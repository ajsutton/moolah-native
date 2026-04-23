import Foundation
import SwiftData
import Testing

@testable import Moolah

/// Shared helpers for the split TransactionStore test suites. Extracted from the
/// original monolithic `TransactionStoreTests.swift` so the focused suites
/// (`TransactionStoreLoadingTests`, `TransactionStoreCRUDTests`, etc.) can share
/// fixtures without duplicating private helpers across files.
@MainActor
enum TransactionStoreTestSupport {
  /// A seeded account paired with its opening balance. Used by `makeStores` to
  /// populate the in-memory store before running a scenario.
  struct SeededAccount {
    let account: Account
    let openingBalance: InstrumentAmount
  }

  /// Helper to create an Account + opening balance pair for seeding.
  static func acct(
    id: UUID,
    name: String,
    type: AccountType = .bank,
    balance: Decimal
  ) -> SeededAccount {
    SeededAccount(
      account: Account(id: id, name: name, type: type, instrument: .defaultTestInstrument),
      openingBalance: InstrumentAmount(quantity: balance, instrument: .defaultTestInstrument)
    )
  }

  static func makeDate(_ string: String) throws -> Date {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    formatter.timeZone = TimeZone(identifier: "UTC")
    return try #require(formatter.date(from: string))
  }

  static func seedTransactions(count: Int, accountId: UUID) throws -> [Transaction] {
    try (0..<count).map { index in
      Transaction(
        date: try makeDate("2024-01-\(String(format: "%02d", min(index + 1, 28)))"),
        payee: "Payee \(index)",
        legs: [
          TransactionLeg(
            accountId: accountId,
            instrument: Instrument.defaultTestInstrument,
            quantity: Decimal(-(index + 1) * 1000) / 100,
            type: .expense
          )
        ]
      )
    }
  }

  /// Bundle of stores returned by `makeStores` so call sites can grab whichever
  /// they need by name rather than positional tuple access.
  struct Stores {
    let transactions: TransactionStore
    let accounts: AccountStore
    let earmarks: EarmarkStore
  }

  static func makeStores(
    backend: CloudKitBackend,
    container: ModelContainer,
    accounts: [SeededAccount] = [],
    earmarks: [Earmark] = []
  ) async -> Stores {
    if !accounts.isEmpty {
      let tuples = accounts.map { ($0.account, $0.openingBalance) }
      TestBackend.seed(accounts: tuples, in: container)
    }
    if !earmarks.isEmpty {
      TestBackend.seed(earmarks: earmarks, in: container)
    }
    let accountStore = AccountStore(
      repository: backend.accounts,
      conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument
    )
    let earmarkStore = EarmarkStore(
      repository: backend.earmarks,
      conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument
    )
    await accountStore.load()
    await earmarkStore.load()
    let store = TransactionStore(
      repository: backend.transactions,
      conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument,
      accountStore: accountStore,
      earmarkStore: earmarkStore
    )
    return Stores(transactions: store, accounts: accountStore, earmarks: earmarkStore)
  }
}

/// In-memory `TransactionRepository` whose every method throws, used by
/// createDefault tests that exercise the failure path. Lives in support so it
/// can be shared across split suites.
struct FailingTransactionRepository: TransactionRepository {
  func fetch(filter: TransactionFilter, page: Int, pageSize: Int) async throws -> TransactionPage {
    throw BackendError.networkUnavailable
  }

  func fetchAll(filter: TransactionFilter) async throws -> [Transaction] {
    throw BackendError.networkUnavailable
  }

  func create(_ transaction: Transaction) async throws -> Transaction {
    throw BackendError.networkUnavailable
  }

  func update(_ transaction: Transaction) async throws -> Transaction {
    throw BackendError.networkUnavailable
  }

  func delete(id: UUID) async throws {
    throw BackendError.networkUnavailable
  }

  func fetchPayeeSuggestions(prefix: String) async throws -> [String] {
    throw BackendError.networkUnavailable
  }
}
