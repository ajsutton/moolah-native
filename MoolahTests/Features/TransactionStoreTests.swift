import Foundation
import SwiftData
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
        amount: MonetaryAmount(cents: -(i + 1) * 1000, currency: Instrument.defaultTestInstrument),
        payee: "Payee \(i)"
      )
    }
  }

  @Test func testLoadsFirstPage() async throws {
    let transactions = seedTransactions(count: 3, accountId: accountId)
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(transactions: transactions, in: container)
    let store = TransactionStore(repository: backend.transactions)

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
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(transactions: transactions, in: container)
    let store = TransactionStore(repository: backend.transactions, pageSize: 3)

    await store.load(filter: TransactionFilter(accountId: accountId))
    #expect(store.transactions.count == 3)
    #expect(store.hasMore == true)

    await store.loadMore()
    #expect(store.transactions.count == 5)
    #expect(store.hasMore == false)
  }

  @Test func testEndOfResultsDetection() async throws {
    let transactions = seedTransactions(count: 2, accountId: accountId)
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(transactions: transactions, in: container)
    let store = TransactionStore(repository: backend.transactions, pageSize: 10)

    await store.load(filter: TransactionFilter(accountId: accountId))

    #expect(store.transactions.count == 2)
    #expect(store.hasMore == false)
  }

  @Test func testLoadMoreDoesNothingWhenNoMore() async throws {
    let transactions = seedTransactions(count: 2, accountId: accountId)
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(transactions: transactions, in: container)
    let store = TransactionStore(repository: backend.transactions, pageSize: 10)

    await store.load(filter: TransactionFilter(accountId: accountId))
    #expect(store.hasMore == false)

    await store.loadMore()
    #expect(store.transactions.count == 2)  // No duplicates
  }

  @Test func testFilterByAccountId() async throws {
    let otherAccountId = UUID()
    let transactions = [
      Transaction(
        type: .expense, date: makeDate("2024-01-01"), accountId: accountId,
        amount: MonetaryAmount(cents: -1000, currency: Instrument.defaultTestInstrument),
        payee: "Mine"),
      Transaction(
        type: .expense, date: makeDate("2024-01-02"), accountId: otherAccountId,
        amount: MonetaryAmount(cents: -2000, currency: Instrument.defaultTestInstrument),
        payee: "Other"),
      Transaction(
        type: .transfer, date: makeDate("2024-01-03"), accountId: otherAccountId,
        toAccountId: accountId,
        amount: MonetaryAmount(cents: -5000, currency: Instrument.defaultTestInstrument),
        payee: "Transfer In"),
    ]
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(transactions: transactions, in: container)
    let store = TransactionStore(repository: backend.transactions)

    await store.load(filter: TransactionFilter(accountId: accountId))

    #expect(store.transactions.count == 2)  // Direct + transfer-in
    let payees = store.transactions.map(\.transaction.payee)
    #expect(payees.contains("Mine"))
    #expect(payees.contains("Transfer In"))
  }

  @Test func testSortedByDateDescending() async throws {
    let transactions = [
      Transaction(
        type: .expense, date: makeDate("2024-01-01"), accountId: accountId,
        amount: MonetaryAmount(cents: -1000, currency: Instrument.defaultTestInstrument),
        payee: "Oldest"),
      Transaction(
        type: .expense, date: makeDate("2024-01-15"), accountId: accountId,
        amount: MonetaryAmount(cents: -2000, currency: Instrument.defaultTestInstrument),
        payee: "Middle"),
      Transaction(
        type: .expense, date: makeDate("2024-01-30"), accountId: accountId,
        amount: MonetaryAmount(cents: -3000, currency: Instrument.defaultTestInstrument),
        payee: "Newest"),
    ]
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(transactions: transactions, in: container)
    let store = TransactionStore(repository: backend.transactions)

    await store.load(filter: TransactionFilter(accountId: accountId))

    #expect(store.transactions[0].transaction.payee == "Newest")
    #expect(store.transactions[1].transaction.payee == "Middle")
    #expect(store.transactions[2].transaction.payee == "Oldest")
  }

  @Test func testRunningBalancesComputed() async throws {
    let transactions = [
      Transaction(
        type: .income, date: makeDate("2024-01-03"), accountId: accountId,
        amount: MonetaryAmount(cents: 100000, currency: Instrument.defaultTestInstrument),
        payee: "Salary"),
      Transaction(
        type: .expense, date: makeDate("2024-01-02"), accountId: accountId,
        amount: MonetaryAmount(cents: -2500, currency: Instrument.defaultTestInstrument),
        payee: "Coffee"),
      Transaction(
        type: .expense, date: makeDate("2024-01-01"), accountId: accountId,
        amount: MonetaryAmount(cents: -10000, currency: Instrument.defaultTestInstrument),
        payee: "Groceries"),
    ]
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(transactions: transactions, in: container)
    let store = TransactionStore(repository: backend.transactions)

    await store.load(filter: TransactionFilter(accountId: accountId))

    #expect(store.transactions.count == 3)

    // Transactions are newest-first; balance is the running total after each tx
    // priorBalance = 0 (no older transactions)
    // Groceries (oldest): 0 + (-10000) = -10000
    // Coffee: -10000 + (-2500) = -12500
    // Salary (newest): -12500 + 100000 = 87500
    #expect(
      store.transactions[0].balance
        == MonetaryAmount(cents: 87500, currency: Instrument.defaultTestInstrument))  // After Salary
    #expect(
      store.transactions[1].balance
        == MonetaryAmount(cents: -12500, currency: Instrument.defaultTestInstrument))  // After Coffee
    #expect(
      store.transactions[2].balance
        == MonetaryAmount(cents: -10000, currency: Instrument.defaultTestInstrument))  // After Groceries
  }

  @Test func testReloadClearsExisting() async throws {
    let transactions = seedTransactions(count: 5, accountId: accountId)
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(transactions: transactions, in: container)
    let store = TransactionStore(repository: backend.transactions, pageSize: 3)

    await store.load(filter: TransactionFilter(accountId: accountId))
    #expect(store.transactions.count == 3)

    // Reload should start fresh
    await store.load(filter: TransactionFilter(accountId: accountId))
    #expect(store.transactions.count == 3)
  }

  // MARK: - CRUD

  @Test func testCreateAddsTransaction() async throws {
    let (backend, _) = try TestBackend.create()
    let store = TransactionStore(repository: backend.transactions)

    await store.load(filter: TransactionFilter(accountId: accountId))
    #expect(store.transactions.isEmpty)

    let tx = Transaction(
      type: .expense, date: makeDate("2024-01-15"), accountId: accountId,
      amount: MonetaryAmount(cents: -5000, currency: Instrument.defaultTestInstrument),
      payee: "Coffee Shop"
    )
    _ = await store.create(tx)

    #expect(store.transactions.count == 1)
    #expect(store.transactions[0].transaction.payee == "Coffee Shop")
    #expect(store.error == nil)
  }

  @Test func testUpdateModifiesTransaction() async throws {
    let tx = Transaction(
      type: .expense, date: makeDate("2024-01-15"), accountId: accountId,
      amount: MonetaryAmount(cents: -5000, currency: Instrument.defaultTestInstrument),
      payee: "Coffee Shop"
    )
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(transactions: [tx], in: container)
    let store = TransactionStore(repository: backend.transactions)

    await store.load(filter: TransactionFilter(accountId: accountId))
    #expect(store.transactions.count == 1)

    var updated = tx
    updated.payee = "Fancy Coffee"
    updated.amount = MonetaryAmount(cents: -7500, currency: Instrument.defaultTestInstrument)
    await store.update(updated)

    #expect(store.transactions.count == 1)
    #expect(store.transactions[0].transaction.payee == "Fancy Coffee")
    #expect(store.transactions[0].transaction.amount.cents == -7500)
    #expect(store.error == nil)
  }

  @Test func testDeleteRemovesTransaction() async throws {
    let tx = Transaction(
      type: .expense, date: makeDate("2024-01-15"), accountId: accountId,
      amount: MonetaryAmount(cents: -5000, currency: Instrument.defaultTestInstrument),
      payee: "Coffee Shop"
    )
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(transactions: [tx], in: container)
    let store = TransactionStore(repository: backend.transactions)

    await store.load(filter: TransactionFilter(accountId: accountId))
    #expect(store.transactions.count == 1)

    await store.delete(id: tx.id)

    #expect(store.transactions.isEmpty)
    #expect(store.error == nil)
  }

  @Test func testCreateUpdateDeleteCycle() async throws {
    let (backend, _) = try TestBackend.create()
    let store = TransactionStore(repository: backend.transactions)

    await store.load(filter: TransactionFilter(accountId: accountId))

    // Create
    let tx = Transaction(
      type: .income, date: makeDate("2024-01-10"), accountId: accountId,
      amount: MonetaryAmount(cents: 100000, currency: Instrument.defaultTestInstrument),
      payee: "Salary"
    )
    _ = await store.create(tx)
    #expect(store.transactions.count == 1)

    // Update
    var modified = tx
    modified.amount = MonetaryAmount(cents: 110000, currency: Instrument.defaultTestInstrument)
    await store.update(modified)
    #expect(store.transactions.count == 1)
    #expect(store.transactions[0].transaction.amount.cents == 110000)

    // Delete
    await store.delete(id: tx.id)
    #expect(store.transactions.isEmpty)
  }

  @Test func testRunningBalancesUpdateAfterCreate() async throws {
    let existing = Transaction(
      type: .income, date: makeDate("2024-01-01"), accountId: accountId,
      amount: MonetaryAmount(cents: 100000, currency: Instrument.defaultTestInstrument),
      payee: "Initial"
    )
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(transactions: [existing], in: container)
    let store = TransactionStore(repository: backend.transactions)

    await store.load(filter: TransactionFilter(accountId: accountId))
    #expect(store.transactions[0].balance.cents == 100000)

    // Add a newer expense
    let expense = Transaction(
      type: .expense, date: makeDate("2024-01-15"), accountId: accountId,
      amount: MonetaryAmount(cents: -3000, currency: Instrument.defaultTestInstrument),
      payee: "Coffee"
    )
    _ = await store.create(expense)

    // Newest first: expense (balance 97000), then income (balance 100000)
    #expect(store.transactions.count == 2)
    #expect(store.transactions[0].transaction.payee == "Coffee")
    #expect(store.transactions[0].balance.cents == 97000)
    #expect(store.transactions[1].transaction.payee == "Initial")
    #expect(store.transactions[1].balance.cents == 100000)
  }

  @Test func testRunningBalancesUpdateAfterDelete() async throws {
    let tx1 = Transaction(
      type: .income, date: makeDate("2024-01-01"), accountId: accountId,
      amount: MonetaryAmount(cents: 100000, currency: Instrument.defaultTestInstrument),
      payee: "Salary"
    )
    let tx2 = Transaction(
      type: .expense, date: makeDate("2024-01-15"), accountId: accountId,
      amount: MonetaryAmount(cents: -3000, currency: Instrument.defaultTestInstrument),
      payee: "Coffee"
    )
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(transactions: [tx1, tx2], in: container)
    let store = TransactionStore(repository: backend.transactions)

    await store.load(filter: TransactionFilter(accountId: accountId))
    #expect(store.transactions.count == 2)
    #expect(store.transactions[0].balance.cents == 97000)  // After Coffee

    // Delete the expense — balance should revert
    await store.delete(id: tx2.id)
    #expect(store.transactions.count == 1)
    #expect(store.transactions[0].balance.cents == 100000)  // Only Salary remains
  }

  @Test func testOnMutatePassesNilOldOnCreate() async throws {
    let (backend, _) = try TestBackend.create()
    let store = TransactionStore(repository: backend.transactions)

    var receivedOld: Transaction?? = .none  // .none = not called, .some(nil) = called with nil
    var receivedNew: Transaction?
    store.onMutate = { old, new in
      receivedOld = old
      receivedNew = new
    }

    await store.load(filter: TransactionFilter(accountId: accountId))

    let tx = Transaction(
      type: .expense, date: makeDate("2024-01-15"), accountId: accountId,
      amount: MonetaryAmount(cents: -5000, currency: Instrument.defaultTestInstrument),
      payee: "Test"
    )
    _ = await store.create(tx)
    #expect(receivedOld == .some(nil))
    #expect(receivedNew?.id == tx.id)
  }

  @Test func testOnMutatePassesBothOnUpdate() async throws {
    let tx = Transaction(
      type: .expense, date: makeDate("2024-01-15"), accountId: accountId,
      amount: MonetaryAmount(cents: -5000, currency: Instrument.defaultTestInstrument),
      payee: "Test"
    )
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(transactions: [tx], in: container)
    let store = TransactionStore(repository: backend.transactions)

    var receivedOld: Transaction?
    var receivedNew: Transaction?
    store.onMutate = { old, new in
      receivedOld = old
      receivedNew = new
    }

    await store.load(filter: TransactionFilter(accountId: accountId))

    var updated = tx
    updated.payee = "Updated"
    await store.update(updated)
    #expect(receivedOld?.id == tx.id)
    #expect(receivedOld?.payee == "Test")
    #expect(receivedNew?.payee == "Updated")
  }

  @Test func testOnMutatePassesNilNewOnDelete() async throws {
    let tx = Transaction(
      type: .expense, date: makeDate("2024-01-15"), accountId: accountId,
      amount: MonetaryAmount(cents: -5000, currency: Instrument.defaultTestInstrument),
      payee: "Test"
    )
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(transactions: [tx], in: container)
    let store = TransactionStore(repository: backend.transactions)

    var receivedOld: Transaction?
    var receivedNew: Transaction?? = .some(nil)  // sentinel
    store.onMutate = { old, new in
      receivedOld = old
      receivedNew = new
    }

    await store.load(filter: TransactionFilter(accountId: accountId))

    await store.delete(id: tx.id)
    #expect(receivedOld?.id == tx.id)
    #expect(receivedNew == .some(nil))
  }

  // MARK: - Balance Updates with Transfers

  @Test func testOnMutateWithTransfer() async throws {
    let savingsId = UUID()
    let tx = Transaction(
      type: .transfer, date: makeDate("2024-01-15"), accountId: accountId,
      toAccountId: savingsId,
      amount: MonetaryAmount(cents: -10000, currency: Instrument.defaultTestInstrument),
      payee: ""
    )
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(transactions: [tx], in: container)
    let store = TransactionStore(repository: backend.transactions)

    var receivedOld: Transaction?
    var receivedNew: Transaction?
    store.onMutate = { old, new in
      receivedOld = old
      receivedNew = new
    }

    await store.load(filter: TransactionFilter(accountId: accountId))

    // Update the transfer amount
    var updated = tx
    updated.amount = MonetaryAmount(cents: -15000, currency: Instrument.defaultTestInstrument)
    await store.update(updated)

    #expect(receivedOld?.id == tx.id)
    #expect(receivedOld?.amount.cents == -10000)
    #expect(receivedOld?.toAccountId == savingsId)
    #expect(receivedNew?.amount.cents == -15000)
    #expect(receivedNew?.toAccountId == savingsId)
  }

  @Test func testOnMutateChangingTransferToAccount() async throws {
    let savingsId = UUID()
    let investmentId = UUID()
    let tx = Transaction(
      type: .transfer, date: makeDate("2024-01-15"), accountId: accountId,
      toAccountId: savingsId,
      amount: MonetaryAmount(cents: -10000, currency: Instrument.defaultTestInstrument),
      payee: ""
    )
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(transactions: [tx], in: container)
    let store = TransactionStore(repository: backend.transactions)

    var receivedOld: Transaction?
    var receivedNew: Transaction?
    store.onMutate = { old, new in
      receivedOld = old
      receivedNew = new
    }

    await store.load(filter: TransactionFilter(accountId: accountId))

    // Change the toAccountId
    var updated = tx
    updated.toAccountId = investmentId
    await store.update(updated)

    #expect(receivedOld?.toAccountId == savingsId)
    #expect(receivedNew?.toAccountId == investmentId)
  }

  @Test func testOnMutateChangingFromAccountId() async throws {
    let newAccountId = UUID()
    let tx = Transaction(
      type: .expense, date: makeDate("2024-01-15"), accountId: accountId,
      amount: MonetaryAmount(cents: -5000, currency: Instrument.defaultTestInstrument),
      payee: "Test"
    )
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(transactions: [tx], in: container)
    let store = TransactionStore(repository: backend.transactions)

    var receivedOld: Transaction?
    var receivedNew: Transaction?
    store.onMutate = { old, new in
      receivedOld = old
      receivedNew = new
    }

    await store.load(filter: TransactionFilter(accountId: accountId))

    // Change the accountId
    var updated = tx
    updated.accountId = newAccountId
    await store.update(updated)

    #expect(receivedOld?.accountId == accountId)
    #expect(receivedNew?.accountId == newAccountId)
  }

  // MARK: - Balance Updates with Earmarks

  @Test func testOnMutateWithEarmark() async throws {
    let earmarkId = UUID()
    let tx = Transaction(
      type: .expense, date: makeDate("2024-01-15"), accountId: accountId,
      amount: MonetaryAmount(cents: -5000, currency: Instrument.defaultTestInstrument),
      payee: "Test",
      earmarkId: earmarkId
    )
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(transactions: [tx], in: container)
    let store = TransactionStore(repository: backend.transactions)

    var receivedOld: Transaction?
    var receivedNew: Transaction?
    store.onMutate = { old, new in
      receivedOld = old
      receivedNew = new
    }

    await store.load(filter: TransactionFilter(accountId: accountId))

    // Update the amount
    var updated = tx
    updated.amount = MonetaryAmount(cents: -7500, currency: Instrument.defaultTestInstrument)
    await store.update(updated)

    #expect(receivedOld?.earmarkId == earmarkId)
    #expect(receivedOld?.amount.cents == -5000)
    #expect(receivedNew?.earmarkId == earmarkId)
    #expect(receivedNew?.amount.cents == -7500)
  }

  @Test func testOnMutateChangingEarmarkId() async throws {
    let earmarkId1 = UUID()
    let earmarkId2 = UUID()
    let tx = Transaction(
      type: .expense, date: makeDate("2024-01-15"), accountId: accountId,
      amount: MonetaryAmount(cents: -5000, currency: Instrument.defaultTestInstrument),
      payee: "Test",
      earmarkId: earmarkId1
    )
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(transactions: [tx], in: container)
    let store = TransactionStore(repository: backend.transactions)

    var receivedOld: Transaction?
    var receivedNew: Transaction?
    store.onMutate = { old, new in
      receivedOld = old
      receivedNew = new
    }

    await store.load(filter: TransactionFilter(accountId: accountId))

    // Change the earmarkId
    var updated = tx
    updated.earmarkId = earmarkId2
    await store.update(updated)

    #expect(receivedOld?.earmarkId == earmarkId1)
    #expect(receivedNew?.earmarkId == earmarkId2)
  }

  @Test func testOnMutateAddingEarmark() async throws {
    let earmarkId = UUID()
    let tx = Transaction(
      type: .expense, date: makeDate("2024-01-15"), accountId: accountId,
      amount: MonetaryAmount(cents: -5000, currency: Instrument.defaultTestInstrument),
      payee: "Test"
    )
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(transactions: [tx], in: container)
    let store = TransactionStore(repository: backend.transactions)

    var receivedOld: Transaction?
    var receivedNew: Transaction?
    store.onMutate = { old, new in
      receivedOld = old
      receivedNew = new
    }

    await store.load(filter: TransactionFilter(accountId: accountId))

    // Add an earmarkId
    var updated = tx
    updated.earmarkId = earmarkId
    await store.update(updated)

    #expect(receivedOld?.earmarkId == nil)
    #expect(receivedNew?.earmarkId == earmarkId)
  }

  @Test func testOnMutateRemovingEarmark() async throws {
    let earmarkId = UUID()
    let tx = Transaction(
      type: .expense, date: makeDate("2024-01-15"), accountId: accountId,
      amount: MonetaryAmount(cents: -5000, currency: Instrument.defaultTestInstrument),
      payee: "Test",
      earmarkId: earmarkId
    )
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(transactions: [tx], in: container)
    let store = TransactionStore(repository: backend.transactions)

    var receivedOld: Transaction?
    var receivedNew: Transaction?
    store.onMutate = { old, new in
      receivedOld = old
      receivedNew = new
    }

    await store.load(filter: TransactionFilter(accountId: accountId))

    // Remove the earmarkId
    var updated = tx
    updated.earmarkId = nil
    await store.update(updated)

    #expect(receivedOld?.earmarkId == earmarkId)
    #expect(receivedNew?.earmarkId == nil)
  }

  // MARK: - Balance Updates with Type Changes

  @Test func testOnMutateChangingTypeExpenseToIncome() async throws {
    let tx = Transaction(
      type: .expense, date: makeDate("2024-01-15"), accountId: accountId,
      amount: MonetaryAmount(cents: -5000, currency: Instrument.defaultTestInstrument),
      payee: "Test"
    )
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(transactions: [tx], in: container)
    let store = TransactionStore(repository: backend.transactions)

    var receivedOld: Transaction?
    var receivedNew: Transaction?
    store.onMutate = { old, new in
      receivedOld = old
      receivedNew = new
    }

    await store.load(filter: TransactionFilter(accountId: accountId))

    // Change type to income (amount sign should flip)
    var updated = tx
    updated.type = .income
    updated.amount = MonetaryAmount(cents: 5000, currency: Instrument.defaultTestInstrument)
    await store.update(updated)

    #expect(receivedOld?.type == .expense)
    #expect(receivedOld?.amount.cents == -5000)
    #expect(receivedNew?.type == .income)
    #expect(receivedNew?.amount.cents == 5000)
  }

  @Test func testOnMutateChangingTypeExpenseToTransfer() async throws {
    let savingsId = UUID()
    let tx = Transaction(
      type: .expense, date: makeDate("2024-01-15"), accountId: accountId,
      amount: MonetaryAmount(cents: -5000, currency: Instrument.defaultTestInstrument),
      payee: "Test"
    )
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(transactions: [tx], in: container)
    let store = TransactionStore(repository: backend.transactions)

    var receivedOld: Transaction?
    var receivedNew: Transaction?
    store.onMutate = { old, new in
      receivedOld = old
      receivedNew = new
    }

    await store.load(filter: TransactionFilter(accountId: accountId))

    // Change type to transfer
    var updated = tx
    updated.type = .transfer
    updated.toAccountId = savingsId
    await store.update(updated)

    #expect(receivedOld?.type == .expense)
    #expect(receivedOld?.toAccountId == nil)
    #expect(receivedNew?.type == .transfer)
    #expect(receivedNew?.toAccountId == savingsId)
  }

  @Test func testOnMutateChangingTypeTransferToExpense() async throws {
    let savingsId = UUID()
    let tx = Transaction(
      type: .transfer, date: makeDate("2024-01-15"), accountId: accountId,
      toAccountId: savingsId,
      amount: MonetaryAmount(cents: -5000, currency: Instrument.defaultTestInstrument),
      payee: ""
    )
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(transactions: [tx], in: container)
    let store = TransactionStore(repository: backend.transactions)

    var receivedOld: Transaction?
    var receivedNew: Transaction?
    store.onMutate = { old, new in
      receivedOld = old
      receivedNew = new
    }

    await store.load(filter: TransactionFilter(accountId: accountId))

    // Change type to expense (toAccountId should be nil)
    var updated = tx
    updated.type = .expense
    updated.toAccountId = nil
    updated.payee = "Test"
    await store.update(updated)

    #expect(receivedOld?.type == .transfer)
    #expect(receivedOld?.toAccountId == savingsId)
    #expect(receivedNew?.type == .expense)
    #expect(receivedNew?.toAccountId == nil)
  }

  // MARK: - Balance Updates with Amount Changes

  @Test func testOnMutateChangingAmount() async throws {
    let tx = Transaction(
      type: .expense, date: makeDate("2024-01-15"), accountId: accountId,
      amount: MonetaryAmount(cents: -5000, currency: Instrument.defaultTestInstrument),
      payee: "Test"
    )
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(transactions: [tx], in: container)
    let store = TransactionStore(repository: backend.transactions)

    var receivedOld: Transaction?
    var receivedNew: Transaction?
    store.onMutate = { old, new in
      receivedOld = old
      receivedNew = new
    }

    await store.load(filter: TransactionFilter(accountId: accountId))

    // Change the amount
    var updated = tx
    updated.amount = MonetaryAmount(cents: -7500, currency: Instrument.defaultTestInstrument)
    await store.update(updated)

    #expect(receivedOld?.amount.cents == -5000)
    #expect(receivedNew?.amount.cents == -7500)
  }

  @Test func testRunningBalancesUpdateAfterAmountChange() async throws {
    let tx1 = Transaction(
      type: .income, date: makeDate("2024-01-01"), accountId: accountId,
      amount: MonetaryAmount(cents: 100000, currency: Instrument.defaultTestInstrument),
      payee: "Salary"
    )
    let tx2 = Transaction(
      type: .expense, date: makeDate("2024-01-15"), accountId: accountId,
      amount: MonetaryAmount(cents: -3000, currency: Instrument.defaultTestInstrument),
      payee: "Coffee"
    )
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(transactions: [tx1, tx2], in: container)
    let store = TransactionStore(repository: backend.transactions)

    await store.load(filter: TransactionFilter(accountId: accountId))
    #expect(store.transactions.count == 2)
    #expect(store.transactions[0].balance.cents == 97000)  // After Coffee
    #expect(store.transactions[1].balance.cents == 100000)  // After Salary

    // Update Coffee amount to -5000
    var updated = tx2
    updated.amount = MonetaryAmount(cents: -5000, currency: Instrument.defaultTestInstrument)
    await store.update(updated)

    #expect(store.transactions.count == 2)
    #expect(store.transactions[0].balance.cents == 95000)  // After updated Coffee
    #expect(store.transactions[1].balance.cents == 100000)  // After Salary (unchanged)
  }

  // MARK: - Pay Scheduled Transaction

  @Test func testPayRecurringTransactionAdvancesDate() async throws {
    let originalDate = makeDate("2024-01-15")
    let scheduled = Transaction(
      type: .expense,
      date: originalDate,
      accountId: accountId,
      amount: MonetaryAmount(cents: -200000, currency: Instrument.defaultTestInstrument),
      payee: "Rent",
      recurPeriod: .month,
      recurEvery: 1
    )
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(transactions: [scheduled], in: container)
    let store = TransactionStore(repository: backend.transactions)

    await store.load(filter: TransactionFilter(scheduled: true))
    #expect(store.transactions.count == 1)

    let result = await store.payScheduledTransaction(scheduled)

    // Store should show the scheduled tx with advanced date
    #expect(store.transactions.count == 1)
    #expect(store.transactions[0].transaction.id == scheduled.id)
    #expect(store.transactions[0].transaction.date == makeDate("2024-02-15"))
    #expect(store.transactions[0].transaction.recurPeriod == .month)

    // Result should return the updated transaction
    guard case .paid(let updated) = result else {
      Issue.record("Expected .paid result, got \(result)")
      return
    }
    #expect(updated?.id == scheduled.id)
    #expect(updated?.date == makeDate("2024-02-15"))

    // Backend should have the paid (non-scheduled) transaction
    let paidPage = try await backend.transactions.fetch(
      filter: TransactionFilter(), page: 0, pageSize: 50)
    #expect(paidPage.transactions.count == 1)

    let paidTx = paidPage.transactions.first
    #expect(paidTx != nil)
    #expect(paidTx?.recurPeriod == nil)
    #expect(paidTx?.recurEvery == nil)
    #expect(paidTx?.payee == "Rent")
    #expect(paidTx?.amount.cents == -200000)

    // Backend should still have the scheduled transaction with advanced date
    let scheduledPage = try await backend.transactions.fetch(
      filter: TransactionFilter(scheduled: true), page: 0, pageSize: 50)
    #expect(scheduledPage.transactions.count == 1)
    #expect(scheduledPage.transactions[0].id == scheduled.id)
  }

  @Test func testPayRecurringWeeklyTransactionAdvancesByWeek() async throws {
    let scheduled = Transaction(
      type: .expense,
      date: makeDate("2024-01-15"),
      accountId: accountId,
      amount: MonetaryAmount(cents: -5000, currency: Instrument.defaultTestInstrument),
      payee: "Groceries",
      recurPeriod: .week,
      recurEvery: 2
    )
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(transactions: [scheduled], in: container)
    let store = TransactionStore(repository: backend.transactions)

    await store.load(filter: TransactionFilter(scheduled: true))
    let result = await store.payScheduledTransaction(scheduled)

    #expect(store.transactions.count == 1)
    #expect(store.transactions[0].transaction.date == makeDate("2024-01-29"))

    guard case .paid(let updated) = result else {
      Issue.record("Expected .paid result")
      return
    }
    #expect(updated?.date == makeDate("2024-01-29"))
  }

  @Test func testPayOneTimeScheduledTransactionDeletesIt() async throws {
    let scheduled = Transaction(
      type: .expense,
      date: makeDate("2024-01-15"),
      accountId: accountId,
      amount: MonetaryAmount(cents: -50000, currency: Instrument.defaultTestInstrument),
      payee: "Annual Fee",
      recurPeriod: .once,
      recurEvery: 1
    )
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(transactions: [scheduled], in: container)
    let store = TransactionStore(repository: backend.transactions)

    await store.load(filter: TransactionFilter(scheduled: true))
    #expect(store.transactions.count == 1)

    let result = await store.payScheduledTransaction(scheduled)

    // Store should show no scheduled transactions (the original was deleted)
    #expect(store.transactions.isEmpty)

    // Result should be .deleted
    guard case .deleted = result else {
      Issue.record("Expected .deleted result, got \(result)")
      return
    }

    // Backend should have only the paid transaction
    let allPage = try await backend.transactions.fetch(
      filter: TransactionFilter(), page: 0, pageSize: 50)
    #expect(allPage.transactions.count == 1)
    #expect(allPage.transactions[0].recurPeriod == nil)
    #expect(allPage.transactions[0].payee == "Annual Fee")
  }

  @Test func testPayPreservesAllTransactionFields() async throws {
    let categoryId = UUID()
    let earmarkId = UUID()
    let toAccountId = UUID()
    let scheduled = Transaction(
      type: .transfer,
      date: makeDate("2024-01-15"),
      accountId: accountId,
      toAccountId: toAccountId,
      amount: MonetaryAmount(cents: -100000, currency: Instrument.defaultTestInstrument),
      payee: "Savings Transfer",
      notes: "Monthly savings",
      categoryId: categoryId,
      earmarkId: earmarkId,
      recurPeriod: .month,
      recurEvery: 1
    )
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(transactions: [scheduled], in: container)
    let store = TransactionStore(repository: backend.transactions)

    await store.load(filter: TransactionFilter(scheduled: true))
    _ = await store.payScheduledTransaction(scheduled)

    // Find the paid (non-scheduled) transaction in the backend
    let allPage = try await backend.transactions.fetch(
      filter: TransactionFilter(), page: 0, pageSize: 50)
    let paidTx = allPage.transactions.first { $0.id != scheduled.id }
    #expect(paidTx != nil)
    #expect(paidTx?.type == .transfer)
    #expect(paidTx?.accountId == accountId)
    #expect(paidTx?.toAccountId == toAccountId)
    #expect(paidTx?.amount.cents == -100000)
    #expect(paidTx?.payee == "Savings Transfer")
    #expect(paidTx?.notes == "Monthly savings")
    #expect(paidTx?.categoryId == categoryId)
    #expect(paidTx?.earmarkId == earmarkId)
    #expect(paidTx?.recurPeriod == nil)
    #expect(paidTx?.recurEvery == nil)
  }

  @Test func testPayFiresOnMutateForCreateAndUpdate() async throws {
    let scheduled = Transaction(
      type: .expense,
      date: makeDate("2024-01-15"),
      accountId: accountId,
      amount: MonetaryAmount(cents: -200000, currency: Instrument.defaultTestInstrument),
      payee: "Rent",
      recurPeriod: .month,
      recurEvery: 1
    )
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(transactions: [scheduled], in: container)
    let store = TransactionStore(repository: backend.transactions)

    var mutations: [(old: Transaction?, new: Transaction?)] = []
    store.onMutate = { old, new in
      mutations.append((old: old, new: new))
    }

    await store.load(filter: TransactionFilter(scheduled: true))
    _ = await store.payScheduledTransaction(scheduled)

    // Should have fired twice: once for create (paid tx), once for update (advance date)
    #expect(mutations.count == 2)

    // First mutation: create paid transaction (old=nil, new=paid)
    #expect(mutations[0].old == nil)
    #expect(mutations[0].new?.recurPeriod == nil)
    #expect(mutations[0].new?.payee == "Rent")

    // Second mutation: update scheduled transaction date (old=original, new=advanced)
    #expect(mutations[1].old?.id == scheduled.id)
    #expect(mutations[1].old?.date == makeDate("2024-01-15"))
    #expect(mutations[1].new?.id == scheduled.id)
    #expect(mutations[1].new?.date == makeDate("2024-02-15"))
  }

  @Test func testPayOneTimeFiresOnMutateForCreateAndDelete() async throws {
    let scheduled = Transaction(
      type: .expense,
      date: makeDate("2024-01-15"),
      accountId: accountId,
      amount: MonetaryAmount(cents: -50000, currency: Instrument.defaultTestInstrument),
      payee: "Annual Fee",
      recurPeriod: .once,
      recurEvery: 1
    )
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(transactions: [scheduled], in: container)
    let store = TransactionStore(repository: backend.transactions)

    var mutations: [(old: Transaction?, new: Transaction?)] = []
    store.onMutate = { old, new in
      mutations.append((old: old, new: new))
    }

    await store.load(filter: TransactionFilter(scheduled: true))
    _ = await store.payScheduledTransaction(scheduled)

    // Should have fired twice: once for create, once for delete
    #expect(mutations.count == 2)

    // First: create (old=nil)
    #expect(mutations[0].old == nil)
    #expect(mutations[0].new?.recurPeriod == nil)

    // Second: delete (new=nil)
    #expect(mutations[1].old?.id == scheduled.id)
    #expect(mutations[1].new == nil)
  }

  // MARK: - Payee Suggestions

  @Test func testFetchPayeeSuggestionsReturnsMatchingPayees() async throws {
    let transactions = [
      Transaction(
        type: .expense, date: makeDate("2024-01-01"), accountId: accountId,
        amount: MonetaryAmount(cents: -5000, currency: Instrument.defaultTestInstrument),
        payee: "Woolworths"),
      Transaction(
        type: .expense, date: makeDate("2024-01-02"), accountId: accountId,
        amount: MonetaryAmount(cents: -3000, currency: Instrument.defaultTestInstrument),
        payee: "Woollies Market"),
      Transaction(
        type: .expense, date: makeDate("2024-01-03"), accountId: accountId,
        amount: MonetaryAmount(cents: -2000, currency: Instrument.defaultTestInstrument),
        payee: "Coles"),
    ]
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(transactions: transactions, in: container)

    let suggestions = try await backend.transactions.fetchPayeeSuggestions(prefix: "Wool")
    #expect(suggestions.count == 2)
    #expect(suggestions.contains("Woolworths"))
    #expect(suggestions.contains("Woollies Market"))
    #expect(!suggestions.contains("Coles"))
  }

  @Test func testPayeeSuggestionsAreSortedByFrequency() async throws {
    let transactions = [
      Transaction(
        type: .expense, date: makeDate("2024-01-01"), accountId: accountId,
        amount: MonetaryAmount(cents: -5000, currency: Instrument.defaultTestInstrument),
        payee: "Woolworths"),
      Transaction(
        type: .expense, date: makeDate("2024-01-02"), accountId: accountId,
        amount: MonetaryAmount(cents: -3000, currency: Instrument.defaultTestInstrument),
        payee: "Woollies Market"),
      Transaction(
        type: .expense, date: makeDate("2024-01-03"), accountId: accountId,
        amount: MonetaryAmount(cents: -4000, currency: Instrument.defaultTestInstrument),
        payee: "Woolworths"),
      Transaction(
        type: .expense, date: makeDate("2024-01-04"), accountId: accountId,
        amount: MonetaryAmount(cents: -6000, currency: Instrument.defaultTestInstrument),
        payee: "Woolworths"),
    ]
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(transactions: transactions, in: container)

    let suggestions = try await backend.transactions.fetchPayeeSuggestions(prefix: "Wool")
    #expect(suggestions.count == 2)
    // Woolworths appears 3 times, Woollies Market once — Woolworths should be first
    #expect(suggestions[0] == "Woolworths")
    #expect(suggestions[1] == "Woollies Market")
  }

  @Test func testFetchTransactionForAutofillReturnsMostRecent() async throws {
    let categoryId = UUID()
    let transactions = [
      Transaction(
        type: .expense, date: makeDate("2024-01-01"), accountId: accountId,
        amount: MonetaryAmount(cents: -3000, currency: Instrument.defaultTestInstrument),
        payee: "Woolworths"),
      Transaction(
        type: .expense, date: makeDate("2024-03-01"), accountId: accountId,
        amount: MonetaryAmount(cents: -7500, currency: Instrument.defaultTestInstrument),
        payee: "Woolworths",
        categoryId: categoryId),
    ]
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(transactions: transactions, in: container)
    let store = TransactionStore(repository: backend.transactions)

    let match = await store.fetchTransactionForAutofill(payee: "Woolworths")
    #expect(match != nil)
    // Most recent (newest first from server) should have the category
    #expect(match?.categoryId == categoryId)
    #expect(match?.amount.cents == -7500)
  }

  @Test func testDebouncedSaveOnlyCallsLastAction() async throws {
    let (backend, _) = try TestBackend.create()
    let store = TransactionStore(repository: backend.transactions)

    var callCount = 0
    var lastValue = ""

    // Rapidly call debouncedSave 3 times — only the last should fire
    store.debouncedSave {
      callCount += 1
      lastValue = "first"
    }
    store.debouncedSave {
      callCount += 1
      lastValue = "second"
    }
    store.debouncedSave {
      callCount += 1
      lastValue = "third"
    }

    // Wait for the debounce delay (300ms) plus a small buffer
    try await Task.sleep(nanoseconds: 500_000_000)

    #expect(callCount == 1)
    #expect(lastValue == "third")
  }

  // MARK: - createDefault

  @Test func testCreateDefaultUsesFilterAccountId() async throws {
    let filterAccountId = UUID()
    let fallbackAccountId = UUID()
    let (backend, _) = try TestBackend.create()
    let store = TransactionStore(repository: backend.transactions)

    await store.load(filter: TransactionFilter(accountId: filterAccountId))

    let created = await store.createDefault(
      accountId: filterAccountId,
      fallbackAccountId: fallbackAccountId,
      instrument: Instrument.defaultTestInstrument
    )

    #expect(created != nil)
    #expect(created?.accountId == filterAccountId)
  }

  @Test func testCreateDefaultFallsBackToFirstAccount() async throws {
    let fallbackAccountId = UUID()
    let (backend, _) = try TestBackend.create()
    let store = TransactionStore(repository: backend.transactions)

    await store.load(filter: TransactionFilter())

    let created = await store.createDefault(
      accountId: nil,
      fallbackAccountId: fallbackAccountId,
      instrument: Instrument.defaultTestInstrument
    )

    #expect(created != nil)
    #expect(created?.accountId == fallbackAccountId)
  }

  @Test func testCreateDefaultSetsExpenseTypeAndZeroAmount() async throws {
    let (backend, _) = try TestBackend.create()
    let store = TransactionStore(repository: backend.transactions)

    await store.load(filter: TransactionFilter())

    let created = await store.createDefault(
      accountId: accountId,
      fallbackAccountId: nil,
      instrument: Instrument.defaultTestInstrument
    )

    #expect(created != nil)
    #expect(created?.type == .expense)
    #expect(created?.amount.cents == 0)
    #expect(created?.amount.currency == Instrument.defaultTestInstrument)
    #expect(created?.payee == "")
  }

  @Test func testCreateDefaultReturnsNilOnFailure() async throws {
    // Use an error-injecting repository to force a failure
    let failingStore = TransactionStore(repository: FailingTransactionRepository())

    let result = await failingStore.createDefault(
      accountId: accountId,
      fallbackAccountId: nil,
      instrument: Instrument.defaultTestInstrument
    )

    #expect(result == nil)
    #expect(failingStore.error != nil)
  }

  @Test func testFetchPayeeSuggestionsEmptyPrefixReturnsEmpty() async throws {
    let transactions = [
      Transaction(
        type: .expense, date: makeDate("2024-01-01"), accountId: accountId,
        amount: MonetaryAmount(cents: -5000, currency: Instrument.defaultTestInstrument),
        payee: "Woolworths")
    ]
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(transactions: transactions, in: container)

    let suggestions = try await backend.transactions.fetchPayeeSuggestions(prefix: "")
    #expect(suggestions.isEmpty)
  }
}

// MARK: - Test helpers

private struct FailingTransactionRepository: TransactionRepository {
  func fetch(filter: TransactionFilter, page: Int, pageSize: Int) async throws -> TransactionPage {
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
