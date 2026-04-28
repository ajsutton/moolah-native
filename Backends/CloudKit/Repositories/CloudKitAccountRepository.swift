import Foundation
import OSLog
import SwiftData
import os

final class CloudKitAccountRepository: AccountRepository, @unchecked Sendable {
  private let logger = Logger(subsystem: "com.moolah.app", category: "AccountRepository")
  let modelContainer: ModelContainer
  /// Receives `(recordType, id)` so the opening-balance create path can tag
  /// its txn and leg writes with `TransactionRecord` / `TransactionLegRecord`
  /// instead of the account's own type — see `RepositoryHookRecordTypeTests`.
  var onRecordChanged: (String, UUID) -> Void = { _, _ in }
  var onRecordDeleted: (String, UUID) -> Void = { _, _ in }
  var onInstrumentChanged: (String) -> Void = { _ in }

  init(modelContainer: ModelContainer) {
    self.modelContainer = modelContainer
  }

  // internal (was private) so the `+Positions` extension file can reach the
  // main-actor context from its `@MainActor` helper overloads.
  @MainActor var context: ModelContext {
    modelContainer.mainContext
  }

  func fetchAll() async throws -> [Account] {
    let signpostID = OSSignpostID(log: Signposts.repository)
    os_signpost(
      .begin, log: Signposts.repository, name: "AccountRepo.fetchAll", signpostID: signpostID)
    defer {
      os_signpost(
        .end, log: Signposts.repository, name: "AccountRepo.fetchAll", signpostID: signpostID)
    }
    let descriptor = FetchDescriptor<AccountRecord>(
      sortBy: [SortDescriptor(\.position)]
    )
    // Use a background context for read-only fetches to avoid blocking the main thread.
    let bgContext = ModelContext(modelContainer)
    let fetchStart = ContinuousClock.now
    let records = try bgContext.fetch(descriptor)
    let fetchMs = (ContinuousClock.now - fetchStart).inMilliseconds

    let positionStart = ContinuousClock.now
    let legsStart = ContinuousClock.now
    let (_, allLegs) = try fetchNonScheduledLegs(context: bgContext)
    let legsMs = (ContinuousClock.now - legsStart).inMilliseconds

    let instrumentsStart = ContinuousClock.now
    let instruments = try fetchInstrumentMap(context: bgContext)
    let instrumentsMs = (ContinuousClock.now - instrumentsStart).inMilliseconds

    let computeStart = ContinuousClock.now
    let allPositions = computePositions(from: allLegs, instruments: instruments)
    let computeMs = (ContinuousClock.now - computeStart).inMilliseconds
    let positionMs = (ContinuousClock.now - positionStart).inMilliseconds

    let result = records.map { record in
      let positions = allPositions[record.id] ?? []
      return record.toDomain(
        instruments: instruments,
        positions: positions)
    }
    let totalMs = fetchMs + positionMs
    if totalMs > 100 {
      logger.info(
        """
        AccountRepo.fetchAll took \(totalMs)ms off-main \
        (records: \(fetchMs)ms, legs.fetch: \(legsMs)ms, \
        instruments.fetch: \(instrumentsMs)ms, positions.compute: \(computeMs)ms, \
        \(records.count) accounts, \(allLegs.count) legs)
        """
      )
    }
    return result
  }

  func create(_ account: Account, openingBalance: InstrumentAmount? = nil) async throws -> Account {
    let signpostID = OSSignpostID(log: Signposts.repository)
    os_signpost(
      .begin, log: Signposts.repository, name: "AccountRepo.create", signpostID: signpostID)
    defer {
      os_signpost(
        .end, log: Signposts.repository, name: "AccountRepo.create", signpostID: signpostID)
    }
    guard !account.name.trimmingCharacters(in: .whitespaces).isEmpty else {
      throw BackendError.validationFailed("Account name cannot be empty")
    }

    let record = AccountRecord.from(account)
    try await MainActor.run {
      context.insert(record)

      // If an opening balance is provided, create an opening balance transaction with a leg
      if let openingBalance, !openingBalance.isZero {
        let txnId = UUID()
        let txnRecord = TransactionRecord(
          id: txnId,
          date: Date()
        )
        context.insert(txnRecord)

        try ensureInstrument(account.instrument)

        let legRecord = TransactionLegRecord(
          transactionId: txnId,
          accountId: account.id,
          instrumentId: account.instrument.id,
          quantity: openingBalance.storageValue,
          type: TransactionType.openingBalance.rawValue,
          sortOrder: 0
        )
        context.insert(legRecord)
        try context.save()
        onRecordChanged(AccountRecord.recordType, account.id)
        onRecordChanged(TransactionRecord.recordType, txnRecord.id)
        onRecordChanged(TransactionLegRecord.recordType, legRecord.id)
      } else {
        try context.save()
        onRecordChanged(AccountRecord.recordType, account.id)
      }
    }

    return account
  }

  func update(_ account: Account) async throws -> Account {
    let signpostID = OSSignpostID(log: Signposts.repository)
    os_signpost(
      .begin, log: Signposts.repository, name: "AccountRepo.update", signpostID: signpostID)
    defer {
      os_signpost(
        .end, log: Signposts.repository, name: "AccountRepo.update", signpostID: signpostID)
    }
    let accountId = account.id
    let descriptor = FetchDescriptor<AccountRecord>(
      predicate: #Predicate { $0.id == accountId }
    )

    guard !account.name.trimmingCharacters(in: .whitespaces).isEmpty else {
      throw BackendError.validationFailed("Account name cannot be empty")
    }

    return try await MainActor.run {
      guard let record = try context.fetch(descriptor).first else {
        throw BackendError.notFound("Account not found")
      }
      record.name = account.name
      record.type = account.type.rawValue
      record.instrumentId = account.instrument.id
      record.position = account.position
      record.isHidden = account.isHidden
      try context.save()
      onRecordChanged(AccountRecord.recordType, account.id)

      let instruments = try fetchInstrumentMap()
      let allPositions = try computeAllPositions(instruments: instruments)
      let positions = allPositions[accountId] ?? []
      return record.toDomain(
        instruments: instruments,
        positions: positions)
    }
  }

  func delete(id: UUID) async throws {
    let signpostID = OSSignpostID(log: Signposts.repository)
    os_signpost(
      .begin, log: Signposts.repository, name: "AccountRepo.delete", signpostID: signpostID)
    defer {
      os_signpost(
        .end, log: Signposts.repository, name: "AccountRepo.delete", signpostID: signpostID)
    }
    let descriptor = FetchDescriptor<AccountRecord>(
      predicate: #Predicate { $0.id == id }
    )

    try await MainActor.run {
      guard let record = try context.fetch(descriptor).first else {
        throw BackendError.notFound("Account not found")
      }

      let instruments = try fetchInstrumentMap()
      let allPositions = try computeAllPositions(instruments: instruments)
      let positions = allPositions[id] ?? []
      let hasNonZeroPosition = positions.contains { $0.quantity != 0 }
      guard !hasNonZeroPosition else {
        throw BackendError.validationFailed("Cannot delete account with non-zero balance")
      }

      // Soft delete
      record.isHidden = true
      try context.save()
      onRecordChanged(AccountRecord.recordType, id)
    }
  }

  // MARK: - Instrument Cache

  @MainActor private var instrumentCacheForAccount: [String: Instrument] = [:]

  @MainActor
  func ensureInstrument(_ instrument: Instrument) throws {
    switch instrument.kind {
    case .fiatCurrency:
      // Fiat is ambient — synthesised from `Locale.Currency.isoCurrencies`
      // by the registry. No row is required.
      instrumentCacheForAccount[instrument.id] = instrument
    case .stock:
      // Stock path intentionally unchanged in this plan. CSV imports do
      // not currently produce unmapped stock rows in the same way the
      // crypto path does, so tightening this without a clear motivating
      // failure risks regressing imports. See design plan §4.8.
      let iid = instrument.id
      let descriptor = FetchDescriptor<InstrumentRecord>(predicate: #Predicate { $0.id == iid })
      if try context.fetch(descriptor).isEmpty {
        context.insert(InstrumentRecord.from(instrument))
        onInstrumentChanged(instrument.id)
      }
      instrumentCacheForAccount[instrument.id] = instrument
    case .cryptoToken:
      // A crypto write must reference an instrument the registry has seen
      // and assigned at least one provider mapping (CoinGecko, CryptoCompare,
      // or Binance). Auto-inserting an unmapped row here would defer the
      // failure to conversion time as `ConversionError.noProviderMapping`.
      // Routing the user through `InstrumentPickerStore.resolve(_:)` (or
      // the Add Token flow) is the contract; throwing here surfaces the
      // programmer error early. Mirrors the transaction repo's tightening
      // (Task 14).
      let iid = instrument.id
      let descriptor = FetchDescriptor<InstrumentRecord>(predicate: #Predicate { $0.id == iid })
      let existing = try context.fetch(descriptor).first
      let isMapped =
        existing?.coingeckoId != nil
        || existing?.cryptocompareSymbol != nil
        || existing?.binanceSymbol != nil
      guard isMapped else {
        throw UnmappedCryptoInstrumentError(instrumentId: instrument.id)
      }
      instrumentCacheForAccount[instrument.id] = instrument
    }
  }
}
