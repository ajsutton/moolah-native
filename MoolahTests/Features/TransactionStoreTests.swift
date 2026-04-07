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
        amount: MonetaryAmount(cents: -(i + 1) * 1000, currency: Currency.defaultCurrency),
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
        type: .expense, date: makeDate("2024-01-01"), accountId: accountId,
        amount: MonetaryAmount(cents: -1000, currency: Currency.defaultCurrency),
        payee: "Mine"),
      Transaction(
        type: .expense, date: makeDate("2024-01-02"), accountId: otherAccountId,
        amount: MonetaryAmount(cents: -2000, currency: Currency.defaultCurrency),
        payee: "Other"),
      Transaction(
        type: .transfer, date: makeDate("2024-01-03"), accountId: otherAccountId,
        toAccountId: accountId,
        amount: MonetaryAmount(cents: -5000, currency: Currency.defaultCurrency),
        payee: "Transfer In"),
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
        type: .expense, date: makeDate("2024-01-01"), accountId: accountId,
        amount: MonetaryAmount(cents: -1000, currency: Currency.defaultCurrency),
        payee: "Oldest"),
      Transaction(
        type: .expense, date: makeDate("2024-01-15"), accountId: accountId,
        amount: MonetaryAmount(cents: -2000, currency: Currency.defaultCurrency),
        payee: "Middle"),
      Transaction(
        type: .expense, date: makeDate("2024-01-30"), accountId: accountId,
        amount: MonetaryAmount(cents: -3000, currency: Currency.defaultCurrency),
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
        type: .income, date: makeDate("2024-01-03"), accountId: accountId,
        amount: MonetaryAmount(cents: 100000, currency: Currency.defaultCurrency),
        payee: "Salary"),
      Transaction(
        type: .expense, date: makeDate("2024-01-02"), accountId: accountId,
        amount: MonetaryAmount(cents: -2500, currency: Currency.defaultCurrency),
        payee: "Coffee"),
      Transaction(
        type: .expense, date: makeDate("2024-01-01"), accountId: accountId,
        amount: MonetaryAmount(cents: -10000, currency: Currency.defaultCurrency),
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
    #expect(
      store.transactions[0].balance
        == MonetaryAmount(cents: 87500, currency: Currency.defaultCurrency))  // After Salary
    #expect(
      store.transactions[1].balance
        == MonetaryAmount(cents: -12500, currency: Currency.defaultCurrency))  // After Coffee
    #expect(
      store.transactions[2].balance
        == MonetaryAmount(cents: -10000, currency: Currency.defaultCurrency))  // After Groceries
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

  // MARK: - CRUD

  @Test func testCreateAddsTransaction() async throws {
    let repository = InMemoryTransactionRepository()
    let store = TransactionStore(repository: repository)

    await store.load(filter: TransactionFilter(accountId: accountId))
    #expect(store.transactions.isEmpty)

    let tx = Transaction(
      type: .expense, date: makeDate("2024-01-15"), accountId: accountId,
      amount: MonetaryAmount(cents: -5000, currency: Currency.defaultCurrency),
      payee: "Coffee Shop"
    )
    await store.create(tx)

    #expect(store.transactions.count == 1)
    #expect(store.transactions[0].transaction.payee == "Coffee Shop")
    #expect(store.error == nil)
  }

  @Test func testUpdateModifiesTransaction() async throws {
    let tx = Transaction(
      type: .expense, date: makeDate("2024-01-15"), accountId: accountId,
      amount: MonetaryAmount(cents: -5000, currency: Currency.defaultCurrency),
      payee: "Coffee Shop"
    )
    let repository = InMemoryTransactionRepository(initialTransactions: [tx])
    let store = TransactionStore(repository: repository)

    await store.load(filter: TransactionFilter(accountId: accountId))
    #expect(store.transactions.count == 1)

    var updated = tx
    updated.payee = "Fancy Coffee"
    updated.amount = MonetaryAmount(cents: -7500, currency: Currency.defaultCurrency)
    await store.update(updated)

    #expect(store.transactions.count == 1)
    #expect(store.transactions[0].transaction.payee == "Fancy Coffee")
    #expect(store.transactions[0].transaction.amount.cents == -7500)
    #expect(store.error == nil)
  }

  @Test func testDeleteRemovesTransaction() async throws {
    let tx = Transaction(
      type: .expense, date: makeDate("2024-01-15"), accountId: accountId,
      amount: MonetaryAmount(cents: -5000, currency: Currency.defaultCurrency),
      payee: "Coffee Shop"
    )
    let repository = InMemoryTransactionRepository(initialTransactions: [tx])
    let store = TransactionStore(repository: repository)

    await store.load(filter: TransactionFilter(accountId: accountId))
    #expect(store.transactions.count == 1)

    await store.delete(id: tx.id)

    #expect(store.transactions.isEmpty)
    #expect(store.error == nil)
  }

  @Test func testCreateUpdateDeleteCycle() async throws {
    let repository = InMemoryTransactionRepository()
    let store = TransactionStore(repository: repository)

    await store.load(filter: TransactionFilter(accountId: accountId))

    // Create
    let tx = Transaction(
      type: .income, date: makeDate("2024-01-10"), accountId: accountId,
      amount: MonetaryAmount(cents: 100000, currency: Currency.defaultCurrency),
      payee: "Salary"
    )
    await store.create(tx)
    #expect(store.transactions.count == 1)

    // Update
    var modified = tx
    modified.amount = MonetaryAmount(cents: 110000, currency: Currency.defaultCurrency)
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
      amount: MonetaryAmount(cents: 100000, currency: Currency.defaultCurrency),
      payee: "Initial"
    )
    let repository = InMemoryTransactionRepository(initialTransactions: [existing])
    let store = TransactionStore(repository: repository)

    await store.load(filter: TransactionFilter(accountId: accountId))
    #expect(store.transactions[0].balance.cents == 100000)

    // Add a newer expense
    let expense = Transaction(
      type: .expense, date: makeDate("2024-01-15"), accountId: accountId,
      amount: MonetaryAmount(cents: -3000, currency: Currency.defaultCurrency),
      payee: "Coffee"
    )
    await store.create(expense)

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
      amount: MonetaryAmount(cents: 100000, currency: Currency.defaultCurrency),
      payee: "Salary"
    )
    let tx2 = Transaction(
      type: .expense, date: makeDate("2024-01-15"), accountId: accountId,
      amount: MonetaryAmount(cents: -3000, currency: Currency.defaultCurrency),
      payee: "Coffee"
    )
    let repository = InMemoryTransactionRepository(initialTransactions: [tx1, tx2])
    let store = TransactionStore(repository: repository)

    await store.load(filter: TransactionFilter(accountId: accountId))
    #expect(store.transactions.count == 2)
    #expect(store.transactions[0].balance.cents == 97000)  // After Coffee

    // Delete the expense — balance should revert
    await store.delete(id: tx2.id)
    #expect(store.transactions.count == 1)
    #expect(store.transactions[0].balance.cents == 100000)  // Only Salary remains
  }

  @Test func testOnMutatePassesNilOldOnCreate() async throws {
    let repository = InMemoryTransactionRepository()
    let store = TransactionStore(repository: repository)

    var receivedOld: Transaction?? = .none  // .none = not called, .some(nil) = called with nil
    var receivedNew: Transaction?
    store.onMutate = { old, new in
      receivedOld = old
      receivedNew = new
    }

    await store.load(filter: TransactionFilter(accountId: accountId))

    let tx = Transaction(
      type: .expense, date: makeDate("2024-01-15"), accountId: accountId,
      amount: MonetaryAmount(cents: -5000, currency: Currency.defaultCurrency),
      payee: "Test"
    )
    await store.create(tx)
    #expect(receivedOld == .some(nil))
    #expect(receivedNew?.id == tx.id)
  }

  @Test func testOnMutatePassesBothOnUpdate() async throws {
    let tx = Transaction(
      type: .expense, date: makeDate("2024-01-15"), accountId: accountId,
      amount: MonetaryAmount(cents: -5000, currency: Currency.defaultCurrency),
      payee: "Test"
    )
    let repository = InMemoryTransactionRepository(initialTransactions: [tx])
    let store = TransactionStore(repository: repository)

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
      amount: MonetaryAmount(cents: -5000, currency: Currency.defaultCurrency),
      payee: "Test"
    )
    let repository = InMemoryTransactionRepository(initialTransactions: [tx])
    let store = TransactionStore(repository: repository)

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
      amount: MonetaryAmount(cents: -10000, currency: Currency.defaultCurrency),
      payee: ""
    )
    let repository = InMemoryTransactionRepository(initialTransactions: [tx])
    let store = TransactionStore(repository: repository)

    var receivedOld: Transaction?
    var receivedNew: Transaction?
    store.onMutate = { old, new in
      receivedOld = old
      receivedNew = new
    }

    await store.load(filter: TransactionFilter(accountId: accountId))

    // Update the transfer amount
    var updated = tx
    updated.amount = MonetaryAmount(cents: -15000, currency: Currency.defaultCurrency)
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
      amount: MonetaryAmount(cents: -10000, currency: Currency.defaultCurrency),
      payee: ""
    )
    let repository = InMemoryTransactionRepository(initialTransactions: [tx])
    let store = TransactionStore(repository: repository)

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
      amount: MonetaryAmount(cents: -5000, currency: Currency.defaultCurrency),
      payee: "Test"
    )
    let repository = InMemoryTransactionRepository(initialTransactions: [tx])
    let store = TransactionStore(repository: repository)

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
      amount: MonetaryAmount(cents: -5000, currency: Currency.defaultCurrency),
      payee: "Test",
      earmarkId: earmarkId
    )
    let repository = InMemoryTransactionRepository(initialTransactions: [tx])
    let store = TransactionStore(repository: repository)

    var receivedOld: Transaction?
    var receivedNew: Transaction?
    store.onMutate = { old, new in
      receivedOld = old
      receivedNew = new
    }

    await store.load(filter: TransactionFilter(accountId: accountId))

    // Update the amount
    var updated = tx
    updated.amount = MonetaryAmount(cents: -7500, currency: Currency.defaultCurrency)
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
      amount: MonetaryAmount(cents: -5000, currency: Currency.defaultCurrency),
      payee: "Test",
      earmarkId: earmarkId1
    )
    let repository = InMemoryTransactionRepository(initialTransactions: [tx])
    let store = TransactionStore(repository: repository)

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
      amount: MonetaryAmount(cents: -5000, currency: Currency.defaultCurrency),
      payee: "Test"
    )
    let repository = InMemoryTransactionRepository(initialTransactions: [tx])
    let store = TransactionStore(repository: repository)

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
      amount: MonetaryAmount(cents: -5000, currency: Currency.defaultCurrency),
      payee: "Test",
      earmarkId: earmarkId
    )
    let repository = InMemoryTransactionRepository(initialTransactions: [tx])
    let store = TransactionStore(repository: repository)

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
      amount: MonetaryAmount(cents: -5000, currency: Currency.defaultCurrency),
      payee: "Test"
    )
    let repository = InMemoryTransactionRepository(initialTransactions: [tx])
    let store = TransactionStore(repository: repository)

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
    updated.amount = MonetaryAmount(cents: 5000, currency: Currency.defaultCurrency)
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
      amount: MonetaryAmount(cents: -5000, currency: Currency.defaultCurrency),
      payee: "Test"
    )
    let repository = InMemoryTransactionRepository(initialTransactions: [tx])
    let store = TransactionStore(repository: repository)

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
      amount: MonetaryAmount(cents: -5000, currency: Currency.defaultCurrency),
      payee: ""
    )
    let repository = InMemoryTransactionRepository(initialTransactions: [tx])
    let store = TransactionStore(repository: repository)

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
      amount: MonetaryAmount(cents: -5000, currency: Currency.defaultCurrency),
      payee: "Test"
    )
    let repository = InMemoryTransactionRepository(initialTransactions: [tx])
    let store = TransactionStore(repository: repository)

    var receivedOld: Transaction?
    var receivedNew: Transaction?
    store.onMutate = { old, new in
      receivedOld = old
      receivedNew = new
    }

    await store.load(filter: TransactionFilter(accountId: accountId))

    // Change the amount
    var updated = tx
    updated.amount = MonetaryAmount(cents: -7500, currency: Currency.defaultCurrency)
    await store.update(updated)

    #expect(receivedOld?.amount.cents == -5000)
    #expect(receivedNew?.amount.cents == -7500)
  }

  @Test func testRunningBalancesUpdateAfterAmountChange() async throws {
    let tx1 = Transaction(
      type: .income, date: makeDate("2024-01-01"), accountId: accountId,
      amount: MonetaryAmount(cents: 100000, currency: Currency.defaultCurrency),
      payee: "Salary"
    )
    let tx2 = Transaction(
      type: .expense, date: makeDate("2024-01-15"), accountId: accountId,
      amount: MonetaryAmount(cents: -3000, currency: Currency.defaultCurrency),
      payee: "Coffee"
    )
    let repository = InMemoryTransactionRepository(initialTransactions: [tx1, tx2])
    let store = TransactionStore(repository: repository)

    await store.load(filter: TransactionFilter(accountId: accountId))
    #expect(store.transactions.count == 2)
    #expect(store.transactions[0].balance.cents == 97000)  // After Coffee
    #expect(store.transactions[1].balance.cents == 100000)  // After Salary

    // Update Coffee amount to -5000
    var updated = tx2
    updated.amount = MonetaryAmount(cents: -5000, currency: Currency.defaultCurrency)
    await store.update(updated)

    #expect(store.transactions.count == 2)
    #expect(store.transactions[0].balance.cents == 95000)  // After updated Coffee
    #expect(store.transactions[1].balance.cents == 100000)  // After Salary (unchanged)
  }
}
