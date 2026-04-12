import Foundation
import SwiftData
import Testing

@testable import Moolah

@Suite("AccountStore")
@MainActor
struct AccountStoreTests {
  @Test func testPopulatesFromRepository() async throws {
    let account = Account(
      name: "Checking", type: .bank,
      balance: InstrumentAmount(
        quantity: Decimal(100000) / 100, instrument: Instrument.defaultTestInstrument))
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(accounts: [account], in: container)
    let store = AccountStore(repository: backend.accounts)

    await store.load()

    #expect(store.accounts.count == 1)
    #expect(store.accounts.first?.name == "Checking")
  }

  @Test func testSortingByPosition() async throws {
    let a1 = Account(
      name: "A1", type: .bank,
      balance: InstrumentAmount(
        quantity: Decimal(10000) / 100, instrument: Instrument.defaultTestInstrument),
      position: 2
    )
    let a2 = Account(
      name: "A2", type: .asset,
      balance: InstrumentAmount(
        quantity: Decimal(20000) / 100, instrument: Instrument.defaultTestInstrument),
      position: 1
    )
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(accounts: [a1, a2], in: container)
    let store = AccountStore(repository: backend.accounts)

    await store.load()

    #expect(store.accounts.count == 2)
    #expect(store.accounts[0].name == "A2")
    #expect(store.accounts[1].name == "A1")
  }

  @Test func testCalculatesTotals() async throws {
    let accounts = [
      Account(
        name: "Bank", type: .bank,
        balance: InstrumentAmount(
          quantity: Decimal(100000) / 100, instrument: Instrument.defaultTestInstrument)),
      Account(
        name: "Asset", type: .asset,
        balance: InstrumentAmount(
          quantity: Decimal(500000) / 100, instrument: Instrument.defaultTestInstrument)),
      Account(
        name: "Credit Card", type: .creditCard,
        balance: InstrumentAmount(
          quantity: Decimal(-50000) / 100, instrument: Instrument.defaultTestInstrument)),
      Account(
        name: "Investment", type: .investment,
        balance: InstrumentAmount(
          quantity: Decimal(2_000_000) / 100, instrument: Instrument.defaultTestInstrument)),
      Account(
        name: "Hidden", type: .asset,
        balance: InstrumentAmount(
          quantity: Decimal(100_000_000) / 100, instrument: Instrument.defaultTestInstrument),
        isHidden: true),
    ]
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(accounts: accounts, in: container)
    let store = AccountStore(repository: backend.accounts)

    await store.load()

    #expect(
      store.currentTotal
        == InstrumentAmount(
          quantity: Decimal(550000) / 100, instrument: Instrument.defaultTestInstrument))  // 100000 + 500000 - 50000
    #expect(
      store.investmentTotal
        == InstrumentAmount(
          quantity: Decimal(2_000_000) / 100, instrument: Instrument.defaultTestInstrument))
    #expect(
      store.netWorth
        == InstrumentAmount(
          quantity: Decimal(2_550_000) / 100, instrument: Instrument.defaultTestInstrument)
    )
  }

  @Test func testAvailableFundsWithNoEarmarks() async throws {
    let accounts = [
      Account(
        name: "Checking", type: .bank,
        balance: InstrumentAmount(
          quantity: Decimal(100000) / 100, instrument: Instrument.defaultTestInstrument)),
      Account(
        name: "Savings", type: .asset,
        balance: InstrumentAmount(
          quantity: Decimal(500000) / 100, instrument: Instrument.defaultTestInstrument)),
    ]
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(accounts: accounts, in: container)
    let store = AccountStore(repository: backend.accounts)

    await store.load()

    let noEarmarks = Earmarks(from: [])
    #expect(
      store.availableFunds(earmarks: noEarmarks)
        == InstrumentAmount(
          quantity: Decimal(600000) / 100, instrument: Instrument.defaultTestInstrument))
  }

  @Test func testAvailableFundsSubtractsPositiveEarmarks() async throws {
    let accounts = [
      Account(
        name: "Checking", type: .bank,
        balance: InstrumentAmount(
          quantity: Decimal(100000) / 100, instrument: Instrument.defaultTestInstrument)),
      Account(
        name: "Savings", type: .asset,
        balance: InstrumentAmount(
          quantity: Decimal(500000) / 100, instrument: Instrument.defaultTestInstrument)),
    ]
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(accounts: accounts, in: container)
    let store = AccountStore(repository: backend.accounts)

    await store.load()

    let earmarks = Earmarks(from: [
      Earmark(
        name: "Holiday",
        balance: InstrumentAmount(
          quantity: Decimal(150000) / 100, instrument: Instrument.defaultTestInstrument)),
      Earmark(
        name: "Emergency",
        balance: InstrumentAmount(
          quantity: Decimal(50000) / 100, instrument: Instrument.defaultTestInstrument)),
    ])
    // 600000 - 150000 - 50000 = 400000
    #expect(
      store.availableFunds(earmarks: earmarks)
        == InstrumentAmount(
          quantity: Decimal(400000) / 100, instrument: Instrument.defaultTestInstrument))
  }

  @Test func testAvailableFundsIgnoresNegativeEarmarkBalances() async throws {
    let accounts = [
      Account(
        name: "Checking", type: .bank,
        balance: InstrumentAmount(
          quantity: Decimal(100000) / 100, instrument: Instrument.defaultTestInstrument))
    ]
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(accounts: accounts, in: container)
    let store = AccountStore(repository: backend.accounts)

    await store.load()

    let earmarks = Earmarks(from: [
      Earmark(
        name: "Positive",
        balance: InstrumentAmount(
          quantity: Decimal(30000) / 100, instrument: Instrument.defaultTestInstrument)),
      Earmark(
        name: "Negative",
        balance: InstrumentAmount(
          quantity: Decimal(-10000) / 100, instrument: Instrument.defaultTestInstrument)),
    ])
    // 100000 - 30000 = 70000 (negative earmark ignored)
    #expect(
      store.availableFunds(earmarks: earmarks)
        == InstrumentAmount(
          quantity: Decimal(70000) / 100, instrument: Instrument.defaultTestInstrument))
  }

  @Test func testAvailableFundsIgnoresHiddenEarmarks() async throws {
    let accounts = [
      Account(
        name: "Checking", type: .bank,
        balance: InstrumentAmount(
          quantity: Decimal(100000) / 100, instrument: Instrument.defaultTestInstrument))
    ]
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(accounts: accounts, in: container)
    let store = AccountStore(repository: backend.accounts)

    await store.load()

    let earmarks = Earmarks(from: [
      Earmark(
        name: "Visible",
        balance: InstrumentAmount(
          quantity: Decimal(20000) / 100, instrument: Instrument.defaultTestInstrument)),
      Earmark(
        name: "Hidden",
        balance: InstrumentAmount(
          quantity: Decimal(50000) / 100, instrument: Instrument.defaultTestInstrument),
        isHidden: true),
    ])
    // 100000 - 20000 = 80000 (hidden earmark ignored)
    #expect(
      store.availableFunds(earmarks: earmarks)
        == InstrumentAmount(
          quantity: Decimal(80000) / 100, instrument: Instrument.defaultTestInstrument))
  }

  // MARK: - applyTransactionDelta

  @Test func testCreateExpenseReducesAccountBalance() async throws {
    let acctId = UUID()
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(
      accounts: [
        Account(
          id: acctId, name: "Checking", type: .bank,
          balance: InstrumentAmount(
            quantity: Decimal(100000) / 100, instrument: Instrument.defaultTestInstrument))
      ], in: container)
    let store = AccountStore(repository: backend.accounts)
    await store.load()

    let tx = Transaction(
      date: Date(),
      payee: "Coffee",
      legs: [
        TransactionLeg(
          accountId: acctId, instrument: Instrument.defaultTestInstrument,
          quantity: Decimal(-5000) / 100, type: .expense)
      ]
    )
    store.applyTransactionDelta(old: nil, new: tx)

    #expect(store.accounts.by(id: acctId)?.balance.quantity == Decimal(95000) / 100)
  }

  @Test func testCreateIncomeIncreasesAccountBalance() async throws {
    let acctId = UUID()
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(
      accounts: [
        Account(
          id: acctId, name: "Checking", type: .bank,
          balance: InstrumentAmount(
            quantity: Decimal(100000) / 100, instrument: Instrument.defaultTestInstrument))
      ], in: container)
    let store = AccountStore(repository: backend.accounts)
    await store.load()

    let tx = Transaction(
      date: Date(),
      payee: "Salary",
      legs: [
        TransactionLeg(
          accountId: acctId, instrument: Instrument.defaultTestInstrument,
          quantity: Decimal(50000) / 100, type: .income)
      ]
    )
    store.applyTransactionDelta(old: nil, new: tx)

    #expect(store.accounts.by(id: acctId)?.balance.quantity == Decimal(150000) / 100)
  }

  @Test func testDeleteRevertsAccountBalance() async throws {
    let acctId = UUID()
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(
      accounts: [
        Account(
          id: acctId, name: "Checking", type: .bank,
          balance: InstrumentAmount(
            quantity: Decimal(95000) / 100, instrument: Instrument.defaultTestInstrument))
      ], in: container)
    let store = AccountStore(repository: backend.accounts)
    await store.load()

    let tx = Transaction(
      date: Date(),
      payee: "Coffee",
      legs: [
        TransactionLeg(
          accountId: acctId, instrument: Instrument.defaultTestInstrument,
          quantity: Decimal(-5000) / 100, type: .expense)
      ]
    )
    store.applyTransactionDelta(old: tx, new: nil)

    // Removing a -5000 expense should add 5000 back
    #expect(store.accounts.by(id: acctId)?.balance.quantity == Decimal(100000) / 100)
  }

  @Test func testUpdateAdjustsAccountBalance() async throws {
    let acctId = UUID()
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(
      accounts: [
        Account(
          id: acctId, name: "Checking", type: .bank,
          balance: InstrumentAmount(
            quantity: Decimal(95000) / 100, instrument: Instrument.defaultTestInstrument))
      ], in: container)
    let store = AccountStore(repository: backend.accounts)
    await store.load()

    let oldTx = Transaction(
      date: Date(),
      payee: "Coffee",
      legs: [
        TransactionLeg(
          accountId: acctId, instrument: Instrument.defaultTestInstrument,
          quantity: Decimal(-5000) / 100, type: .expense)
      ]
    )
    let newTx = Transaction(
      id: oldTx.id,
      date: oldTx.date,
      payee: "Coffee",
      legs: [
        TransactionLeg(
          accountId: acctId, instrument: Instrument.defaultTestInstrument,
          quantity: Decimal(-7500) / 100, type: .expense)
      ]
    )

    store.applyTransactionDelta(old: oldTx, new: newTx)

    // Was 95000 (after -5000 expense). Remove old (-(-5000) = +5000 → 100000), apply new (-7500 → 92500)
    #expect(store.accounts.by(id: acctId)?.balance.quantity == Decimal(92500) / 100)
  }

  @Test func testTransferUpdatesBothAccounts() async throws {
    let checkingId = UUID()
    let savingsId = UUID()
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(
      accounts: [
        Account(
          id: checkingId, name: "Checking", type: .bank,
          balance: InstrumentAmount(
            quantity: Decimal(100000) / 100, instrument: Instrument.defaultTestInstrument)),
        Account(
          id: savingsId, name: "Savings", type: .bank,
          balance: InstrumentAmount(
            quantity: Decimal(200000) / 100, instrument: Instrument.defaultTestInstrument)),
      ], in: container)
    let store = AccountStore(repository: backend.accounts)
    await store.load()

    // Transfer $100 from checking to savings (amount is -10000 from source perspective)
    let tx = Transaction(
      date: Date(),
      legs: [
        TransactionLeg(
          accountId: checkingId, instrument: Instrument.defaultTestInstrument,
          quantity: Decimal(-10000) / 100, type: .transfer),
        TransactionLeg(
          accountId: savingsId, instrument: Instrument.defaultTestInstrument,
          quantity: Decimal(10000) / 100, type: .transfer),
      ]
    )
    store.applyTransactionDelta(old: nil, new: tx)

    #expect(store.accounts.by(id: checkingId)?.balance.quantity == Decimal(90000) / 100)
    #expect(store.accounts.by(id: savingsId)?.balance.quantity == Decimal(210000) / 100)
  }

  @Test func testDeleteTransferRevertsBothAccounts() async throws {
    let checkingId = UUID()
    let savingsId = UUID()
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(
      accounts: [
        Account(
          id: checkingId, name: "Checking", type: .bank,
          balance: InstrumentAmount(
            quantity: Decimal(90000) / 100, instrument: Instrument.defaultTestInstrument)),
        Account(
          id: savingsId, name: "Savings", type: .bank,
          balance: InstrumentAmount(
            quantity: Decimal(210000) / 100, instrument: Instrument.defaultTestInstrument)),
      ], in: container)
    let store = AccountStore(repository: backend.accounts)
    await store.load()

    let tx = Transaction(
      date: Date(),
      legs: [
        TransactionLeg(
          accountId: checkingId, instrument: Instrument.defaultTestInstrument,
          quantity: Decimal(-10000) / 100, type: .transfer),
        TransactionLeg(
          accountId: savingsId, instrument: Instrument.defaultTestInstrument,
          quantity: Decimal(10000) / 100, type: .transfer),
      ]
    )
    store.applyTransactionDelta(old: tx, new: nil)

    #expect(store.accounts.by(id: checkingId)?.balance.quantity == Decimal(100000) / 100)
    #expect(store.accounts.by(id: savingsId)?.balance.quantity == Decimal(200000) / 100)
  }

  @Test func testTotalsUpdateAfterDelta() async throws {
    let checkingId = UUID()
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(
      accounts: [
        Account(
          id: checkingId, name: "Checking", type: .bank,
          balance: InstrumentAmount(
            quantity: Decimal(100000) / 100, instrument: Instrument.defaultTestInstrument))
      ], in: container)
    let store = AccountStore(repository: backend.accounts)
    await store.load()

    #expect(store.currentTotal.quantity == Decimal(100000) / 100)
    #expect(store.netWorth.quantity == Decimal(100000) / 100)

    let tx = Transaction(
      date: Date(),
      payee: "Coffee",
      legs: [
        TransactionLeg(
          accountId: checkingId, instrument: Instrument.defaultTestInstrument,
          quantity: Decimal(-5000) / 100, type: .expense)
      ]
    )
    store.applyTransactionDelta(old: nil, new: tx)

    #expect(store.currentTotal.quantity == Decimal(95000) / 100)
    #expect(store.netWorth.quantity == Decimal(95000) / 100)
  }

  @Test func testScheduledTransactionDoesNotAffectBalance() async throws {
    let acctId = UUID()
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(
      accounts: [
        Account(
          id: acctId, name: "Checking", type: .bank,
          balance: MonetaryAmount(cents: 100000, currency: Currency.defaultTestCurrency))
      ], in: container)
    let store = AccountStore(repository: backend.accounts)
    await store.load()

    let scheduledTx = Transaction(
      type: .expense, date: Date(), accountId: acctId,
      amount: MonetaryAmount(cents: -5000, currency: Currency.defaultTestCurrency),
      payee: "Rent", recurPeriod: .month, recurEvery: 1
    )
    store.applyTransactionDelta(old: nil, new: scheduledTx)

    // Scheduled transactions should not change the balance
    #expect(store.accounts.by(id: acctId)?.balance.cents == 100000)
  }

  @Test func testDeleteScheduledTransactionDoesNotAffectBalance() async throws {
    let acctId = UUID()
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(
      accounts: [
        Account(
          id: acctId, name: "Checking", type: .bank,
          balance: MonetaryAmount(cents: 100000, currency: Currency.defaultTestCurrency))
      ], in: container)
    let store = AccountStore(repository: backend.accounts)
    await store.load()

    let scheduledTx = Transaction(
      type: .expense, date: Date(), accountId: acctId,
      amount: MonetaryAmount(cents: -5000, currency: Currency.defaultTestCurrency),
      payee: "Rent", recurPeriod: .month, recurEvery: 1
    )
    store.applyTransactionDelta(old: scheduledTx, new: nil)

    // Deleting a scheduled transaction should not change the balance
    #expect(store.accounts.by(id: acctId)?.balance.cents == 100000)
  }

  @Test func testPayOneTimeScheduledTransactionUpdatesBalance() async throws {
    let acctId = UUID()
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(
      accounts: [
        Account(
          id: acctId, name: "Checking", type: .bank,
          balance: MonetaryAmount(cents: 100000, currency: Currency.defaultTestCurrency))
      ], in: container)
    let store = AccountStore(repository: backend.accounts)
    await store.load()

    let scheduledTx = Transaction(
      type: .expense, date: Date(), accountId: acctId,
      amount: MonetaryAmount(cents: -5000, currency: Currency.defaultTestCurrency),
      payee: "Bill", recurPeriod: .once, recurEvery: 1
    )

    // Simulate paying: create non-scheduled copy, then delete the scheduled original
    let paidTx = Transaction(
      id: UUID(), type: .expense, date: Date(), accountId: acctId,
      amount: MonetaryAmount(cents: -5000, currency: Currency.defaultTestCurrency),
      payee: "Bill"
    )
    store.applyTransactionDelta(old: nil, new: paidTx)
    store.applyTransactionDelta(old: scheduledTx, new: nil)

    // Only the paid (non-scheduled) transaction should affect the balance
    #expect(store.accounts.by(id: acctId)?.balance.cents == 95000)
  }

  // MARK: - Show Hidden

  @Test("currentAccounts excludes hidden accounts by default")
  func hiddenAccountsExcluded() async throws {
    let visible = Account(
      name: "Visible", type: .bank,
      balance: InstrumentAmount(
        quantity: Decimal(100000) / 100, instrument: Instrument.defaultTestInstrument))
    let hidden = Account(
      name: "Hidden", type: .bank,
      balance: InstrumentAmount(
        quantity: Decimal(50000) / 100, instrument: Instrument.defaultTestInstrument),
      isHidden: true)
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(accounts: [visible, hidden], in: container)
    let store = AccountStore(repository: backend.accounts)

    await store.load()

    #expect(store.currentAccounts.count == 1)
    #expect(store.currentAccounts[0].name == "Visible")
  }

  @Test("currentAccounts includes hidden accounts when showHidden is true")
  func hiddenAccountsIncluded() async throws {
    let visible = Account(
      name: "Visible", type: .bank,
      balance: InstrumentAmount(
        quantity: Decimal(100000) / 100, instrument: Instrument.defaultTestInstrument))
    let hidden = Account(
      name: "Hidden", type: .bank,
      balance: InstrumentAmount(
        quantity: Decimal(50000) / 100, instrument: Instrument.defaultTestInstrument),
      isHidden: true)
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(accounts: [visible, hidden], in: container)
    let store = AccountStore(repository: backend.accounts)

    await store.load()
    store.showHidden = true

    #expect(store.currentAccounts.count == 2)
  }

  @Test("investmentAccounts respects showHidden flag")
  func hiddenInvestmentAccounts() async throws {
    let visible = Account(
      name: "Visible", type: .investment,
      balance: InstrumentAmount(
        quantity: Decimal(100000) / 100, instrument: Instrument.defaultTestInstrument))
    let hidden = Account(
      name: "Hidden", type: .investment,
      balance: InstrumentAmount(
        quantity: Decimal(50000) / 100, instrument: Instrument.defaultTestInstrument),
      isHidden: true)
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(accounts: [visible, hidden], in: container)
    let store = AccountStore(repository: backend.accounts)

    await store.load()

    #expect(store.investmentAccounts.count == 1)
    store.showHidden = true
    #expect(store.investmentAccounts.count == 2)
  }
}
