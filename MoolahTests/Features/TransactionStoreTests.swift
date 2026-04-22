import Foundation
import SwiftData
import Testing

@testable import Moolah

@Suite("TransactionStore")
@MainActor
struct TransactionStoreTests {
  private let accountId = UUID()

  /// Helper to create an Account + opening balance tuple for seeding.
  private func acct(
    id: UUID, name: String, type: AccountType = .bank,
    balance: Decimal
  ) -> (account: Account, openingBalance: InstrumentAmount) {
    (
      account: Account(id: id, name: name, type: type, instrument: .defaultTestInstrument),
      openingBalance: InstrumentAmount(quantity: balance, instrument: .defaultTestInstrument)
    )
  }

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

  /// The placeholder-pass-through pattern in `TransactionListView.createNewTransaction`
  /// (and the upcoming-view equivalent) relies on `store.create(placeholder)`
  /// returning a transaction with the same UUID the caller passed in. The
  /// inspector's `.id(selected.id)` otherwise forces a view recreation on
  /// every create, which would drop focus state. See
  /// `plans/2026-04-21-transaction-detail-focus-design.md`.
  @Test func testCreatePreservesInputUUID() async throws {
    let (backend, _) = try TestBackend.create()
    let store = TransactionStore(
      repository: backend.transactions,
      conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument
    )
    await store.load(filter: TransactionFilter(accountId: accountId))

    let placeholderId = UUID()
    let placeholder = Transaction(
      id: placeholderId,
      date: makeDate("2024-02-01"),
      payee: "",
      legs: [
        TransactionLeg(
          accountId: accountId,
          instrument: Instrument.defaultTestInstrument,
          quantity: 0,
          type: .expense
        )
      ]
    )

    let created = await store.create(placeholder)

    #expect(created?.id == placeholderId)
    #expect(store.transactions.count == 1)
    #expect(store.transactions[0].transaction.id == placeholderId)
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
    #expect(store.transactions[0].displayAmount?.quantity == Decimal(-7500) / 100)
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
    #expect(store.transactions[0].displayAmount?.quantity == Decimal(110000) / 100)

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
    #expect(store.transactions[0].balance?.quantity == Decimal(100000) / 100)

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
    #expect(store.transactions[0].balance?.quantity == Decimal(97000) / 100)
    #expect(store.transactions[1].transaction.payee == "Initial")
    #expect(store.transactions[1].balance?.quantity == Decimal(100000) / 100)
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
    #expect(store.transactions[0].balance?.quantity == Decimal(97000) / 100)  // After Coffee

    // Delete the expense — balance should revert
    await store.delete(id: tx2.id)
    #expect(store.transactions.count == 1)
    #expect(store.transactions[0].balance?.quantity == Decimal(100000) / 100)  // Only Salary remains
  }

  // MARK: - Cross-Store Balance Updates

  private func makeStores(
    backend: CloudKitBackend,
    container: ModelContainer,
    accounts: [(account: Account, openingBalance: InstrumentAmount)] = [],
    earmarks: [Earmark] = []
  ) async -> (TransactionStore, AccountStore, EarmarkStore) {
    if !accounts.isEmpty {
      TestBackend.seed(accounts: accounts, in: container)
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
    return (store, accountStore, earmarkStore)
  }

  @Test func testCreateUpdatesAccountBalance() async throws {
    let account = acct(id: accountId, name: "Bank", balance: 1000)
    let (backend, container) = try TestBackend.create()
    let (store, accountStore, _) = await makeStores(
      backend: backend, container: container, accounts: [account])

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

    // Seeded balance is 1000 (from OB tx), create adds -50 expense -> 950
    let balance = try await accountStore.displayBalance(for: accountId)
    #expect(balance.quantity == Decimal(950))
  }

  @Test func testUpdateUpdatesAccountBalance() async throws {
    let account = acct(id: accountId, name: "Bank", balance: 950)
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
    let (store, accountStore, _) = await makeStores(
      backend: backend, container: container, accounts: [account])

    await store.load(filter: TransactionFilter(accountId: accountId))

    // Change amount from -50 to -75
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

    // Seeded account OB=950 + seeded tx=-50 gives loaded balance=900
    // Update delta: (-75)-(-50)=-25, so 900-25=875
    let balance = try await accountStore.displayBalance(for: accountId)
    #expect(balance.quantity == Decimal(875))
  }

  @Test func testDeleteUpdatesAccountBalance() async throws {
    let account = acct(id: accountId, name: "Bank", balance: 950)
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
    let (store, accountStore, _) = await makeStores(
      backend: backend, container: container, accounts: [account])

    await store.load(filter: TransactionFilter(accountId: accountId))

    await store.delete(id: tx.id)

    // Seeded account OB=950 + seeded tx=-50 gives loaded balance=900
    // Deleting the -50 expense adds 50 back: 900+50=950
    let balance = try await accountStore.displayBalance(for: accountId)
    #expect(balance.quantity == Decimal(950))
  }

  // MARK: - Cross-Store Balance Updates with Transfers

  @Test func testTransferUpdateAffectsBothAccounts() async throws {
    let savingsId = UUID()
    let checking = acct(id: accountId, name: "Checking", balance: 900)
    let savings = acct(id: savingsId, name: "Savings", balance: 1100)
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
    let (store, accountStore, _) = await makeStores(
      backend: backend, container: container, accounts: [checking, savings])

    await store.load(filter: TransactionFilter(accountId: accountId))

    // Update transfer amount from 100 to 150
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

    // Loaded: checking=900+(-100)=800, savings=1100+100=1200
    // Update delta: checking: -150-(-100)=-50, savings: +150-100=+50
    // Final: checking=800-50=750, savings=1200+50=1250
    let checkingBalance = try await accountStore.displayBalance(for: accountId)
    let savingsBalance = try await accountStore.displayBalance(for: savingsId)
    #expect(checkingBalance.quantity == Decimal(750))
    #expect(savingsBalance.quantity == Decimal(1250))
  }

  @Test func testChangingTransferToAccount() async throws {
    let savingsId = UUID()
    let investmentId = UUID()
    let checking = acct(id: accountId, name: "Checking", balance: 900)
    let savings = acct(id: savingsId, name: "Savings", balance: 1100)
    let investment = acct(id: investmentId, name: "Investment", type: .investment, balance: 500)
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
    let (store, accountStore, _) = await makeStores(
      backend: backend, container: container, accounts: [checking, savings, investment])

    await store.load(filter: TransactionFilter(accountId: accountId))

    // Change destination from savings to investment
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

    // Loaded: checking=900+(-100)=800, savings=1100+100=1200, investment=500
    // Change dest from savings to investment:
    // checking delta: -100-(-100)=0, savings delta: 0-100=-100, investment delta: +100-0=+100
    // Final: checking=800, savings=1200-100=1100, investment=500+100=600
    let checkingBalance = try await accountStore.displayBalance(for: accountId)
    let savingsBalance = try await accountStore.displayBalance(for: savingsId)
    let investmentBalance = try await accountStore.displayBalance(for: investmentId)
    #expect(checkingBalance.quantity == Decimal(800))
    #expect(savingsBalance.quantity == Decimal(1100))
    #expect(investmentBalance.quantity == Decimal(600))
  }

  // MARK: - Cross-Store Balance Updates with Earmarks

  @Test func testCreateWithEarmarkUpdatesEarmarkBalance() async throws {
    let earmarkId = UUID()
    let account = acct(id: accountId, name: "Bank", balance: 1000)
    let earmark = Earmark(
      id: earmarkId, name: "Holiday",
      instrument: .defaultTestInstrument)
    let (backend, container) = try TestBackend.create()
    let (store, _, earmarkStore) = await makeStores(
      backend: backend, container: container, accounts: [account], earmarks: [earmark])

    await store.load(filter: TransactionFilter(accountId: accountId))

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
    _ = await store.create(tx)

    // Earmark spent should increase (balance decreases for expense)
    let updatedEarmark = earmarkStore.earmarks.by(id: earmarkId)
    #expect(updatedEarmark != nil)
    // Expense of -50 against earmark: spent increases by 50
    #expect(updatedEarmark?.spentPositions.first?.quantity == Decimal(50))
  }

  @Test func testUpdateChangingEarmarkId() async throws {
    let earmarkId1 = UUID()
    let earmarkId2 = UUID()
    let account = acct(id: accountId, name: "Bank", balance: 950)
    let earmark1 = Earmark(
      id: earmarkId1, name: "Holiday",
      instrument: .defaultTestInstrument)
    let earmark2 = Earmark(
      id: earmarkId2, name: "Emergency",
      instrument: .defaultTestInstrument)
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
    let (store, _, earmarkStore) = await makeStores(
      backend: backend, container: container, accounts: [account],
      earmarks: [earmark1, earmark2])

    await store.load(filter: TransactionFilter(accountId: accountId))

    // Change earmark from 1 to 2
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

    // Earmark 1 should have spent reversed (50 - 50 = 0)
    let updatedEarmark1 = earmarkStore.earmarks.by(id: earmarkId1)
    #expect(updatedEarmark1?.spentPositions.first?.quantity ?? 0 == Decimal(0))
    // Earmark 2 should have spent increased (0 + 50 = 50)
    let updatedEarmark2 = earmarkStore.earmarks.by(id: earmarkId2)
    #expect(updatedEarmark2?.spentPositions.first?.quantity == Decimal(50))
  }

  @Test func testTypeChangeExpenseToIncomeUpdatesAccountBalance() async throws {
    let account = acct(id: accountId, name: "Bank", balance: 950)
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
    let (store, accountStore, _) = await makeStores(
      backend: backend, container: container, accounts: [account])

    await store.load(filter: TransactionFilter(accountId: accountId))

    // Change from expense (-50) to income (+50)
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

    // Loaded: 950+(-50)=900. Update delta: +50-(-50)=+100. Final: 900+100=1000
    let balance = try await accountStore.displayBalance(for: accountId)
    #expect(balance.quantity == Decimal(1000))
  }

  @Test func testPayScheduledTransactionUpdatesAccountBalance() async throws {
    let account = acct(id: accountId, name: "Bank", balance: 1000)
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
    let (store, accountStore, _) = await makeStores(
      backend: backend, container: container, accounts: [account])

    await store.load(filter: TransactionFilter(scheduled: true))
    _ = await store.payScheduledTransaction(scheduled)

    // Paying a -2000 expense should decrease balance by 2000
    let balance = try await accountStore.displayBalance(for: accountId)
    #expect(balance.quantity == Decimal(-1000))
  }

  @Test func testPayOneTimeScheduledTransactionUpdatesAccountBalance() async throws {
    let account = acct(id: accountId, name: "Bank", balance: 1000)
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
    let (store, accountStore, _) = await makeStores(
      backend: backend, container: container, accounts: [account])

    await store.load(filter: TransactionFilter(scheduled: true))
    _ = await store.payScheduledTransaction(scheduled)

    // Paying a -500 expense should decrease balance by 500
    let balance = try await accountStore.displayBalance(for: accountId)
    #expect(balance.quantity == Decimal(500))
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
    #expect(store.transactions[0].balance?.quantity == Decimal(97000) / 100)  // After Coffee
    #expect(store.transactions[1].balance?.quantity == Decimal(100000) / 100)  // After Salary

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
    #expect(store.transactions[0].balance?.quantity == Decimal(95000) / 100)  // After updated Coffee
    #expect(store.transactions[1].balance?.quantity == Decimal(100000) / 100)  // After Salary (unchanged)
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
    #expect(paidTx?.legs.contains(where: { $0.earmarkId == earmarkId }) == true)
    #expect(paidTx?.recurPeriod == nil)
    #expect(paidTx?.recurEvery == nil)
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

  // MARK: - createDefaultScheduled

  @Test func testCreateDefaultScheduledSetsMonthlyRecurrence() async throws {
    let (backend, _) = try TestBackend.create()
    let store = TransactionStore(
      repository: backend.transactions,
      conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument
    )

    await store.load(filter: TransactionFilter(scheduled: true))

    let created = await store.createDefaultScheduled(
      accountId: accountId,
      fallbackAccountId: nil,
      instrument: Instrument.defaultTestInstrument
    )

    #expect(created != nil)
    #expect(created?.isScheduled == true)
    #expect(created?.recurPeriod == .month)
    #expect(created?.recurEvery == 1)
    #expect(created?.legs.first?.type == .expense)
    #expect(created?.legs.first?.quantity == 0)
    #expect(created?.accountIds.contains(accountId) == true)
    #expect(created?.payee == "")
  }

  @Test func testCreateDefaultScheduledFallsBackToFirstAccount() async throws {
    let fallbackAccountId = UUID()
    let (backend, _) = try TestBackend.create()
    let store = TransactionStore(
      repository: backend.transactions,
      conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument
    )

    await store.load(filter: TransactionFilter(scheduled: true))

    let created = await store.createDefaultScheduled(
      accountId: nil,
      fallbackAccountId: fallbackAccountId,
      instrument: Instrument.defaultTestInstrument
    )

    #expect(created != nil)
    #expect(created?.isScheduled == true)
    #expect(created?.accountIds.contains(fallbackAccountId) == true)
  }

  @Test func testCreateDefaultScheduledReturnsNilWhenNoAccount() async throws {
    let (backend, _) = try TestBackend.create()
    let store = TransactionStore(
      repository: backend.transactions,
      conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument
    )

    let result = await store.createDefaultScheduled(
      accountId: nil,
      fallbackAccountId: nil,
      instrument: Instrument.defaultTestInstrument
    )

    #expect(result == nil)
  }

  @Test func testCreateDefaultScheduledReturnsNilOnFailure() async throws {
    let failingStore = TransactionStore(
      repository: FailingTransactionRepository(),
      conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument
    )

    let result = await failingStore.createDefaultScheduled(
      accountId: accountId,
      fallbackAccountId: nil,
      instrument: Instrument.defaultTestInstrument
    )

    #expect(result == nil)
    #expect(failingStore.error != nil)
  }

  /// Issue #48: a conversion failure while computing running balances must be
  /// surfaced on the store so the UI can render a retry path, not silently
  /// swallowed. Target is AUD; seeded transaction is in USD and the conversion
  /// service refuses the USD pair.
  @Test func testConversionFailureSurfacesErrorOnStore() async throws {
    let aud = Instrument.defaultTestInstrument
    let usd = Instrument.USD
    let (backend, container) = try TestBackend.create()

    let account = Account(id: accountId, name: "AUD", type: .bank, instrument: aud)
    TestBackend.seed(accounts: [account], in: container)

    let foreignTx = Transaction(
      date: makeDate("2024-01-05"),
      payee: "Overseas",
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: usd, quantity: Decimal(-50), type: .expense)
      ]
    )
    TestBackend.seed(transactions: [foreignTx], in: container)

    let store = TransactionStore(
      repository: backend.transactions,
      conversionService: FailingConversionService(failingInstrumentIds: [usd.id]),
      targetInstrument: aud
    )

    await store.load(filter: TransactionFilter(accountId: accountId))

    // The row still renders so the list isn't blanked...
    #expect(store.transactions.count == 1)
    // ...but its display/balance are unavailable and the error is surfaced.
    #expect(store.transactions.first?.displayAmount == nil)
    #expect(store.transactions.first?.balance == nil)
    #expect(store.error != nil)
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

  // MARK: - Multi-instrument loading

  @Test func testLoadsUSDAccountTransactionsInUSDInstrument() async throws {
    // A USD-denominated account should load expense/income legs with USD instrument intact.
    let usdAccountId = UUID()
    let transactions = [
      Transaction(
        date: makeDate("2024-06-15"),
        payee: "Starbucks",
        legs: [
          TransactionLeg(
            accountId: usdAccountId,
            instrument: .USD,
            quantity: Decimal(string: "-4.50")!,
            type: .expense)
        ]
      )
    ]
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(
      accounts: [
        Account(id: usdAccountId, name: "US Checking", type: .bank, instrument: .USD)
      ], in: container)
    TestBackend.seed(transactions: transactions, in: container)

    let store = TransactionStore(
      repository: backend.transactions,
      conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument
    )
    await store.load(filter: TransactionFilter(accountId: usdAccountId))

    #expect(store.transactions.count == 1)
    let tx = store.transactions[0].transaction
    #expect(tx.legs[0].instrument == .USD)
    #expect(tx.legs[0].quantity == Decimal(string: "-4.50")!)
  }

  @Test func testLoadsTransactionSpanningMultipleInstruments() async throws {
    // Currency conversion transaction on the same account — leg instruments must be preserved.
    let revolutId = UUID()
    let tx = Transaction(
      date: makeDate("2024-06-15"),
      payee: "FX",
      legs: [
        TransactionLeg(
          accountId: revolutId, instrument: .AUD,
          quantity: Decimal(string: "-1000.00")!, type: .transfer),
        TransactionLeg(
          accountId: revolutId, instrument: .USD,
          quantity: Decimal(string: "650.00")!, type: .transfer),
      ]
    )
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(
      accounts: [
        Account(id: revolutId, name: "Revolut", type: .bank, instrument: .AUD)
      ], in: container)
    TestBackend.seed(transactions: [tx], in: container)

    let store = TransactionStore(
      repository: backend.transactions,
      conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument
    )
    await store.load(filter: TransactionFilter(accountId: revolutId))

    #expect(store.transactions.count == 1)
    let fetched = store.transactions[0].transaction
    #expect(fetched.legs.count == 2)
    let audLeg = try #require(fetched.legs.first(where: { $0.instrument == .AUD }))
    let usdLeg = try #require(fetched.legs.first(where: { $0.instrument == .USD }))
    #expect(audLeg.quantity == Decimal(string: "-1000.00")!)
    #expect(usdLeg.quantity == Decimal(string: "650.00")!)
    #expect(fetched.isTransfer)
  }

  // MARK: - Scheduled view helpers

  /// Seeds one past-dated scheduled transaction and one future-dated scheduled
  /// transaction plus one past-dated non-scheduled (paid) transaction, then
  /// returns the prepared store. The non-scheduled transaction is what the
  /// pre-fix Analysis card was rendering as "overdue" when the shared
  /// transactionStore had been loaded with a non-scheduled filter first.
  private func makeScheduledTestStore() async throws -> (
    store: TransactionStore, backend: CloudKitBackend, container: ModelContainer
  ) {
    let (backend, container) = try TestBackend.create()
    let accountId = UUID()
    TestBackend.seed(
      accounts: [
        (
          account: Account(
            id: accountId, name: "Bank", type: .bank, instrument: .defaultTestInstrument),
          openingBalance: InstrumentAmount(quantity: 0, instrument: .defaultTestInstrument)
        )
      ],
      in: container)
    let calendar = Calendar.current
    let overdue = calendar.date(byAdding: .day, value: -5, to: Date())!
    let upcoming = calendar.date(byAdding: .day, value: 5, to: Date())!
    let farFuture = calendar.date(byAdding: .day, value: 60, to: Date())!
    let pastPaid = calendar.date(byAdding: .day, value: -10, to: Date())!
    TestBackend.seed(
      transactions: [
        Transaction(
          date: overdue, payee: "Overdue Rent",
          recurPeriod: .month, recurEvery: 1,
          legs: [
            TransactionLeg(
              accountId: accountId, instrument: .defaultTestInstrument,
              quantity: Decimal(-2000), type: .expense)
          ]),
        Transaction(
          date: upcoming, payee: "Upcoming Internet",
          recurPeriod: .month, recurEvery: 1,
          legs: [
            TransactionLeg(
              accountId: accountId, instrument: .defaultTestInstrument,
              quantity: Decimal(-150), type: .expense)
          ]),
        Transaction(
          date: farFuture, payee: "Future Insurance",
          recurPeriod: .month, recurEvery: 1,
          legs: [
            TransactionLeg(
              accountId: accountId, instrument: .defaultTestInstrument,
              quantity: Decimal(-300), type: .expense)
          ]),
        Transaction(
          date: pastPaid, payee: "Old Coffee",
          legs: [
            TransactionLeg(
              accountId: accountId, instrument: .defaultTestInstrument,
              quantity: Decimal(-10), type: .expense)
          ]),
      ],
      in: container)
    let store = TransactionStore(
      repository: backend.transactions,
      conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument)
    return (store, backend, container)
  }

  @Test("scheduledOverdueTransactions is empty when filter isn't scheduled-only")
  func overdueEmptyWhenFilterMismatched() async throws {
    let (store, _, _) = try await makeScheduledTestStore()

    await store.load(filter: TransactionFilter())

    #expect(!store.transactions.isEmpty)
    #expect(store.scheduledOverdueTransactions.isEmpty)
    #expect(store.scheduledUpcomingTransactions.isEmpty)
    #expect(store.scheduledShortTermTransactions().isEmpty)
  }

  @Test("scheduledOverdueTransactions returns past-dated scheduled transactions only")
  func overdueReturnsPastDatedScheduled() async throws {
    let (store, _, _) = try await makeScheduledTestStore()

    await store.load(filter: TransactionFilter(scheduled: true))

    #expect(store.scheduledOverdueTransactions.count == 1)
    #expect(store.scheduledOverdueTransactions.first?.transaction.payee == "Overdue Rent")
  }

  @Test("scheduledUpcomingTransactions returns today-or-later scheduled transactions")
  func upcomingReturnsTodayOrLaterScheduled() async throws {
    let (store, _, _) = try await makeScheduledTestStore()

    await store.load(filter: TransactionFilter(scheduled: true))

    let payees = store.scheduledUpcomingTransactions.map(\.transaction.payee)
    #expect(payees == ["Upcoming Internet", "Future Insurance"])
  }

  @Test("scheduledShortTermTransactions limits to within the daysAhead window")
  func shortTermWindowedByDaysAhead() async throws {
    let (store, _, _) = try await makeScheduledTestStore()

    await store.load(filter: TransactionFilter(scheduled: true))

    // Default 14-day window: includes overdue + near upcoming, excludes 60-day future.
    let payees = store.scheduledShortTermTransactions().map(\.transaction.payee)
    #expect(payees == ["Overdue Rent", "Upcoming Internet"])
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
