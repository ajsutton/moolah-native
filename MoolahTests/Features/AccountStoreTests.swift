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

  // MARK: - updateInvestmentValue

  @Test func testUpdateInvestmentValueSetsValue() async throws {
    let acctId = UUID()
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(
      accounts: [
        Account(
          name: "Invest", type: .investment,
          balance: InstrumentAmount(
            quantity: Decimal(100000) / 100, instrument: Instrument.defaultTestInstrument))
      ], in: container)
    let store = AccountStore(repository: backend.accounts)
    await store.load()

    let newValue = InstrumentAmount(
      quantity: Decimal(150000) / 100, instrument: Instrument.defaultTestInstrument)
    store.updateInvestmentValue(accountId: acctId, value: newValue)

    // Uses seed account ID, but accounts from seed get new IDs. Use first account.
    let account = store.accounts.first
    #expect(account != nil)
    // Since seed creates new UUIDs, update using the actual ID
    let actualId = account!.id
    store.updateInvestmentValue(accountId: actualId, value: newValue)
    #expect(store.accounts.by(id: actualId)?.investmentValue == newValue)
    #expect(store.accounts.by(id: actualId)?.displayBalance == newValue)
  }

  @Test func testUpdateInvestmentValueClearsValue() async throws {
    let (backend, container) = try TestBackend.create()
    let investmentValue = InstrumentAmount(
      quantity: Decimal(200000) / 100, instrument: Instrument.defaultTestInstrument)
    TestBackend.seed(
      accounts: [
        Account(
          name: "Invest", type: .investment,
          balance: InstrumentAmount(
            quantity: Decimal(100000) / 100, instrument: Instrument.defaultTestInstrument),
          investmentValue: investmentValue)
      ], in: container)
    let store = AccountStore(repository: backend.accounts)
    await store.load()

    let account = store.accounts.first!
    store.updateInvestmentValue(accountId: account.id, value: nil)

    #expect(store.accounts.by(id: account.id)?.investmentValue == nil)
    // displayBalance falls back to balance when investmentValue is nil
    #expect(
      store.accounts.by(id: account.id)?.displayBalance
        == InstrumentAmount(
          quantity: Decimal(100000) / 100, instrument: Instrument.defaultTestInstrument))
  }

  @Test func testUpdateInvestmentValueIgnoresUnknownAccount() async throws {
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(
      accounts: [
        Account(
          name: "Invest", type: .investment,
          balance: InstrumentAmount(
            quantity: Decimal(100000) / 100, instrument: Instrument.defaultTestInstrument))
      ], in: container)
    let store = AccountStore(repository: backend.accounts)
    await store.load()

    let newValue = InstrumentAmount(
      quantity: Decimal(150000) / 100, instrument: Instrument.defaultTestInstrument)
    store.updateInvestmentValue(accountId: UUID(), value: newValue)

    // Should not affect existing accounts
    #expect(store.accounts.count == 1)
    #expect(store.accounts.first?.investmentValue == nil)
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
    let instrument = Instrument.defaultTestInstrument
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(
      accounts: [
        Account(
          id: acctId, name: "Checking", type: .bank,
          balance: InstrumentAmount(quantity: 1000, instrument: instrument))
      ], in: container)
    let store = AccountStore(repository: backend.accounts)
    await store.load()

    let scheduledTx = Transaction(
      date: Date(), payee: "Rent",
      recurPeriod: .month, recurEvery: 1,
      legs: [
        TransactionLeg(accountId: acctId, instrument: instrument, quantity: -50, type: .expense)
      ]
    )
    store.applyTransactionDelta(old: nil, new: scheduledTx)

    // Scheduled transactions should not change the balance
    #expect(store.accounts.by(id: acctId)?.balance.quantity == 1000)
  }

  @Test func testDeleteScheduledTransactionDoesNotAffectBalance() async throws {
    let acctId = UUID()
    let instrument = Instrument.defaultTestInstrument
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(
      accounts: [
        Account(
          id: acctId, name: "Checking", type: .bank,
          balance: InstrumentAmount(quantity: 1000, instrument: instrument))
      ], in: container)
    let store = AccountStore(repository: backend.accounts)
    await store.load()

    let scheduledTx = Transaction(
      date: Date(), payee: "Rent",
      recurPeriod: .month, recurEvery: 1,
      legs: [
        TransactionLeg(accountId: acctId, instrument: instrument, quantity: -50, type: .expense)
      ]
    )
    store.applyTransactionDelta(old: scheduledTx, new: nil)

    // Deleting a scheduled transaction should not change the balance
    #expect(store.accounts.by(id: acctId)?.balance.quantity == 1000)
  }

  @Test func testPayOneTimeScheduledTransactionUpdatesBalance() async throws {
    let acctId = UUID()
    let instrument = Instrument.defaultTestInstrument
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(
      accounts: [
        Account(
          id: acctId, name: "Checking", type: .bank,
          balance: InstrumentAmount(quantity: 1000, instrument: instrument))
      ], in: container)
    let store = AccountStore(repository: backend.accounts)
    await store.load()

    let scheduledTx = Transaction(
      date: Date(), payee: "Bill",
      recurPeriod: .once, recurEvery: 1,
      legs: [
        TransactionLeg(accountId: acctId, instrument: instrument, quantity: -50, type: .expense)
      ]
    )

    // Simulate paying: create non-scheduled copy, then delete the scheduled original
    let paidTx = Transaction(
      date: Date(), payee: "Bill",
      legs: [
        TransactionLeg(accountId: acctId, instrument: instrument, quantity: -50, type: .expense)
      ]
    )
    store.applyTransactionDelta(old: nil, new: paidTx)
    store.applyTransactionDelta(old: scheduledTx, new: nil)

    // Only the paid (non-scheduled) transaction should affect the balance
    #expect(store.accounts.by(id: acctId)?.balance.quantity == 950)
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

  // MARK: - applyDelta

  @Test func testApplyDeltaReducesAccountBalance() async throws {
    let acctId = UUID()
    let instrument = Instrument.defaultTestInstrument
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(
      accounts: [
        Account(
          id: acctId, name: "Checking", type: .bank,
          balance: InstrumentAmount(quantity: Decimal(100000) / 100, instrument: instrument))
      ], in: container)
    let store = AccountStore(repository: backend.accounts)
    await store.load()

    let deltas: PositionDeltas = [acctId: [instrument: Decimal(-5000) / 100]]
    store.applyDelta(deltas)

    #expect(store.accounts.by(id: acctId)?.balance.quantity == Decimal(95000) / 100)
  }

  @Test func testApplyDeltaIncreasesAccountBalance() async throws {
    let acctId = UUID()
    let instrument = Instrument.defaultTestInstrument
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(
      accounts: [
        Account(
          id: acctId, name: "Checking", type: .bank,
          balance: InstrumentAmount(quantity: Decimal(100000) / 100, instrument: instrument))
      ], in: container)
    let store = AccountStore(repository: backend.accounts)
    await store.load()

    let deltas: PositionDeltas = [acctId: [instrument: Decimal(50000) / 100]]
    store.applyDelta(deltas)

    #expect(store.accounts.by(id: acctId)?.balance.quantity == Decimal(150000) / 100)
  }

  @Test func testApplyDeltaUpdatesBothAccounts() async throws {
    let checkingId = UUID()
    let savingsId = UUID()
    let instrument = Instrument.defaultTestInstrument
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(
      accounts: [
        Account(
          id: checkingId, name: "Checking", type: .bank,
          balance: InstrumentAmount(quantity: Decimal(100000) / 100, instrument: instrument)),
        Account(
          id: savingsId, name: "Savings", type: .bank,
          balance: InstrumentAmount(quantity: Decimal(200000) / 100, instrument: instrument)),
      ], in: container)
    let store = AccountStore(repository: backend.accounts)
    await store.load()

    let deltas: PositionDeltas = [
      checkingId: [instrument: Decimal(-10000) / 100],
      savingsId: [instrument: Decimal(10000) / 100],
    ]
    store.applyDelta(deltas)

    #expect(store.accounts.by(id: checkingId)?.balance.quantity == Decimal(90000) / 100)
    #expect(store.accounts.by(id: savingsId)?.balance.quantity == Decimal(210000) / 100)
  }

  @Test func testApplyDeltaUpdatesTotals() async throws {
    let checkingId = UUID()
    let instrument = Instrument.defaultTestInstrument
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(
      accounts: [
        Account(
          id: checkingId, name: "Checking", type: .bank,
          balance: InstrumentAmount(quantity: Decimal(100000) / 100, instrument: instrument))
      ], in: container)
    let store = AccountStore(repository: backend.accounts)
    await store.load()

    #expect(store.currentTotal.quantity == Decimal(100000) / 100)

    let deltas: PositionDeltas = [checkingId: [instrument: Decimal(-5000) / 100]]
    store.applyDelta(deltas)

    #expect(store.currentTotal.quantity == Decimal(95000) / 100)
    #expect(store.netWorth.quantity == Decimal(95000) / 100)
  }

  @Test func testApplyDeltaViaBalanceDeltaCalculator() async throws {
    let acctId = UUID()
    let instrument = Instrument.defaultTestInstrument
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(
      accounts: [
        Account(
          id: acctId, name: "Checking", type: .bank,
          balance: InstrumentAmount(quantity: Decimal(100000) / 100, instrument: instrument))
      ], in: container)
    let store = AccountStore(repository: backend.accounts)
    await store.load()

    let tx = Transaction(
      date: Date(),
      payee: "Coffee",
      legs: [
        TransactionLeg(
          accountId: acctId, instrument: instrument,
          quantity: Decimal(-5000) / 100, type: .expense)
      ]
    )
    let delta = BalanceDeltaCalculator.deltas(old: nil, new: tx)
    store.applyDelta(delta.accountDeltas)

    #expect(store.accounts.by(id: acctId)?.balance.quantity == Decimal(95000) / 100)
  }

  @Test func testApplyDeltaIgnoresUnknownAccount() async throws {
    let acctId = UUID()
    let unknownId = UUID()
    let instrument = Instrument.defaultTestInstrument
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(
      accounts: [
        Account(
          id: acctId, name: "Checking", type: .bank,
          balance: InstrumentAmount(quantity: Decimal(100000) / 100, instrument: instrument))
      ], in: container)
    let store = AccountStore(repository: backend.accounts)
    await store.load()

    let deltas: PositionDeltas = [unknownId: [instrument: Decimal(-5000) / 100]]
    store.applyDelta(deltas)

    // Balance should be unchanged
    #expect(store.accounts.by(id: acctId)?.balance.quantity == Decimal(100000) / 100)
  }

  // MARK: - Converted Totals

  @Test func testConvertedTotalsAreNilBeforeLoad() async throws {
    let (backend, _) = try TestBackend.create()
    let store = AccountStore(
      repository: backend.accounts,
      conversionService: backend.conversionService,
      targetInstrument: Instrument.defaultTestInstrument
    )

    #expect(store.convertedCurrentTotal == nil)
    #expect(store.convertedInvestmentTotal == nil)
    #expect(store.convertedNetWorth == nil)
  }

  @Test func testConvertedTotalsPopulatedAfterLoad() async throws {
    let instrument = Instrument.defaultTestInstrument
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(
      accounts: [
        Account(
          name: "Checking", type: .bank,
          balance: InstrumentAmount(quantity: Decimal(100000) / 100, instrument: instrument))
      ], in: container)
    let store = AccountStore(
      repository: backend.accounts,
      conversionService: backend.conversionService,
      targetInstrument: instrument
    )

    await store.load()
    // Wait for async conversion task to complete
    try await Task.sleep(for: .milliseconds(100))

    #expect(store.convertedCurrentTotal != nil)
    #expect(store.convertedCurrentTotal?.quantity == Decimal(100000) / 100)
    #expect(store.convertedNetWorth != nil)
  }

  @Test func testConvertedTotalsUpdateAfterApplyDelta() async throws {
    let acctId = UUID()
    let instrument = Instrument.defaultTestInstrument
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(
      accounts: [
        Account(
          id: acctId, name: "Checking", type: .bank,
          balance: InstrumentAmount(quantity: Decimal(100000) / 100, instrument: instrument))
      ], in: container)
    let store = AccountStore(
      repository: backend.accounts,
      conversionService: backend.conversionService,
      targetInstrument: instrument
    )

    await store.load()
    try await Task.sleep(for: .milliseconds(100))

    #expect(store.convertedCurrentTotal?.quantity == Decimal(100000) / 100)

    let deltas: PositionDeltas = [acctId: [instrument: Decimal(-5000) / 100]]
    store.applyDelta(deltas)
    try await Task.sleep(for: .milliseconds(100))

    #expect(store.convertedCurrentTotal?.quantity == Decimal(95000) / 100)
    #expect(store.convertedNetWorth?.quantity == Decimal(95000) / 100)
  }
}
