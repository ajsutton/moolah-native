import Foundation
import Testing

@testable import Moolah

@Suite("TransactionStore")
@MainActor
struct TransactionStoreTests {
  private let accountId = UUID()

  private func makeDate(_ string: String) -> Date {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    formatter.timeZone = TimeZone(identifier: "UTC")
    return formatter.date(from: string)!
  }

  private func seedTransactions(count: Int, accountId: UUID) -> [Transaction] {
    (0..<count).map { i in
      Transaction(
        type: .expense,
        date: makeDate("2024-01-\(String(format: "%02d", min(i + 1, 28)))"),
        accountId: accountId,
        amount: MonetaryAmount(cents: -(i + 1) * 1000),
        payee: "Payee \(i)"
      )
    }
  }

  @Test func testLoadsFirstPage() async throws {
    let transactions = seedTransactions(count: 3, accountId: accountId)
    let repository = InMemoryTransactionRepository(initialTransactions: transactions)
    let store = TransactionStore(repository: repository)

    await store.load(filter: TransactionFilter(accountId: accountId))

    #expect(store.transactions.count == 3)
    #expect(!store.isLoading)

    // Each entry should have a running balance
    for entry in store.transactions {
      #expect(entry.transaction.accountId == accountId)
    }
  }

  @Test func testPaginationAppendsSecondPage() async throws {
    // Create more transactions than one page
    let transactions = seedTransactions(count: 5, accountId: accountId)
    let repository = InMemoryTransactionRepository(initialTransactions: transactions)
    let store = TransactionStore(repository: repository, pageSize: 3)

    await store.load(filter: TransactionFilter(accountId: accountId))
    #expect(store.transactions.count == 3)
    #expect(store.hasMore == true)

    await store.loadMore()
    #expect(store.transactions.count == 5)
    #expect(store.hasMore == false)
  }

  @Test func testEndOfResultsDetection() async throws {
    let transactions = seedTransactions(count: 2, accountId: accountId)
    let repository = InMemoryTransactionRepository(initialTransactions: transactions)
    let store = TransactionStore(repository: repository, pageSize: 10)

    await store.load(filter: TransactionFilter(accountId: accountId))

    #expect(store.transactions.count == 2)
    #expect(store.hasMore == false)
  }

  @Test func testLoadMoreDoesNothingWhenNoMore() async throws {
    let transactions = seedTransactions(count: 2, accountId: accountId)
    let repository = InMemoryTransactionRepository(initialTransactions: transactions)
    let store = TransactionStore(repository: repository, pageSize: 10)

    await store.load(filter: TransactionFilter(accountId: accountId))
    #expect(store.hasMore == false)

    await store.loadMore()
    #expect(store.transactions.count == 2)  // No duplicates
  }

  @Test func testFilterByAccountId() async throws {
    let otherAccountId = UUID()
    let transactions = [
      Transaction(
        type: .expense, date: makeDate("2024-01-01"), accountId: accountId, amount: MonetaryAmount(cents: -1000),
        payee: "Mine"),
      Transaction(
        type: .expense, date: makeDate("2024-01-02"), accountId: otherAccountId, amount: MonetaryAmount(cents: -2000),
        payee: "Other"),
      Transaction(
        type: .transfer, date: makeDate("2024-01-03"), accountId: otherAccountId,
        toAccountId: accountId, amount: MonetaryAmount(cents: -5000), payee: "Transfer In"),
    ]
    let repository = InMemoryTransactionRepository(initialTransactions: transactions)
    let store = TransactionStore(repository: repository)

    await store.load(filter: TransactionFilter(accountId: accountId))

    #expect(store.transactions.count == 2)  // Direct + transfer-in
    let payees = store.transactions.map(\.transaction.payee)
    #expect(payees.contains("Mine"))
    #expect(payees.contains("Transfer In"))
  }

  @Test func testSortedByDateDescending() async throws {
    let transactions = [
      Transaction(
        type: .expense, date: makeDate("2024-01-01"), accountId: accountId, amount: MonetaryAmount(cents: -1000),
        payee: "Oldest"),
      Transaction(
        type: .expense, date: makeDate("2024-01-15"), accountId: accountId, amount: MonetaryAmount(cents: -2000),
        payee: "Middle"),
      Transaction(
        type: .expense, date: makeDate("2024-01-30"), accountId: accountId, amount: MonetaryAmount(cents: -3000),
        payee: "Newest"),
    ]
    let repository = InMemoryTransactionRepository(initialTransactions: transactions)
    let store = TransactionStore(repository: repository)

    await store.load(filter: TransactionFilter(accountId: accountId))

    #expect(store.transactions[0].transaction.payee == "Newest")
    #expect(store.transactions[1].transaction.payee == "Middle")
    #expect(store.transactions[2].transaction.payee == "Oldest")
  }

  @Test func testRunningBalancesComputed() async throws {
    let transactions = [
      Transaction(
        type: .income, date: makeDate("2024-01-03"), accountId: accountId, amount: MonetaryAmount(cents: 100000),
        payee: "Salary"),
      Transaction(
        type: .expense, date: makeDate("2024-01-02"), accountId: accountId, amount: MonetaryAmount(cents: -2500),
        payee: "Coffee"),
      Transaction(
        type: .expense, date: makeDate("2024-01-01"), accountId: accountId, amount: MonetaryAmount(cents: -10000),
        payee: "Groceries"),
    ]
    let repository = InMemoryTransactionRepository(initialTransactions: transactions)
    let store = TransactionStore(repository: repository)

    await store.load(filter: TransactionFilter(accountId: accountId))

    #expect(store.transactions.count == 3)

    // Transactions are newest-first; balance is the running total after each tx
    // priorBalance = 0 (no older transactions)
    // Groceries (oldest): 0 + (-10000) = -10000
    // Coffee: -10000 + (-2500) = -12500
    // Salary (newest): -12500 + 100000 = 87500
    #expect(store.transactions[0].balance == MonetaryAmount(cents: 87500))  // After Salary
    #expect(store.transactions[1].balance == MonetaryAmount(cents: -12500))  // After Coffee
    #expect(store.transactions[2].balance == MonetaryAmount(cents: -10000))  // After Groceries
  }

  @Test func testReloadClearsExisting() async throws {
    let transactions = seedTransactions(count: 5, accountId: accountId)
    let repository = InMemoryTransactionRepository(initialTransactions: transactions)
    let store = TransactionStore(repository: repository, pageSize: 3)

    await store.load(filter: TransactionFilter(accountId: accountId))
    #expect(store.transactions.count == 3)

    // Reload should start fresh
    await store.load(filter: TransactionFilter(accountId: accountId))
    #expect(store.transactions.count == 3)
  }
}
