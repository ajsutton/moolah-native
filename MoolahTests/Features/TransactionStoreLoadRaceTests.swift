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
  func testConcurrentLoadsDoNotDuplicate() async throws {
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
}
