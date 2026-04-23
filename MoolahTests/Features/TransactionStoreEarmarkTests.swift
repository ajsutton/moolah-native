import Foundation
import SwiftData
import Testing

@testable import Moolah

@Suite("TransactionStore/Earmarks")
@MainActor
struct TransactionStoreEarmarkTests {
  private let accountId = UUID()

  // MARK: - Cross-Store Balance Updates with Earmarks

  @Test
  func testCreateWithEarmarkUpdatesEarmarkBalance() async throws {
    let earmarkId = UUID()
    let account = TransactionStoreTestSupport.acct(id: accountId, name: "Bank", balance: 1000)
    let earmark = Earmark(
      id: earmarkId, name: "Holiday",
      instrument: .defaultTestInstrument)
    let (backend, container) = try TestBackend.create()
    let stores = await TransactionStoreTestSupport.makeStores(
      backend: backend, container: container, accounts: [account], earmarks: [earmark])
    let store = stores.transactions
    let earmarkStore = stores.earmarks

    await store.load(filter: TransactionFilter(accountId: accountId))

    let transaction = Transaction(
      date: try TransactionStoreTestSupport.makeDate("2024-01-15"),
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
    _ = await store.create(transaction)

    // Earmark spent should increase (balance decreases for expense)
    let updatedEarmark = earmarkStore.earmarks.by(id: earmarkId)
    #expect(updatedEarmark != nil)
    // Expense of -50 against earmark: spent increases by 50
    #expect(updatedEarmark?.spentPositions.first?.quantity == Decimal(50))
  }

  @Test
  func testUpdateChangingEarmarkId() async throws {
    let earmarkId1 = UUID()
    let earmarkId2 = UUID()
    let account = TransactionStoreTestSupport.acct(id: accountId, name: "Bank", balance: 950)
    let earmark1 = Earmark(
      id: earmarkId1, name: "Holiday",
      instrument: .defaultTestInstrument)
    let earmark2 = Earmark(
      id: earmarkId2, name: "Emergency",
      instrument: .defaultTestInstrument)
    let transaction = Transaction(
      date: try TransactionStoreTestSupport.makeDate("2024-01-15"),
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
    TestBackend.seed(transactions: [transaction], in: container)
    let stores = await TransactionStoreTestSupport.makeStores(
      backend: backend, container: container, accounts: [account],
      earmarks: [earmark1, earmark2])
    let store = stores.transactions
    let earmarkStore = stores.earmarks

    await store.load(filter: TransactionFilter(accountId: accountId))

    // Change earmark from 1 to 2
    var updated = transaction
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

    // Earmark 1 should have spent reversed (50 - 50 = 0)
    let updatedEarmark1 = earmarkStore.earmarks.by(id: earmarkId1)
    #expect(updatedEarmark1?.spentPositions.first?.quantity ?? 0 == Decimal(0))
    // Earmark 2 should have spent increased (0 + 50 = 50)
    let updatedEarmark2 = earmarkStore.earmarks.by(id: earmarkId2)
    #expect(updatedEarmark2?.spentPositions.first?.quantity == Decimal(50))
  }

  @Test
  func testTypeChangeExpenseToIncomeUpdatesAccountBalance() async throws {
    let account = TransactionStoreTestSupport.acct(id: accountId, name: "Bank", balance: 950)
    let transaction = Transaction(
      date: try TransactionStoreTestSupport.makeDate("2024-01-15"),
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
    TestBackend.seed(transactions: [transaction], in: container)
    let stores = await TransactionStoreTestSupport.makeStores(
      backend: backend, container: container, accounts: [account])
    let store = stores.transactions
    let accountStore = stores.accounts

    await store.load(filter: TransactionFilter(accountId: accountId))

    // Change from expense (-50) to income (+50)
    var updated = transaction
    updated.legs = [
      TransactionLeg(
        accountId: accountId,
        instrument: Instrument.defaultTestInstrument,
        quantity: Decimal(5000) / 100,
        type: .income
      )
    ]
    await store.update(updated)

    // Loaded: 950+(-50)=900. Update delta: +50-(-50)=+100. Final: 900+100=1000
    let balance = try await accountStore.displayBalance(for: accountId)
    #expect(balance.quantity == Decimal(1000))
  }

  @Test
  func testPayScheduledTransactionUpdatesAccountBalance() async throws {
    let account = TransactionStoreTestSupport.acct(id: accountId, name: "Bank", balance: 1000)
    let scheduled = Transaction(
      date: try TransactionStoreTestSupport.makeDate("2024-01-15"),
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
    let stores = await TransactionStoreTestSupport.makeStores(
      backend: backend, container: container, accounts: [account])
    let store = stores.transactions
    let accountStore = stores.accounts

    await store.load(filter: TransactionFilter(scheduled: true))
    _ = await store.payScheduledTransaction(scheduled)

    // Paying a -2000 expense should decrease balance by 2000
    let balance = try await accountStore.displayBalance(for: accountId)
    #expect(balance.quantity == Decimal(-1000))
  }

  @Test
  func testPayOneTimeScheduledTransactionUpdatesAccountBalance() async throws {
    let account = TransactionStoreTestSupport.acct(id: accountId, name: "Bank", balance: 1000)
    let scheduled = Transaction(
      date: try TransactionStoreTestSupport.makeDate("2024-01-15"),
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
    let stores = await TransactionStoreTestSupport.makeStores(
      backend: backend, container: container, accounts: [account])
    let store = stores.transactions
    let accountStore = stores.accounts

    await store.load(filter: TransactionFilter(scheduled: true))
    _ = await store.payScheduledTransaction(scheduled)

    // Paying a -500 expense should decrease balance by 500
    let balance = try await accountStore.displayBalance(for: accountId)
    #expect(balance.quantity == Decimal(500))
  }

  @Test
  func testRunningBalancesUpdateAfterAmountChange() async throws {
    let salary = Transaction(
      date: try TransactionStoreTestSupport.makeDate("2024-01-01"),
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
    let coffee = Transaction(
      date: try TransactionStoreTestSupport.makeDate("2024-01-15"),
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
    TestBackend.seed(transactions: [salary, coffee], in: container)
    let store = TransactionStore(
      repository: backend.transactions,
      conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument
    )

    await store.load(filter: TransactionFilter(accountId: accountId))
    #expect(store.transactions.count == 2)
    #expect(store.transactions[0].balance?.quantity == Decimal(97000) / 100)  // After Coffee
    #expect(store.transactions[1].balance?.quantity == Decimal(100000) / 100)  // After Salary

    // Update Coffee amount to -5000
    var updated = coffee
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
    #expect(store.transactions[0].balance?.quantity == Decimal(95000) / 100)  // After updated Coffee
    #expect(store.transactions[1].balance?.quantity == Decimal(100000) / 100)  // After Salary (unchanged)
  }
}
