import Foundation
import SwiftData
import Testing

@testable import Moolah

@Suite("AccountStore")
@MainActor
struct AccountStoreTests {

  private func seedAccount(
    id: UUID = UUID(),
    name: String,
    type: AccountType = .bank,
    instrument: Instrument = .defaultTestInstrument,
    balance: Decimal = 0,
    position: Int = 0,
    isHidden: Bool = false,
    in container: ModelContainer
  ) -> Account {
    let account = Account(
      id: id, name: name, type: type, instrument: instrument, position: position,
      isHidden: isHidden)
    let balanceAmount = InstrumentAmount(quantity: balance, instrument: instrument)
    TestBackend.seed(
      accounts: [(account: account, openingBalance: balanceAmount)],
      in: container,
      instrument: instrument)
    return account
  }

  @Test func testPopulatesFromRepository() async throws {
    let (backend, container) = try TestBackend.create()
    _ = seedAccount(name: "Checking", balance: Decimal(100000) / 100, in: container)
    let store = AccountStore(repository: backend.accounts, targetInstrument: .defaultTestInstrument)

    await store.load()

    #expect(store.accounts.count == 1)
    #expect(store.accounts.first?.name == "Checking")
  }

  @Test func testSortingByPosition() async throws {
    let (backend, container) = try TestBackend.create()
    _ = seedAccount(name: "A1", balance: Decimal(10000) / 100, position: 2, in: container)
    _ = seedAccount(
      name: "A2", type: .asset, balance: Decimal(20000) / 100, position: 1, in: container)
    let store = AccountStore(repository: backend.accounts, targetInstrument: .defaultTestInstrument)

    await store.load()

    #expect(store.accounts.count == 2)
    #expect(store.accounts[0].name == "A2")
    #expect(store.accounts[1].name == "A1")
  }

  @Test func testCalculatesTotals() async throws {
    let (backend, container) = try TestBackend.create()
    _ = seedAccount(name: "Bank", balance: Decimal(100000) / 100, in: container)
    _ = seedAccount(name: "Asset", type: .asset, balance: Decimal(500000) / 100, in: container)
    _ = seedAccount(
      name: "Credit Card", type: .creditCard, balance: Decimal(-50000) / 100, in: container)
    _ = seedAccount(
      name: "Investment", type: .investment, balance: Decimal(2_000_000) / 100, in: container)
    _ = seedAccount(
      name: "Hidden", type: .asset, balance: Decimal(100_000_000) / 100, isHidden: true,
      in: container)

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
    let (backend, container) = try TestBackend.create()
    _ = seedAccount(
      name: "Invest", type: .investment, balance: Decimal(100000) / 100, in: container)
    let store = AccountStore(repository: backend.accounts, targetInstrument: .defaultTestInstrument)
    await store.load()

    let newValue = InstrumentAmount(
      quantity: Decimal(150000) / 100, instrument: Instrument.defaultTestInstrument)

    let account = store.accounts.first!
    store.updateInvestmentValue(accountId: account.id, value: newValue)
    #expect(store.investmentValues[account.id] == newValue)
    #expect(store.displayBalance(for: account.id) == newValue)
  }

  @Test func testUpdateInvestmentValueClearsValue() async throws {
    let (backend, container) = try TestBackend.create()
    _ = seedAccount(
      name: "Invest", type: .investment, balance: Decimal(100000) / 100, in: container)
    let store = AccountStore(repository: backend.accounts, targetInstrument: .defaultTestInstrument)
    await store.load()

    let account = store.accounts.first!
    let investmentValue = InstrumentAmount(
      quantity: Decimal(200000) / 100, instrument: Instrument.defaultTestInstrument)
    store.updateInvestmentValue(accountId: account.id, value: investmentValue)
    store.updateInvestmentValue(accountId: account.id, value: nil)

    #expect(store.investmentValues[account.id] == nil)
    // displayBalance falls back to position balance when investmentValue is nil
    #expect(
      store.displayBalance(for: account.id)
        == InstrumentAmount(
          quantity: Decimal(100000) / 100, instrument: Instrument.defaultTestInstrument))
  }

  @Test func testUpdateInvestmentValueIgnoresUnknownAccount() async throws {
    let (backend, container) = try TestBackend.create()
    _ = seedAccount(
      name: "Invest", type: .investment, balance: Decimal(100000) / 100, in: container)
    let store = AccountStore(repository: backend.accounts, targetInstrument: .defaultTestInstrument)
    await store.load()

    let newValue = InstrumentAmount(
      quantity: Decimal(150000) / 100, instrument: Instrument.defaultTestInstrument)
    store.updateInvestmentValue(accountId: UUID(), value: newValue)

    // Should not affect existing accounts
    #expect(store.accounts.count == 1)
    #expect(store.investmentValues.isEmpty)
  }

  // MARK: - Show Hidden

  @Test("currentAccounts excludes hidden accounts by default")
  func hiddenAccountsExcluded() async throws {
    let (backend, container) = try TestBackend.create()
    _ = seedAccount(name: "Visible", balance: Decimal(100000) / 100, in: container)
    _ = seedAccount(
      name: "Hidden", balance: Decimal(50000) / 100, isHidden: true, in: container)
    let store = AccountStore(repository: backend.accounts, targetInstrument: .defaultTestInstrument)

    await store.load()

    #expect(store.currentAccounts.count == 1)
    #expect(store.currentAccounts[0].name == "Visible")
  }

  @Test("currentAccounts includes hidden accounts when showHidden is true")
  func hiddenAccountsIncluded() async throws {
    let (backend, container) = try TestBackend.create()
    _ = seedAccount(name: "Visible", balance: Decimal(100000) / 100, in: container)
    _ = seedAccount(
      name: "Hidden", balance: Decimal(50000) / 100, isHidden: true, in: container)
    let store = AccountStore(repository: backend.accounts, targetInstrument: .defaultTestInstrument)

    await store.load()
    store.showHidden = true

    #expect(store.currentAccounts.count == 2)
  }

  @Test("investmentAccounts respects showHidden flag")
  func hiddenInvestmentAccounts() async throws {
    let (backend, container) = try TestBackend.create()
    _ = seedAccount(
      name: "Visible", type: .investment, balance: Decimal(100000) / 100, in: container)
    _ = seedAccount(
      name: "Hidden", type: .investment, balance: Decimal(50000) / 100, isHidden: true,
      in: container)
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
    _ = seedAccount(
      id: acctId, name: "Checking", balance: Decimal(100000) / 100, in: container)
    let store = AccountStore(repository: backend.accounts, targetInstrument: .defaultTestInstrument)
    await store.load()

    let deltas: PositionDeltas = [acctId: [instrument: Decimal(-5000) / 100]]
    store.applyDelta(deltas)

    #expect(store.balance(for: acctId).quantity == Decimal(95000) / 100)
  }

  @Test func testApplyDeltaIncreasesAccountBalance() async throws {
    let acctId = UUID()
    let instrument = Instrument.defaultTestInstrument
    let (backend, container) = try TestBackend.create()
    _ = seedAccount(
      id: acctId, name: "Checking", balance: Decimal(100000) / 100, in: container)
    let store = AccountStore(repository: backend.accounts, targetInstrument: .defaultTestInstrument)
    await store.load()

    let deltas: PositionDeltas = [acctId: [instrument: Decimal(50000) / 100]]
    store.applyDelta(deltas)

    #expect(store.balance(for: acctId).quantity == Decimal(150000) / 100)
  }

  @Test func testApplyDeltaUpdatesBothAccounts() async throws {
    let checkingId = UUID()
    let savingsId = UUID()
    let instrument = Instrument.defaultTestInstrument
    let (backend, container) = try TestBackend.create()
    _ = seedAccount(
      id: checkingId, name: "Checking", balance: Decimal(100000) / 100, in: container)
    _ = seedAccount(
      id: savingsId, name: "Savings", balance: Decimal(200000) / 100, in: container)
    let store = AccountStore(repository: backend.accounts, targetInstrument: .defaultTestInstrument)
    await store.load()

    let deltas: PositionDeltas = [
      checkingId: [instrument: Decimal(-10000) / 100],
      savingsId: [instrument: Decimal(10000) / 100],
    ]
    store.applyDelta(deltas)

    #expect(store.balance(for: checkingId).quantity == Decimal(90000) / 100)
    #expect(store.balance(for: savingsId).quantity == Decimal(210000) / 100)
  }

  @Test func testApplyDeltaUpdatesTotals() async throws {
    let checkingId = UUID()
    let instrument = Instrument.defaultTestInstrument
    let (backend, container) = try TestBackend.create()
    _ = seedAccount(
      id: checkingId, name: "Checking", balance: Decimal(100000) / 100, in: container)
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
    _ = seedAccount(
      id: acctId, name: "Checking", balance: Decimal(100000) / 100, in: container)
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

    #expect(store.balance(for: acctId).quantity == Decimal(95000) / 100)
  }

  @Test func testApplyDeltaIgnoresUnknownAccount() async throws {
    let acctId = UUID()
    let unknownId = UUID()
    let instrument = Instrument.defaultTestInstrument
    let (backend, container) = try TestBackend.create()
    _ = seedAccount(
      id: acctId, name: "Checking", balance: Decimal(100000) / 100, in: container)
    let store = AccountStore(repository: backend.accounts, targetInstrument: .defaultTestInstrument)
    await store.load()

    let deltas: PositionDeltas = [unknownId: [instrument: Decimal(-5000) / 100]]
    store.applyDelta(deltas)

    // Balance should be unchanged
    #expect(store.balance(for: acctId).quantity == Decimal(100000) / 100)
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
    _ = seedAccount(name: "Checking", balance: Decimal(100000) / 100, in: container)
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
    _ = seedAccount(
      id: acctId, name: "Checking", balance: Decimal(100000) / 100, in: container)
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

  // MARK: - Balance and Display Balance

  @Test func testBalanceForAccountReturnsPositionAmount() async throws {
    let acctId = UUID()
    let (backend, container) = try TestBackend.create()
    _ = seedAccount(
      id: acctId, name: "Checking", balance: Decimal(100000) / 100, in: container)
    let store = AccountStore(repository: backend.accounts, targetInstrument: .defaultTestInstrument)
    await store.load()

    #expect(store.balance(for: acctId).quantity == Decimal(100000) / 100)
  }

  @Test func testDisplayBalanceReturnsInvestmentValueForInvestmentAccount() async throws {
    let acctId = UUID()
    let (backend, container) = try TestBackend.create()
    _ = seedAccount(
      id: acctId, name: "Invest", type: .investment, balance: Decimal(100000) / 100,
      in: container)
    let store = AccountStore(repository: backend.accounts, targetInstrument: .defaultTestInstrument)
    await store.load()

    let investmentValue = InstrumentAmount(
      quantity: Decimal(150000) / 100, instrument: Instrument.defaultTestInstrument)
    store.updateInvestmentValue(accountId: acctId, value: investmentValue)

    #expect(store.displayBalance(for: acctId) == investmentValue)
  }

  @Test func testCanDeleteReturnsTrueForZeroPositions() async throws {
    let acctId = UUID()
    let (backend, container) = try TestBackend.create()
    _ = seedAccount(id: acctId, name: "Empty", in: container)
    let store = AccountStore(repository: backend.accounts, targetInstrument: .defaultTestInstrument)
    await store.load()

    #expect(store.canDelete(acctId))
  }

  @Test func testCanDeleteReturnsFalseForNonZeroPositions() async throws {
    let acctId = UUID()
    let (backend, container) = try TestBackend.create()
    _ = seedAccount(
      id: acctId, name: "Active", balance: Decimal(100000) / 100, in: container)
    let store = AccountStore(repository: backend.accounts, targetInstrument: .defaultTestInstrument)
    await store.load()

    #expect(!store.canDelete(acctId))
  }

  // MARK: - Instrument Persistence

  @Test func testCreatePersistsInstrument() async throws {
    let (backend, _) = try TestBackend.create()
    let store = AccountStore(repository: backend.accounts)
    let usdInstrument = Instrument.fiat(code: "USD")
    let account = Account(
      id: UUID(), name: "USD Checking", type: .bank, instrument: usdInstrument, position: 0,
      isHidden: false)

    let created = try await store.create(account, openingBalance: nil)

    #expect(created.instrument.id == usdInstrument.id)
    #expect(store.accounts.first?.instrument.id == usdInstrument.id)

    let fetched = try await backend.accounts.fetchAll()
    #expect(fetched.first?.instrument.id == usdInstrument.id)
  }

  @Test func testUpdatePersistsChangedInstrument() async throws {
    let (backend, container) = try TestBackend.create()
    let original = seedAccount(name: "Savings", in: container)
    let store = AccountStore(repository: backend.accounts)

    let eurInstrument = Instrument.fiat(code: "EUR")
    var modified = original
    modified.instrument = eurInstrument

    let updated = try await store.update(modified)

    #expect(updated.instrument.id == eurInstrument.id)

    let fetched = try await backend.accounts.fetchAll()
    #expect(fetched.first?.instrument.id == eurInstrument.id)
  }
}
