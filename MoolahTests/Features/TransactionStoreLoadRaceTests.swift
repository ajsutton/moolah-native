import Foundation
import SwiftData
import Testing

@testable import Moolah

@Suite("TransactionStore/Load Race")
@MainActor
struct TransactionStoreLoadRaceTests {
  private let accountId = UUID()

  /// Two `load()` calls in flight at the same time (e.g. SwiftUI re-mounting
  /// `TransactionListView` during Analysis → Account navigation and firing
  /// `.task(id: baseFilter)` twice) must not cause the earlier fetch's result
  /// to be appended on top of the later one. See #372.
  @Test
  func concurrentLoadsDoNotDuplicateRows() async throws {
    let transactions = try TransactionStoreTestSupport.seedTransactions(
      count: 3, accountId: accountId)
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(transactions: transactions, in: container)
    let store = TransactionStore(
      repository: backend.transactions,
      conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument
    )

    async let first: Void = store.load(filter: TransactionFilter(accountId: accountId))
    async let second: Void = store.load(filter: TransactionFilter(accountId: accountId))
    _ = await (first, second)

    #expect(store.transactions.count == 3)
    let ids = Set(store.transactions.map(\.transaction.id))
    #expect(ids.count == 3)
  }

  /// An empty store reports no loaded filter, so the first mount of a view
  /// always triggers its initial fetch.
  @Test
  func firstMountTriggersInitialLoad() async throws {
    let (backend, _) = try TestBackend.create()
    let store = TransactionStore(
      repository: backend.transactions,
      conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument
    )

    #expect(!store.isLoaded(for: TransactionFilter(accountId: accountId)))
    #expect(!store.isLoaded(for: TransactionFilter()))
  }

  /// A spurious re-mount after a successful load sees `isLoaded(for:)` as
  /// `true` and skips the redundant fetch.
  @Test
  func reMountWithSameFilterSkipsReload() async throws {
    let (backend, container) = try TestBackend.create()
    let transactions = try TransactionStoreTestSupport.seedTransactions(
      count: 2, accountId: accountId)
    TestBackend.seed(transactions: transactions, in: container)
    let store = TransactionStore(
      repository: backend.transactions,
      conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument
    )

    let filter = TransactionFilter(accountId: accountId)
    await store.load(filter: filter)

    #expect(store.isLoaded(for: filter))
  }

  /// A completed zero-result load still counts as loaded — otherwise an empty
  /// account would re-fetch on every re-mount since `transactions` stays
  /// empty.
  @Test
  func emptyResultLoadStillCountsAsLoaded() async throws {
    let (backend, _) = try TestBackend.create()
    let store = TransactionStore(
      repository: backend.transactions,
      conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument
    )

    let filter = TransactionFilter(accountId: accountId)
    await store.load(filter: filter)

    #expect(store.transactions.isEmpty)
    #expect(store.isLoaded(for: filter))
  }

  /// Switching accounts replaces the store's load state, so `isLoaded(for:)`
  /// is `true` for the new filter and `false` for the previous one — the
  /// `.task` for the new account will actually fetch.
  @Test
  func switchingFiltersResetsLoadState() async throws {
    let otherId = UUID()
    let filterA = TransactionFilter(accountId: accountId)
    let filterB = TransactionFilter(accountId: otherId)

    let transactions =
      try TransactionStoreTestSupport.seedTransactions(count: 2, accountId: accountId)
      + TransactionStoreTestSupport.seedTransactions(count: 1, accountId: otherId)
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(transactions: transactions, in: container)
    let store = TransactionStore(
      repository: backend.transactions,
      conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument
    )

    await store.load(filter: filterA)
    #expect(store.isLoaded(for: filterA))

    await store.load(filter: filterB)
    #expect(store.isLoaded(for: filterB))
    #expect(!store.isLoaded(for: filterA))
  }

  /// A failed fetch leaves `isLoaded(for:)` as `false` so a subsequent
  /// re-mount retries instead of silently showing the empty error state.
  @Test
  func failedLoadAllowsRetryOnRemount() async throws {
    let store = TransactionStore(
      repository: FailingTransactionRepository(),
      conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument
    )

    let filter = TransactionFilter(accountId: accountId)
    await store.load(filter: filter)

    #expect(store.error != nil)
    #expect(!store.isLoaded(for: filter))
  }
}
