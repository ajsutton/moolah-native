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
        date: makeDate("2024-01-\(String(format: "%02d", min(i + 1, 28)))"),
        payee: "Payee \(i)",
        legs: [
          TransactionLeg(
            accountId: accountId,
            instrument: Instrument.defaultTestInstrument,
            quantity: Decimal(-(i + 1) * 1000) / 100,
            type: .expense
          )
        ]
      )
    }
  }

  @Test func testLoadsFirstPage() async throws {
    let transactions = seedTransactions(count: 3, accountId: accountId)
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(transactions: transactions, in: container)
    let store = TransactionStore(
      repository: backend.transactions,
      conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument
    )

    await store.load(filter: TransactionFilter(accountId: accountId))

    #expect(store.transactions.count == 3)
    #expect(!store.isLoading)

    // Each entry should have a running balance
    for entry in store.transactions {
      #expect(entry.transaction.accountIds.contains(accountId))
    }
  }

  @Test func testPaginationAppendsSecondPage() async throws {
    // Create more transactions than one page
    let transactions = seedTransactions(count: 5, accountId: accountId)
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(transactions: transactions, in: container)
    let store = TransactionStore(
      repository: backend.transactions,
      conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument,
      pageSize: 3
    )

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
    let store = TransactionStore(
      repository: backend.transactions,
      conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument,
      pageSize: 10
    )

    await store.load(filter: TransactionFilter(accountId: accountId))

    #expect(store.transactions.count == 2)
    #expect(store.hasMore == false)
  }

  @Test func testLoadMoreDoesNothingWhenNoMore() async throws {
    let transactions = seedTransactions(count: 2, accountId: accountId)
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(transactions: transactions, in: container)
    let store = TransactionStore(
      repository: backend.transactions,
      conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument,
      pageSize: 10
    )

    await store.load(filter: TransactionFilter(accountId: accountId))
    #expect(store.hasMore == false)

    await store.loadMore()
    #expect(store.transactions.count == 2)  // No duplicates
  }

  @Test func testFilterByAccountId() async throws {
    let otherAccountId = UUID()
    let transactions = [
      Transaction(
        date: makeDate("2024-01-01"),
        payee: "Mine",
        legs: [
          TransactionLeg(
            accountId: accountId,
            instrument: Instrument.defaultTestInstrument,
            quantity: Decimal(-1000) / 100,
            type: .expense
          )
        ]
      ),
      Transaction(
        date: makeDate("2024-01-02"),
        payee: "Other",
        legs: [
          TransactionLeg(
            accountId: otherAccountId,
            instrument: Instrument.defaultTestInstrument,
            quantity: Decimal(-2000) / 100,
            type: .expense
          )
        ]
      ),
      Transaction(
        date: makeDate("2024-01-03"),
        payee: "Transfer In",
        legs: [
          TransactionLeg(
            accountId: otherAccountId,
            instrument: Instrument.defaultTestInstrument,
            quantity: Decimal(-5000) / 100,
            type: .transfer
          ),
          TransactionLeg(
            accountId: accountId,
            instrument: Instrument.defaultTestInstrument,
            quantity: Decimal(5000) / 100,
            type: .transfer
          ),
        ]
      ),
    ]
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(transactions: transactions, in: container)
    let store = TransactionStore(
      repository: backend.transactions,
      conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument
    )

    await store.load(filter: TransactionFilter(accountId: accountId))

    #expect(store.transactions.count == 2)  // Direct + transfer-in
    let payees = store.transactions.map(\.transaction.payee)
    #expect(payees.contains("Mine"))
    #expect(payees.contains("Transfer In"))
  }

  @Test func testSortedByDateDescending() async throws {
    let transactions = [
      Transaction(
        date: makeDate("2024-01-01"),
        payee: "Oldest",
        legs: [
          TransactionLeg(
            accountId: accountId,
            instrument: Instrument.defaultTestInstrument,
            quantity: Decimal(-1000) / 100,
            type: .expense
          )
        ]
      ),
      Transaction(
        date: makeDate("2024-01-15"),
        payee: "Middle",
        legs: [
          TransactionLeg(
            accountId: accountId,
            instrument: Instrument.defaultTestInstrument,
            quantity: Decimal(-2000) / 100,
            type: .expense
          )
        ]
      ),
      Transaction(
        date: makeDate("2024-01-30"),
        payee: "Newest",
        legs: [
          TransactionLeg(
            accountId: accountId,
            instrument: Instrument.defaultTestInstrument,
            quantity: Decimal(-3000) / 100,
            type: .expense
          )
        ]
      ),
    ]
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(transactions: transactions, in: container)
    let store = TransactionStore(
      repository: backend.transactions,
      conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument
    )

    await store.load(filter: TransactionFilter(accountId: accountId))

    #expect(store.transactions[0].transaction.payee == "Newest")
    #expect(store.transactions[1].transaction.payee == "Middle")
    #expect(store.transactions[2].transaction.payee == "Oldest")
  }

  @Test func testRunningBalancesComputed() async throws {
    let transactions = [
      Transaction(
        date: makeDate("2024-01-03"),
        payee: "Salary",
        legs: [
          TransactionLeg(
            accountId: accountId,
            instrument: Instrument.defaultTestInstrument,
            quantity: Decimal(100000) / 100,
            type: .income
          )
        ]
      ),
      Transaction(
        date: makeDate("2024-01-02"),
        payee: "Coffee",
        legs: [
          TransactionLeg(
            accountId: accountId,
            instrument: Instrument.defaultTestInstrument,
            quantity: Decimal(-2500) / 100,
            type: .expense
          )
        ]
      ),
      Transaction(
        date: makeDate("2024-01-01"),
        payee: "Groceries",
        legs: [
          TransactionLeg(
            accountId: accountId,
            instrument: Instrument.defaultTestInstrument,
            quantity: Decimal(-10000) / 100,
            type: .expense
          )
        ]
      ),
    ]
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(transactions: transactions, in: container)
    let store = TransactionStore(
      repository: backend.transactions,
      conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument
    )

    await store.load(filter: TransactionFilter(accountId: accountId))

    #expect(store.transactions.count == 3)

    // Transactions are newest-first; balance is the running total after each tx
    // priorBalance = 0 (no older transactions)
    // Groceries (oldest): 0 + (-10000) = -10000
    // Coffee: -10000 + (-2500) = -12500
    // Salary (newest): -12500 + 100000 = 87500
    #expect(
      store.transactions[0].balance
        == InstrumentAmount(
          quantity: Decimal(87500) / 100, instrument: Instrument.defaultTestInstrument))  // After Salary
    #expect(
      store.transactions[1].balance
        == InstrumentAmount(
          quantity: Decimal(-12500) / 100, instrument: Instrument.defaultTestInstrument))  // After Coffee
    #expect(
      store.transactions[2].balance
        == InstrumentAmount(
          quantity: Decimal(-10000) / 100, instrument: Instrument.defaultTestInstrument))  // After Groceries
  }

  @Test func testReloadClearsExisting() async throws {
    let transactions = seedTransactions(count: 5, accountId: accountId)
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(transactions: transactions, in: container)
    let store = TransactionStore(
      repository: backend.transactions,
      conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument,
      pageSize: 3
    )

    await store.load(filter: TransactionFilter(accountId: accountId))
    #expect(store.transactions.count == 3)

    // Reload should start fresh
    await store.load(filter: TransactionFilter(accountId: accountId))
    #expect(store.transactions.count == 3)
  }

  // MARK: - CRUD

  @Test func testCreateAddsTransaction() async throws {
    let (backend, _) = try TestBackend.create()
    let store = TransactionStore(
      repository: backend.transactions,
      conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument
    )

    await store.load(filter: TransactionFilter(accountId: accountId))
    #expect(store.transactions.isEmpty)

    let tx = Transaction(
      date: makeDate("2024-01-15"),
      payee: "Coffee Shop",
      legs: [
        TransactionLeg(
          accountId: accountId,
          instrument: Instrument.defaultTestInstrument,
          quantity: Decimal(-5000) / 100,
          type: .expense
        )
      ]
    )
    _ = await store.create(tx)

    #expect(store.transactions.count == 1)
    #expect(store.transactions[0].transaction.payee == "Coffee Shop")
    #expect(store.error == nil)
  }

  @Test func testUpdateModifiesTransaction() async throws {
    let tx = Transaction(
      date: makeDate("2024-01-15"),
      payee: "Coffee Shop",
      legs: [
        TransactionLeg(
          accountId: accountId,
          instrument: Instrument.defaultTestInstrument,
          quantity: Decimal(-5000) / 100,
          type: .expense
        )
      ]
    )
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(transactions: [tx], in: container)
    let store = TransactionStore(
      repository: backend.transactions,
      conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument
    )

    await store.load(filter: TransactionFilter(accountId: accountId))
    #expect(store.transactions.count == 1)

    var updated = tx
    updated.payee = "Fancy Coffee"
    updated.legs = [
      TransactionLeg(
        accountId: accountId,
        instrument: Instrument.defaultTestInstrument,
        quantity: Decimal(-7500) / 100,
        type: .expense
      )
    ]
    await store.update(updated)

    #expect(store.transactions.count == 1)
    #expect(store.transactions[0].transaction.payee == "Fancy Coffee")
    #expect(store.transactions[0].displayAmount.quantity == Decimal(-7500) / 100)
    #expect(store.error == nil)
  }

  @Test func testDeleteRemovesTransaction() async throws {
    let tx = Transaction(
      date: makeDate("2024-01-15"),
      payee: "Coffee Shop",
      legs: [
        TransactionLeg(
          accountId: accountId,
          instrument: Instrument.defaultTestInstrument,
          quantity: Decimal(-5000) / 100,
          type: .expense
        )
      ]
    )
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(transactions: [tx], in: container)
    let store = TransactionStore(
      repository: backend.transactions,
      conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument
    )

    await store.load(filter: TransactionFilter(accountId: accountId))
    #expect(store.transactions.count == 1)

    await store.delete(id: tx.id)

    #expect(store.transactions.isEmpty)
    #expect(store.error == nil)
  }

  @Test func testCreateUpdateDeleteCycle() async throws {
    let (backend, _) = try TestBackend.create()
    let store = TransactionStore(
      repository: backend.transactions,
      conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument
    )

    await store.load(filter: TransactionFilter(accountId: accountId))

    // Create
    let tx = Transaction(
      date: makeDate("2024-01-10"),
      payee: "Salary",
      legs: [
        TransactionLeg(
          accountId: accountId,
          instrument: Instrument.defaultTestInstrument,
          quantity: Decimal(100000) / 100,
          type: .income
        )
      ]
    )
    _ = await store.create(tx)
    #expect(store.transactions.count == 1)

    // Update
    var modified = tx
    modified.legs = [
      TransactionLeg(
        accountId: accountId,
        instrument: Instrument.defaultTestInstrument,
        quantity: Decimal(110000) / 100,
        type: .income
      )
    ]
    await store.update(modified)
    #expect(store.transactions.count == 1)
    #expect(store.transactions[0].displayAmount.quantity == Decimal(110000) / 100)

    // Delete
    await store.delete(id: tx.id)
    #expect(store.transactions.isEmpty)
  }

  @Test func testRunningBalancesUpdateAfterCreate() async throws {
    let existing = Transaction(
      date: makeDate("2024-01-01"),
      payee: "Initial",
      legs: [
        TransactionLeg(
          accountId: accountId,
          instrument: Instrument.defaultTestInstrument,
          quantity: Decimal(100000) / 100,
          type: .income
        )
      ]
    )
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(transactions: [existing], in: container)
    let store = TransactionStore(
      repository: backend.transactions,
      conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument
    )

    await store.load(filter: TransactionFilter(accountId: accountId))
    #expect(store.transactions[0].balance.quantity == Decimal(100000) / 100)

    // Add a newer expense
    let expense = Transaction(
      date: makeDate("2024-01-15"),
      payee: "Coffee",
      legs: [
        TransactionLeg(
          accountId: accountId,
          instrument: Instrument.defaultTestInstrument,
          quantity: Decimal(-3000) / 100,
          type: .expense
        )
      ]
    )
    _ = await store.create(expense)

    // Newest first: expense (balance 97000), then income (balance 100000)
    #expect(store.transactions.count == 2)
    #expect(store.transactions[0].transaction.payee == "Coffee")
    #expect(store.transactions[0].balance.quantity == Decimal(97000) / 100)
    #expect(store.transactions[1].transaction.payee == "Initial")
    #expect(store.transactions[1].balance.quantity == Decimal(100000) / 100)
  }

  @Test func testRunningBalancesUpdateAfterDelete() async throws {
    let tx1 = Transaction(
      date: makeDate("2024-01-01"),
      payee: "Salary",
      legs: [
        TransactionLeg(
          accountId: accountId,
          instrument: Instrument.defaultTestInstrument,
          quantity: Decimal(100000) / 100,
          type: .income
        )
      ]
    )
    let tx2 = Transaction(
      date: makeDate("2024-01-15"),
      payee: "Coffee",
      legs: [
        TransactionLeg(
          accountId: accountId,
          instrument: Instrument.defaultTestInstrument,
          quantity: Decimal(-3000) / 100,
          type: .expense
        )
      ]
    )
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(transactions: [tx1, tx2], in: container)
    let store = TransactionStore(
      repository: backend.transactions,
      conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument
    )

    await store.load(filter: TransactionFilter(accountId: accountId))
    #expect(store.transactions.count == 2)
    #expect(store.transactions[0].balance.quantity == Decimal(97000) / 100)  // After Coffee

    // Delete the expense — balance should revert
    await store.delete(id: tx2.id)
    #expect(store.transactions.count == 1)
    #expect(store.transactions[0].balance.quantity == Decimal(100000) / 100)  // Only Salary remains
  }

  @Test func testOnMutatePassesNilOldOnCreate() async throws {
    let (backend, _) = try TestBackend.create()
    let store = TransactionStore(
      repository: backend.transactions,
      conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument
    )

    var receivedOld: Transaction?? = .none  // .none = not called, .some(nil) = called with nil
    var receivedNew: Transaction?
    store.onMutate = { old, new in
      receivedOld = old
      receivedNew = new
    }

    await store.load(filter: TransactionFilter(accountId: accountId))

    let tx = Transaction(
      date: makeDate("2024-01-15"),
      payee: "Test",
      legs: [
        TransactionLeg(
          accountId: accountId,
          instrument: Instrument.defaultTestInstrument,
          quantity: Decimal(-5000) / 100,
          type: .expense
        )
      ]
    )
    _ = await store.create(tx)
    #expect(receivedOld == .some(nil))
    #expect(receivedNew?.id == tx.id)
  }

  @Test func testOnMutatePassesBothOnUpdate() async throws {
    let tx = Transaction(
      date: makeDate("2024-01-15"),
      payee: "Test",
      legs: [
        TransactionLeg(
          accountId: accountId,
          instrument: Instrument.defaultTestInstrument,
          quantity: Decimal(-5000) / 100,
          type: .expense
        )
      ]
    )
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(transactions: [tx], in: container)
    let store = TransactionStore(
      repository: backend.transactions,
      conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument
    )

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
      date: makeDate("2024-01-15"),
      payee: "Test",
      legs: [
        TransactionLeg(
          accountId: accountId,
          instrument: Instrument.defaultTestInstrument,
          quantity: Decimal(-5000) / 100,
          type: .expense
        )
      ]
    )
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(transactions: [tx], in: container)
    let store = TransactionStore(
      repository: backend.transactions,
      conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument
    )

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
      date: makeDate("2024-01-15"),
      payee: "",
      legs: [
        TransactionLeg(
          accountId: accountId,
          instrument: Instrument.defaultTestInstrument,
          quantity: Decimal(-10000) / 100,
          type: .transfer
        ),
        TransactionLeg(
          accountId: savingsId,
          instrument: Instrument.defaultTestInstrument,
          quantity: Decimal(10000) / 100,
          type: .transfer
        ),
      ]
    )
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(transactions: [tx], in: container)
    let store = TransactionStore(
      repository: backend.transactions,
      conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument
    )

    var receivedOld: Transaction?
    var receivedNew: Transaction?
    store.onMutate = { old, new in
      receivedOld = old
      receivedNew = new
    }

    await store.load(filter: TransactionFilter(accountId: accountId))

    // Update the transfer amount
    var updated = tx
    updated.legs = [
      TransactionLeg(
        accountId: accountId,
        instrument: Instrument.defaultTestInstrument,
        quantity: Decimal(-15000) / 100,
        type: .transfer
      ),
      TransactionLeg(
        accountId: savingsId,
        instrument: Instrument.defaultTestInstrument,
        quantity: Decimal(15000) / 100,
        type: .transfer
      ),
    ]
    await store.update(updated)

    #expect(receivedOld?.id == tx.id)
    #expect(receivedOld?.legs.first?.quantity == Decimal(-10000) / 100)
    #expect(
      receivedOld?.legs.first(where: { $0.accountId != accountId })?.accountId
        == savingsId)
    #expect(receivedNew?.legs.first?.quantity == Decimal(-15000) / 100)
    #expect(
      receivedNew?.legs.first(where: { $0.accountId != accountId })?.accountId
        == savingsId)
  }

  @Test func testOnMutateChangingTransferToAccount() async throws {
    let savingsId = UUID()
    let investmentId = UUID()
    let tx = Transaction(
      date: makeDate("2024-01-15"),
      payee: "",
      legs: [
        TransactionLeg(
          accountId: accountId,
          instrument: Instrument.defaultTestInstrument,
          quantity: Decimal(-10000) / 100,
          type: .transfer
        ),
        TransactionLeg(
          accountId: savingsId,
          instrument: Instrument.defaultTestInstrument,
          quantity: Decimal(10000) / 100,
          type: .transfer
        ),
      ]
    )
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(transactions: [tx], in: container)
    let store = TransactionStore(
      repository: backend.transactions,
      conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument
    )

    var receivedOld: Transaction?
    var receivedNew: Transaction?
    store.onMutate = { old, new in
      receivedOld = old
      receivedNew = new
    }

    await store.load(filter: TransactionFilter(accountId: accountId))

    // Change the toAccountId
    var updated = tx
    updated.legs = [
      TransactionLeg(
        accountId: accountId,
        instrument: Instrument.defaultTestInstrument,
        quantity: Decimal(-10000) / 100,
        type: .transfer
      ),
      TransactionLeg(
        accountId: investmentId,
        instrument: Instrument.defaultTestInstrument,
        quantity: Decimal(10000) / 100,
        type: .transfer
      ),
    ]
    await store.update(updated)

    #expect(
      receivedOld?.legs.first(where: { $0.accountId != accountId })?.accountId
        == savingsId)
    #expect(
      receivedNew?.legs.first(where: { $0.accountId != accountId })?.accountId
        == investmentId)
  }

  @Test func testOnMutateChangingFromAccountId() async throws {
    let newAccountId = UUID()
    let tx = Transaction(
      date: makeDate("2024-01-15"),
      payee: "Test",
      legs: [
        TransactionLeg(
          accountId: accountId,
          instrument: Instrument.defaultTestInstrument,
          quantity: Decimal(-5000) / 100,
          type: .expense
        )
      ]
    )
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(transactions: [tx], in: container)
    let store = TransactionStore(
      repository: backend.transactions,
      conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument
    )

    var receivedOld: Transaction?
    var receivedNew: Transaction?
    store.onMutate = { old, new in
      receivedOld = old
      receivedNew = new
    }

    await store.load(filter: TransactionFilter(accountId: accountId))

    // Change the accountId
    var updated = tx
    updated.legs = [
      TransactionLeg(
        accountId: newAccountId,
        instrument: Instrument.defaultTestInstrument,
        quantity: Decimal(-5000) / 100,
        type: .expense
      )
    ]
    await store.update(updated)

    #expect(receivedOld?.accountIds.contains(accountId) == true)
    #expect(receivedNew?.accountIds.contains(newAccountId) == true)
  }

  // MARK: - Balance Updates with Earmarks

  @Test func testOnMutateWithEarmark() async throws {
    let earmarkId = UUID()
    let tx = Transaction(
      date: makeDate("2024-01-15"),
      payee: "Test",
      legs: [
        TransactionLeg(
          accountId: accountId,
          instrument: Instrument.defaultTestInstrument,
          quantity: Decimal(-5000) / 100,
          type: .expense,
          earmarkId: earmarkId
        )
      ]
    )
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(transactions: [tx], in: container)
    let store = TransactionStore(
      repository: backend.transactions,
      conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument
    )

    var receivedOld: Transaction?
    var receivedNew: Transaction?
    store.onMutate = { old, new in
      receivedOld = old
      receivedNew = new
    }

    await store.load(filter: TransactionFilter(accountId: accountId))

    // Update the amount
    var updated = tx
    updated.legs = [
      TransactionLeg(
        accountId: accountId,
        instrument: Instrument.defaultTestInstrument,
        quantity: Decimal(-7500) / 100,
        type: .expense,
        earmarkId: earmarkId
      )
    ]
    await store.update(updated)

    #expect(receivedOld?.earmarkId == earmarkId)
    #expect(receivedOld?.legs.first?.quantity == Decimal(-5000) / 100)
    #expect(receivedNew?.earmarkId == earmarkId)
    #expect(receivedNew?.legs.first?.quantity == Decimal(-7500) / 100)
  }

  @Test func testOnMutateChangingEarmarkId() async throws {
    let earmarkId1 = UUID()
    let earmarkId2 = UUID()
    let tx = Transaction(
      date: makeDate("2024-01-15"),
      payee: "Test",
      legs: [
        TransactionLeg(
          accountId: accountId,
          instrument: Instrument.defaultTestInstrument,
          quantity: Decimal(-5000) / 100,
          type: .expense,
          earmarkId: earmarkId1
        )
      ]
    )
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(transactions: [tx], in: container)
    let store = TransactionStore(
      repository: backend.transactions,
      conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument
    )

    var receivedOld: Transaction?
    var receivedNew: Transaction?
    store.onMutate = { old, new in
      receivedOld = old
      receivedNew = new
    }

    await store.load(filter: TransactionFilter(accountId: accountId))

    // Change the earmarkId
    var updated = tx
    updated.legs = [
      TransactionLeg(
        accountId: accountId,
        instrument: Instrument.defaultTestInstrument,
        quantity: Decimal(-5000) / 100,
        type: .expense,
        earmarkId: earmarkId2
      )
    ]
    await store.update(updated)

    #expect(receivedOld?.earmarkId == earmarkId1)
    #expect(receivedNew?.earmarkId == earmarkId2)
  }

  @Test func testOnMutateAddingEarmark() async throws {
    let earmarkId = UUID()
    let tx = Transaction(
      date: makeDate("2024-01-15"),
      payee: "Test",
      legs: [
        TransactionLeg(
          accountId: accountId,
          instrument: Instrument.defaultTestInstrument,
          quantity: Decimal(-5000) / 100,
          type: .expense
        )
      ]
    )
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(transactions: [tx], in: container)
    let store = TransactionStore(
      repository: backend.transactions,
      conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument
    )

    var receivedOld: Transaction?
    var receivedNew: Transaction?
    store.onMutate = { old, new in
      receivedOld = old
      receivedNew = new
    }

    await store.load(filter: TransactionFilter(accountId: accountId))

    // Add an earmarkId
    var updated = tx
    updated.legs = [
      TransactionLeg(
        accountId: accountId,
        instrument: Instrument.defaultTestInstrument,
        quantity: Decimal(-5000) / 100,
        type: .expense,
        earmarkId: earmarkId
      )
    ]
    await store.update(updated)

    #expect(receivedOld?.earmarkId == nil)
    #expect(receivedNew?.earmarkId == earmarkId)
  }

  @Test func testOnMutateRemovingEarmark() async throws {
    let earmarkId = UUID()
    let tx = Transaction(
      date: makeDate("2024-01-15"),
      payee: "Test",
      legs: [
        TransactionLeg(
          accountId: accountId,
          instrument: Instrument.defaultTestInstrument,
          quantity: Decimal(-5000) / 100,
          type: .expense,
          earmarkId: earmarkId
        )
      ]
    )
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(transactions: [tx], in: container)
    let store = TransactionStore(
      repository: backend.transactions,
      conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument
    )

    var receivedOld: Transaction?
    var receivedNew: Transaction?
    store.onMutate = { old, new in
      receivedOld = old
      receivedNew = new
    }

    await store.load(filter: TransactionFilter(accountId: accountId))

    // Remove the earmarkId
    var updated = tx
    updated.legs = [
      TransactionLeg(
        accountId: accountId,
        instrument: Instrument.defaultTestInstrument,
        quantity: Decimal(-5000) / 100,
        type: .expense
      )
    ]
    await store.update(updated)

    #expect(receivedOld?.earmarkId == earmarkId)
    #expect(receivedNew?.earmarkId == nil)
  }

  // MARK: - Balance Updates with Type Changes

  @Test func testOnMutateChangingTypeExpenseToIncome() async throws {
    let tx = Transaction(
      date: makeDate("2024-01-15"),
      payee: "Test",
      legs: [
        TransactionLeg(
          accountId: accountId,
          instrument: Instrument.defaultTestInstrument,
          quantity: Decimal(-5000) / 100,
          type: .expense
        )
      ]
    )
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(transactions: [tx], in: container)
    let store = TransactionStore(
      repository: backend.transactions,
      conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument
    )

    var receivedOld: Transaction?
    var receivedNew: Transaction?
    store.onMutate = { old, new in
      receivedOld = old
      receivedNew = new
    }

    await store.load(filter: TransactionFilter(accountId: accountId))

    // Change type to income (amount sign should flip)
    var updated = tx
    updated.legs = [
      TransactionLeg(
        accountId: accountId,
        instrument: Instrument.defaultTestInstrument,
        quantity: Decimal(5000) / 100,
        type: .income
      )
    ]
    await store.update(updated)

    #expect(receivedOld?.legs.first?.type ?? .expense == .expense)
    #expect(receivedOld?.legs.first?.quantity == Decimal(-5000) / 100)
    #expect(receivedNew?.legs.first?.type ?? .expense == .income)
    #expect(receivedNew?.legs.first?.quantity == Decimal(5000) / 100)
  }

  @Test func testOnMutateChangingTypeExpenseToTransfer() async throws {
    let savingsId = UUID()
    let tx = Transaction(
      date: makeDate("2024-01-15"),
      payee: "Test",
      legs: [
        TransactionLeg(
          accountId: accountId,
          instrument: Instrument.defaultTestInstrument,
          quantity: Decimal(-5000) / 100,
          type: .expense
        )
      ]
    )
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(transactions: [tx], in: container)
    let store = TransactionStore(
      repository: backend.transactions,
      conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument
    )

    var receivedOld: Transaction?
    var receivedNew: Transaction?
    store.onMutate = { old, new in
      receivedOld = old
      receivedNew = new
    }

    await store.load(filter: TransactionFilter(accountId: accountId))

    // Change type to transfer
    var updated = tx
    updated.legs = [
      TransactionLeg(
        accountId: accountId,
        instrument: Instrument.defaultTestInstrument,
        quantity: Decimal(-5000) / 100,
        type: .transfer
      ),
      TransactionLeg(
        accountId: savingsId,
        instrument: Instrument.defaultTestInstrument,
        quantity: Decimal(5000) / 100,
        type: .transfer
      ),
    ]
    await store.update(updated)

    #expect(receivedOld?.legs.first?.type ?? .expense == .expense)
    #expect(
      receivedOld?.legs.first(where: { $0.accountId != accountId })?.accountId
        == nil)
    #expect(receivedNew?.legs.first?.type ?? .expense == .transfer)
    #expect(
      receivedNew?.legs.first(where: { $0.accountId != accountId })?.accountId
        == savingsId)
  }

  @Test func testOnMutateChangingTypeTransferToExpense() async throws {
    let savingsId = UUID()
    let tx = Transaction(
      date: makeDate("2024-01-15"),
      payee: "",
      legs: [
        TransactionLeg(
          accountId: accountId,
          instrument: Instrument.defaultTestInstrument,
          quantity: Decimal(-5000) / 100,
          type: .transfer
        ),
        TransactionLeg(
          accountId: savingsId,
          instrument: Instrument.defaultTestInstrument,
          quantity: Decimal(5000) / 100,
          type: .transfer
        ),
      ]
    )
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(transactions: [tx], in: container)
    let store = TransactionStore(
      repository: backend.transactions,
      conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument
    )

    var receivedOld: Transaction?
    var receivedNew: Transaction?
    store.onMutate = { old, new in
      receivedOld = old
      receivedNew = new
    }

    await store.load(filter: TransactionFilter(accountId: accountId))

    // Change type to expense (toAccountId should be nil)
    var updated = tx
    updated.legs = [
      TransactionLeg(
        accountId: accountId,
        instrument: Instrument.defaultTestInstrument,
        quantity: Decimal(-5000) / 100,
        type: .expense
      )
    ]
    updated.payee = "Test"
    await store.update(updated)

    #expect(receivedOld?.legs.first?.type ?? .expense == .transfer)
    #expect(
      receivedOld?.legs.first(where: { $0.accountId != accountId })?.accountId
        == savingsId)
    #expect(receivedNew?.legs.first?.type ?? .expense == .expense)
    #expect(
      receivedNew?.legs.first(where: { $0.accountId != accountId })?.accountId
        == nil)
  }

  // MARK: - Balance Updates with Amount Changes

  @Test func testOnMutateChangingAmount() async throws {
    let tx = Transaction(
      date: makeDate("2024-01-15"),
      payee: "Test",
      legs: [
        TransactionLeg(
          accountId: accountId,
          instrument: Instrument.defaultTestInstrument,
          quantity: Decimal(-5000) / 100,
          type: .expense
        )
      ]
    )
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(transactions: [tx], in: container)
    let store = TransactionStore(
      repository: backend.transactions,
      conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument
    )

    var receivedOld: Transaction?
    var receivedNew: Transaction?
    store.onMutate = { old, new in
      receivedOld = old
      receivedNew = new
    }

    await store.load(filter: TransactionFilter(accountId: accountId))

    // Change the amount
    var updated = tx
    updated.legs = [
      TransactionLeg(
        accountId: accountId,
        instrument: Instrument.defaultTestInstrument,
        quantity: Decimal(-7500) / 100,
        type: .expense
      )
    ]
    await store.update(updated)

    #expect(receivedOld?.legs.first?.quantity == Decimal(-5000) / 100)
    #expect(receivedNew?.legs.first?.quantity == Decimal(-7500) / 100)
  }

  @Test func testRunningBalancesUpdateAfterAmountChange() async throws {
    let tx1 = Transaction(
      date: makeDate("2024-01-01"),
      payee: "Salary",
      legs: [
        TransactionLeg(
          accountId: accountId,
          instrument: Instrument.defaultTestInstrument,
          quantity: Decimal(100000) / 100,
          type: .income
        )
      ]
    )
    let tx2 = Transaction(
      date: makeDate("2024-01-15"),
      payee: "Coffee",
      legs: [
        TransactionLeg(
          accountId: accountId,
          instrument: Instrument.defaultTestInstrument,
          quantity: Decimal(-3000) / 100,
          type: .expense
        )
      ]
    )
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(transactions: [tx1, tx2], in: container)
    let store = TransactionStore(
      repository: backend.transactions,
      conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument
    )

    await store.load(filter: TransactionFilter(accountId: accountId))
    #expect(store.transactions.count == 2)
    #expect(store.transactions[0].balance.quantity == Decimal(97000) / 100)  // After Coffee
    #expect(store.transactions[1].balance.quantity == Decimal(100000) / 100)  // After Salary

    // Update Coffee amount to -5000
    var updated = tx2
    updated.legs = [
      TransactionLeg(
        accountId: accountId,
        instrument: Instrument.defaultTestInstrument,
        quantity: Decimal(-5000) / 100,
        type: .expense
      )
    ]
    await store.update(updated)

    #expect(store.transactions.count == 2)
    #expect(store.transactions[0].balance.quantity == Decimal(95000) / 100)  // After updated Coffee
    #expect(store.transactions[1].balance.quantity == Decimal(100000) / 100)  // After Salary (unchanged)
  }

  // MARK: - Pay Scheduled Transaction

  @Test func testPayRecurringTransactionAdvancesDate() async throws {
    let originalDate = makeDate("2024-01-15")
    let scheduled = Transaction(
      date: originalDate,
      payee: "Rent",
      recurPeriod: .month,
      recurEvery: 1,
      legs: [
        TransactionLeg(
          accountId: accountId,
          instrument: Instrument.defaultTestInstrument,
          quantity: Decimal(-200000) / 100,
          type: .expense
        )
      ]
    )
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(transactions: [scheduled], in: container)
    let store = TransactionStore(
      repository: backend.transactions,
      conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument
    )

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
    #expect(paidTx?.legs.first?.quantity == Decimal(-200000) / 100)

    // Backend should still have the scheduled transaction with advanced date
    let scheduledPage = try await backend.transactions.fetch(
      filter: TransactionFilter(scheduled: true), page: 0, pageSize: 50)
    #expect(scheduledPage.transactions.count == 1)
    #expect(scheduledPage.transactions[0].id == scheduled.id)
  }

  @Test func testPayRecurringWeeklyTransactionAdvancesByWeek() async throws {
    let scheduled = Transaction(
      date: makeDate("2024-01-15"),
      payee: "Groceries",
      recurPeriod: .week,
      recurEvery: 2,
      legs: [
        TransactionLeg(
          accountId: accountId,
          instrument: Instrument.defaultTestInstrument,
          quantity: Decimal(-5000) / 100,
          type: .expense
        )
      ]
    )
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(transactions: [scheduled], in: container)
    let store = TransactionStore(
      repository: backend.transactions,
      conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument
    )

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
      date: makeDate("2024-01-15"),
      payee: "Annual Fee",
      recurPeriod: .once,
      recurEvery: 1,
      legs: [
        TransactionLeg(
          accountId: accountId,
          instrument: Instrument.defaultTestInstrument,
          quantity: Decimal(-50000) / 100,
          type: .expense
        )
      ]
    )
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(transactions: [scheduled], in: container)
    let store = TransactionStore(
      repository: backend.transactions,
      conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument
    )

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
      date: makeDate("2024-01-15"),
      payee: "Savings Transfer",
      notes: "Monthly savings",
      recurPeriod: .month,
      recurEvery: 1,
      legs: [
        TransactionLeg(
          accountId: accountId,
          instrument: Instrument.defaultTestInstrument,
          quantity: Decimal(-100000) / 100,
          type: .transfer,
          categoryId: categoryId,
          earmarkId: earmarkId
        ),
        TransactionLeg(
          accountId: toAccountId,
          instrument: Instrument.defaultTestInstrument,
          quantity: Decimal(100000) / 100,
          type: .transfer
        ),
      ]
    )
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(transactions: [scheduled], in: container)
    let store = TransactionStore(
      repository: backend.transactions,
      conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument
    )

    await store.load(filter: TransactionFilter(scheduled: true))
    _ = await store.payScheduledTransaction(scheduled)

    // Find the paid (non-scheduled) transaction in the backend
    let allPage = try await backend.transactions.fetch(
      filter: TransactionFilter(), page: 0, pageSize: 50)
    let paidTx = allPage.transactions.first { $0.id != scheduled.id }
    #expect(paidTx != nil)
    #expect(paidTx?.legs.first?.type ?? .expense == .transfer)
    #expect(paidTx?.accountIds.contains(accountId) == true)
    #expect(
      paidTx?.legs.first(where: { $0.accountId != accountId })?.accountId
        == toAccountId)
    #expect(paidTx?.legs.first?.quantity == Decimal(-100000) / 100)
    #expect(paidTx?.payee == "Savings Transfer")
    #expect(paidTx?.notes == "Monthly savings")
    #expect(paidTx?.legs.contains(where: { $0.categoryId == categoryId }) == true)
    #expect(paidTx?.earmarkId == earmarkId)
    #expect(paidTx?.recurPeriod == nil)
    #expect(paidTx?.recurEvery == nil)
  }

  @Test func testPayFiresOnMutateForCreateAndUpdate() async throws {
    let scheduled = Transaction(
      date: makeDate("2024-01-15"),
      payee: "Rent",
      recurPeriod: .month,
      recurEvery: 1,
      legs: [
        TransactionLeg(
          accountId: accountId,
          instrument: Instrument.defaultTestInstrument,
          quantity: Decimal(-200000) / 100,
          type: .expense
        )
      ]
    )
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(transactions: [scheduled], in: container)
    let store = TransactionStore(
      repository: backend.transactions,
      conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument
    )

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
      date: makeDate("2024-01-15"),
      payee: "Annual Fee",
      recurPeriod: .once,
      recurEvery: 1,
      legs: [
        TransactionLeg(
          accountId: accountId,
          instrument: Instrument.defaultTestInstrument,
          quantity: Decimal(-50000) / 100,
          type: .expense
        )
      ]
    )
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(transactions: [scheduled], in: container)
    let store = TransactionStore(
      repository: backend.transactions,
      conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument
    )

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
        date: makeDate("2024-01-01"),
        payee: "Woolworths",
        legs: [
          TransactionLeg(
            accountId: accountId,
            instrument: Instrument.defaultTestInstrument,
            quantity: Decimal(-5000) / 100,
            type: .expense
          )
        ]
      ),
      Transaction(
        date: makeDate("2024-01-02"),
        payee: "Woollies Market",
        legs: [
          TransactionLeg(
            accountId: accountId,
            instrument: Instrument.defaultTestInstrument,
            quantity: Decimal(-3000) / 100,
            type: .expense
          )
        ]
      ),
      Transaction(
        date: makeDate("2024-01-03"),
        payee: "Coles",
        legs: [
          TransactionLeg(
            accountId: accountId,
            instrument: Instrument.defaultTestInstrument,
            quantity: Decimal(-2000) / 100,
            type: .expense
          )
        ]
      ),
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
        date: makeDate("2024-01-01"),
        payee: "Woolworths",
        legs: [
          TransactionLeg(
            accountId: accountId,
            instrument: Instrument.defaultTestInstrument,
            quantity: Decimal(-5000) / 100,
            type: .expense
          )
        ]
      ),
      Transaction(
        date: makeDate("2024-01-02"),
        payee: "Woollies Market",
        legs: [
          TransactionLeg(
            accountId: accountId,
            instrument: Instrument.defaultTestInstrument,
            quantity: Decimal(-3000) / 100,
            type: .expense
          )
        ]
      ),
      Transaction(
        date: makeDate("2024-01-03"),
        payee: "Woolworths",
        legs: [
          TransactionLeg(
            accountId: accountId,
            instrument: Instrument.defaultTestInstrument,
            quantity: Decimal(-4000) / 100,
            type: .expense
          )
        ]
      ),
      Transaction(
        date: makeDate("2024-01-04"),
        payee: "Woolworths",
        legs: [
          TransactionLeg(
            accountId: accountId,
            instrument: Instrument.defaultTestInstrument,
            quantity: Decimal(-6000) / 100,
            type: .expense
          )
        ]
      ),
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
        date: makeDate("2024-01-01"),
        payee: "Woolworths",
        legs: [
          TransactionLeg(
            accountId: accountId,
            instrument: Instrument.defaultTestInstrument,
            quantity: Decimal(-3000) / 100,
            type: .expense
          )
        ]
      ),
      Transaction(
        date: makeDate("2024-03-01"),
        payee: "Woolworths",
        legs: [
          TransactionLeg(
            accountId: accountId,
            instrument: Instrument.defaultTestInstrument,
            quantity: Decimal(-7500) / 100,
            type: .expense,
            categoryId: categoryId
          )
        ]
      ),
    ]
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(transactions: transactions, in: container)
    let store = TransactionStore(
      repository: backend.transactions,
      conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument
    )

    let match = await store.fetchTransactionForAutofill(payee: "Woolworths")
    #expect(match != nil)
    // Most recent (newest first from server) should have the category
    #expect(match?.legs.contains(where: { $0.categoryId == categoryId }) == true)
    #expect(match?.legs.first?.quantity == Decimal(-7500) / 100)
  }

  @Test func testDebouncedSaveOnlyCallsLastAction() async throws {
    let (backend, _) = try TestBackend.create()
    let store = TransactionStore(
      repository: backend.transactions,
      conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument
    )

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
    let store = TransactionStore(
      repository: backend.transactions,
      conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument
    )

    await store.load(filter: TransactionFilter(accountId: filterAccountId))

    let created = await store.createDefault(
      accountId: filterAccountId,
      fallbackAccountId: fallbackAccountId,
      instrument: Instrument.defaultTestInstrument
    )

    #expect(created != nil)
    #expect(created?.accountIds.contains(filterAccountId) == true)
  }

  @Test func testCreateDefaultFallsBackToFirstAccount() async throws {
    let fallbackAccountId = UUID()
    let (backend, _) = try TestBackend.create()
    let store = TransactionStore(
      repository: backend.transactions,
      conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument
    )

    await store.load(filter: TransactionFilter())

    let created = await store.createDefault(
      accountId: nil,
      fallbackAccountId: fallbackAccountId,
      instrument: Instrument.defaultTestInstrument
    )

    #expect(created != nil)
    #expect(created?.accountIds.contains(fallbackAccountId) == true)
  }

  @Test func testCreateDefaultSetsExpenseTypeAndZeroAmount() async throws {
    let (backend, _) = try TestBackend.create()
    let store = TransactionStore(
      repository: backend.transactions,
      conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument
    )

    await store.load(filter: TransactionFilter())

    let created = await store.createDefault(
      accountId: accountId,
      fallbackAccountId: nil,
      instrument: Instrument.defaultTestInstrument
    )

    #expect(created != nil)
    #expect(created?.legs.first?.type ?? .expense == .expense)
    #expect(created?.legs.first?.quantity == 0)
    #expect(created?.legs.first?.instrument == Instrument.defaultTestInstrument)
    #expect(created?.payee == "")
  }

  @Test func testCreateDefaultReturnsNilOnFailure() async throws {
    // Use an error-injecting repository to force a failure
    let failingStore = TransactionStore(
      repository: FailingTransactionRepository(),
      conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument
    )

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
        date: makeDate("2024-01-01"),
        payee: "Woolworths",
        legs: [
          TransactionLeg(
            accountId: accountId,
            instrument: Instrument.defaultTestInstrument,
            quantity: Decimal(-5000) / 100,
            type: .expense
          )
        ]
      )
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
