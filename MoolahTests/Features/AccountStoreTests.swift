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
    let store = AccountStore(repository: backend.accounts, targetInstrument: .defaultTestInstrument)

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
    let store = AccountStore(repository: backend.accounts, targetInstrument: .defaultTestInstrument)

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
    let store = AccountStore(repository: backend.accounts, targetInstrument: .defaultTestInstrument)

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
    let store = AccountStore(repository: backend.accounts, targetInstrument: .defaultTestInstrument)
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
    let store = AccountStore(repository: backend.accounts, targetInstrument: .defaultTestInstrument)
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
    let store = AccountStore(repository: backend.accounts, targetInstrument: .defaultTestInstrument)
    await store.load()

    let newValue = InstrumentAmount(
      quantity: Decimal(150000) / 100, instrument: Instrument.defaultTestInstrument)
    store.updateInvestmentValue(accountId: UUID(), value: newValue)

    // Should not affect existing accounts
    #expect(store.accounts.count == 1)
    #expect(store.accounts.first?.investmentValue == nil)
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
    let store = AccountStore(repository: backend.accounts, targetInstrument: .defaultTestInstrument)

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
    let store = AccountStore(repository: backend.accounts, targetInstrument: .defaultTestInstrument)

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
    let store = AccountStore(repository: backend.accounts, targetInstrument: .defaultTestInstrument)

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
    let store = AccountStore(repository: backend.accounts, targetInstrument: .defaultTestInstrument)
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
    let store = AccountStore(repository: backend.accounts, targetInstrument: .defaultTestInstrument)
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
    let store = AccountStore(repository: backend.accounts, targetInstrument: .defaultTestInstrument)
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
    let store = AccountStore(repository: backend.accounts, targetInstrument: .defaultTestInstrument)
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
    let store = AccountStore(repository: backend.accounts, targetInstrument: .defaultTestInstrument)
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
    let store = AccountStore(repository: backend.accounts, targetInstrument: .defaultTestInstrument)
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
