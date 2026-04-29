import Foundation
import GRDB

@testable import Moolah

/// Wraps `database.write` and traps with a clear message on failure.
///
/// In-memory GRDB writes during test seeding should never fail; a
/// failure here means the test harness is broken and the suite cannot
/// proceed. Trapping keeps seed call sites free of `try!` without
/// forcing every seed helper (and its hundreds of callers) to throw.
private func writeOrTrap(
  _ database: any DatabaseWriter,
  file: StaticString = #file,
  line: UInt = #line,
  _ block: (Database) throws -> Void
) {
  do {
    try database.write(block)
  } catch {
    preconditionFailure(
      "TestBackend seed write failed: \(error)",
      file: file,
      line: line
    )
  }
}

/// Factory for creating CloudKitBackend instances backed by an in-memory GRDB database.
/// Used in all tests as a replacement for InMemoryBackend and individual InMemory*Repository types.
enum TestBackend {
  /// Creates a CloudKitBackend backed by an in-memory GRDB database.
  /// Each call creates a fresh, isolated queue — no cross-test contamination.
  static func create(
    instrument: Instrument = .defaultTestInstrument,
    exchangeRates: [String: [String: Decimal]] = [:]
  ) throws -> (backend: CloudKitBackend, database: DatabaseQueue) {
    let rateClient = FixedRateClient(rates: exchangeRates)
    // One in-memory GRDB queue per backend covers every repository on
    // the same connection — domain rows, the rate-cache service, and
    // the two synced csv-import tables share the per-profile
    // `data.sqlite` in production.
    let database = try ProfileDatabase.openInMemory()
    let exchangeRateService = ExchangeRateService(
      client: rateClient, database: database)
    let conversionService = FiatConversionService(exchangeRates: exchangeRateService)
    let registry = GRDBInstrumentRegistryRepository(database: database)
    let backend = CloudKitBackend(
      database: database,
      instrument: instrument,
      profileLabel: "Test",
      conversionService: conversionService,
      instrumentRegistry: registry
    )
    return (backend, database)
  }

  // MARK: - Data Seeding

  /// Seeds accounts into the in-memory store.
  @discardableResult
  static func seed(
    accounts: [Account],
    in database: any DatabaseWriter,
    instrument: Instrument = .defaultTestInstrument
  ) -> [Account] {
    writeOrTrap(database) { database in
      for account in accounts {
        try AccountRow(domain: account).insert(database)
      }
    }
    return accounts
  }

  /// Seeds accounts with opening balances into the in-memory store.
  /// Creates opening balance transactions for accounts with the provided balances.
  @discardableResult
  static func seed(
    accounts: [(account: Account, openingBalance: InstrumentAmount)],
    in database: any DatabaseWriter,
    instrument: Instrument = .defaultTestInstrument
  ) -> [Account] {
    writeOrTrap(database) { database in
      for (account, openingBalance) in accounts {
        try AccountRow(domain: account).insert(database)
        if !openingBalance.isZero {
          try insertOpeningBalanceTransaction(
            database: database,
            accountId: account.id,
            instrument: instrument,
            openingBalance: openingBalance)
        }
      }
    }
    return accounts.map(\.account)
  }

  private static func insertOpeningBalanceTransaction(
    database: Database,
    accountId: UUID,
    instrument: Instrument,
    openingBalance: InstrumentAmount
  ) throws {
    let txnId = UUID()
    let txnRow = TransactionRow(
      id: txnId,
      recordName: TransactionRow.recordName(for: txnId),
      date: Date(),
      payee: nil,
      notes: nil,
      recurPeriod: nil,
      recurEvery: nil,
      importOriginRawDescription: nil,
      importOriginBankReference: nil,
      importOriginRawAmount: nil,
      importOriginRawBalance: nil,
      importOriginImportedAt: nil,
      importOriginImportSessionId: nil,
      importOriginSourceFilename: nil,
      importOriginParserIdentifier: nil,
      encodedSystemFields: nil)
    try txnRow.insert(database)
    let legId = UUID()
    let legRow = TransactionLegRow(
      id: legId,
      recordName: TransactionLegRow.recordName(for: legId),
      transactionId: txnId,
      accountId: accountId,
      instrumentId: instrument.id,
      quantity: openingBalance.storageValue,
      type: TransactionType.openingBalance.rawValue,
      categoryId: nil,
      earmarkId: nil,
      sortOrder: 0,
      encodedSystemFields: nil)
    try legRow.insert(database)
  }

  /// Seeds transactions into the in-memory store.
  /// Also creates InstrumentRow entries for non-fiat instruments so they resolve correctly on fetch.
  @discardableResult
  static func seed(
    transactions: [Transaction],
    in database: any DatabaseWriter
  ) -> [Transaction] {
    writeOrTrap(database) { database in
      var seenInstruments: Set<String> = []
      var seenAccounts: Set<UUID> = []
      var seenCategories: Set<UUID> = []
      var seenEarmarks: Set<UUID> = []
      for txn in transactions {
        try TransactionRow(domain: txn).insert(database)
        for (index, leg) in txn.legs.enumerated() {
          // Ensure non-fiat instruments have InstrumentRow entries
          if leg.instrument.kind != .fiatCurrency,
            !seenInstruments.contains(leg.instrument.id)
          {
            seenInstruments.insert(leg.instrument.id)
            try InstrumentRow(domain: leg.instrument).insert(database)
          }
          // Auto-create FK parents on demand. SwiftData-era tests rarely
          // pre-seeded accounts/categories/earmarks before the legs that
          // referenced them; under the GRDB schema's enforced FKs we have
          // to materialise lightweight placeholder rows so the leg insert
          // doesn't trip the constraint. Tests that care about the parent
          // shape seed it explicitly, which the `try?` upsert respects.
          if let accountId = leg.accountId, !seenAccounts.contains(accountId) {
            seenAccounts.insert(accountId)
            try ensurePlaceholderAccount(
              database: database, id: accountId, instrument: leg.instrument)
          }
          if let categoryId = leg.categoryId, !seenCategories.contains(categoryId) {
            seenCategories.insert(categoryId)
            try ensurePlaceholderCategory(database: database, id: categoryId)
          }
          if let earmarkId = leg.earmarkId, !seenEarmarks.contains(earmarkId) {
            seenEarmarks.insert(earmarkId)
            try ensurePlaceholderEarmark(
              database: database, id: earmarkId, instrument: leg.instrument)
          }
          try TransactionLegRow(domain: leg, transactionId: txn.id, sortOrder: index)
            .insert(database)
        }
      }
    }
    return transactions
  }

  /// Inserts a stub `account` row keyed by `id` if one isn't already
  /// present. Used by the seed helpers to keep the FK enforcement from
  /// rejecting leg / investment-value inserts that reference an
  /// account the test didn't bother to seed (most existing tests rely on
  /// this implicit behaviour from the SwiftData era).
  private static func ensurePlaceholderAccount(
    database: Database, id: UUID, instrument: Instrument
  ) throws {
    let exists = try AccountRow.filter(AccountRow.Columns.id == id).fetchOne(database)
    guard exists == nil else { return }
    let stub = Account(
      id: id, name: "stub", type: .bank, instrument: instrument)
    try AccountRow(domain: stub).insert(database)
  }

  /// See `ensurePlaceholderAccount`.
  private static func ensurePlaceholderCategory(database: Database, id: UUID) throws {
    let exists = try CategoryRow.filter(CategoryRow.Columns.id == id).fetchOne(database)
    guard exists == nil else { return }
    try CategoryRow(domain: Moolah.Category(id: id, name: "stub")).insert(database)
  }

  /// See `ensurePlaceholderAccount`.
  private static func ensurePlaceholderEarmark(
    database: Database, id: UUID, instrument: Instrument
  ) throws {
    let exists = try EarmarkRow.filter(EarmarkRow.Columns.id == id).fetchOne(database)
    guard exists == nil else { return }
    try EarmarkRow(domain: Earmark(id: id, name: "stub", instrument: instrument))
      .insert(database)
  }

  /// Seeds earmarks into the in-memory store.
  /// Note: Earmark saved/spent/balance are computed from transactions in the repositories,
  /// so you must also seed corresponding transactions for earmarks that need non-zero balances.
  @discardableResult
  static func seed(
    earmarks: [Earmark],
    in database: any DatabaseWriter,
    instrument: Instrument = .defaultTestInstrument
  ) -> [Earmark] {
    writeOrTrap(database) { database in
      for earmark in earmarks {
        try EarmarkRow(domain: earmark).insert(database)
      }
    }
    return earmarks
  }

  /// Seeds categories into the in-memory store.
  @discardableResult
  static func seed(
    categories: [Moolah.Category],
    in database: any DatabaseWriter
  ) -> [Moolah.Category] {
    writeOrTrap(database) { database in
      for category in categories {
        try CategoryRow(domain: category).insert(database)
      }
    }
    return categories
  }

  /// Seeds investment values into the in-memory store. Auto-seeds a stub
  /// account row for any `accountId` the test didn't seed explicitly,
  /// matching the SwiftData-era seeding pattern.
  @discardableResult
  static func seed(
    investmentValues: [UUID: [InvestmentValue]],
    in database: any DatabaseWriter,
    instrument: Instrument = .defaultTestInstrument
  ) -> [UUID: [InvestmentValue]] {
    writeOrTrap(database) { database in
      for (accountId, values) in investmentValues {
        try ensurePlaceholderAccount(
          database: database, id: accountId, instrument: instrument)
        for value in values {
          try InvestmentValueRow(domain: value, accountId: accountId).insert(database)
        }
      }
    }
    return investmentValues
  }

  /// Seeds earmark budget items into the in-memory store. Auto-seeds a
  /// stub earmark row keyed by `earmarkId` and stub category rows for
  /// every `item.categoryId` the test didn't seed explicitly.
  static func seedBudget(
    earmarkId: UUID,
    items: [EarmarkBudgetItem],
    in database: any DatabaseWriter,
    instrument: Instrument = .defaultTestInstrument
  ) {
    writeOrTrap(database) { database in
      try ensurePlaceholderEarmark(
        database: database, id: earmarkId, instrument: instrument)
      for item in items {
        try ensurePlaceholderCategory(database: database, id: item.categoryId)
        try EarmarkBudgetItemRow(domain: item, earmarkId: earmarkId).insert(database)
      }
    }
  }
}
