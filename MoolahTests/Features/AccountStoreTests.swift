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
    let store = AccountStore(
      repository: backend.accounts, conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument)

    await store.load()

    #expect(store.accounts.count == 1)
    #expect(store.accounts.first?.name == "Checking")
  }

  @Test func testSortingByPosition() async throws {
    let (backend, container) = try TestBackend.create()
    _ = seedAccount(name: "A1", balance: Decimal(10000) / 100, position: 2, in: container)
    _ = seedAccount(
      name: "A2", type: .asset, balance: Decimal(20000) / 100, position: 1, in: container)
    let store = AccountStore(
      repository: backend.accounts, conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument)

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

    let store = AccountStore(
      repository: backend.accounts, conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument)

    await store.load()

    #expect(
      store.convertedCurrentTotal
        == InstrumentAmount(
          quantity: Decimal(550000) / 100, instrument: Instrument.defaultTestInstrument))  // 100000 + 500000 - 50000
    #expect(
      store.convertedInvestmentTotal
        == InstrumentAmount(
          quantity: Decimal(2_000_000) / 100, instrument: Instrument.defaultTestInstrument))
    #expect(
      store.convertedNetWorth
        == InstrumentAmount(
          quantity: Decimal(2_550_000) / 100, instrument: Instrument.defaultTestInstrument)
    )
  }

  @Test func testConvertedTotalsHandleMixedInstruments() async throws {
    let aud = Instrument.defaultTestInstrument  // AUD in tests
    let usd = Instrument.fiat(code: "USD")
    let (backend, container) = try TestBackend.create()
    _ = seedAccount(name: "AUD Bank", balance: Decimal(100000) / 100, in: container)
    _ = seedAccount(
      name: "USD Bank", instrument: usd, balance: Decimal(50000) / 100, in: container)
    _ = seedAccount(
      name: "USD Asset", type: .asset, instrument: usd, balance: Decimal(20000) / 100,
      in: container)

    // 1 USD = 2 AUD — simple test rate
    let conversion = FixedConversionService(rates: ["USD": 2])
    let store = AccountStore(
      repository: backend.accounts, conversionService: conversion, targetInstrument: aud)

    await store.load()

    // 1_000.00 AUD + (500.00 USD * 2) + (200.00 USD * 2) = 1_000 + 1_000 + 400 = 2_400.00
    #expect(
      store.convertedCurrentTotal
        == InstrumentAmount(quantity: Decimal(240_000) / 100, instrument: aud))
    #expect(
      store.convertedNetWorth
        == InstrumentAmount(quantity: Decimal(240_000) / 100, instrument: aud))
  }

  // MARK: - Preload investment values on load

  @Test("load populates investmentValues from latest repository value for investment accounts")
  func loadPreloadsLatestInvestmentValues() async throws {
    let acctId = UUID()
    let instrument = Instrument.defaultTestInstrument
    let (backend, container) = try TestBackend.create()
    _ = seedAccount(
      id: acctId, name: "Brokerage", type: .investment, balance: Decimal(100000) / 100,
      in: container)
    let latestDate = Date()
    let olderDate = Calendar.current.date(byAdding: .day, value: -7, to: latestDate)!
    TestBackend.seed(
      investmentValues: [
        acctId: [
          InvestmentValue(
            date: latestDate,
            value: InstrumentAmount(quantity: Decimal(250000) / 100, instrument: instrument)),
          InvestmentValue(
            date: olderDate,
            value: InstrumentAmount(quantity: Decimal(180000) / 100, instrument: instrument)),
        ]
      ],
      in: container,
      instrument: instrument)

    let store = AccountStore(
      repository: backend.accounts,
      conversionService: FixedConversionService(),
      targetInstrument: instrument,
      investmentRepository: backend.investments)

    await store.load()

    #expect(store.investmentValues[acctId]?.quantity == Decimal(250000) / 100)
    #expect(store.convertedBalances[acctId]?.quantity == Decimal(250000) / 100)
  }

  @Test("load leaves investmentValues empty when no values exist")
  func loadOmitsInvestmentValueWhenRepositoryEmpty() async throws {
    let acctId = UUID()
    let (backend, container) = try TestBackend.create()
    _ = seedAccount(
      id: acctId, name: "Brokerage", type: .investment, balance: Decimal(100000) / 100,
      in: container)

    let store = AccountStore(
      repository: backend.accounts,
      conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument,
      investmentRepository: backend.investments)

    await store.load()

    #expect(store.investmentValues[acctId] == nil)
    #expect(store.convertedBalances[acctId]?.quantity == Decimal(100000) / 100)
  }

  // MARK: - updateInvestmentValue

  @Test func testUpdateInvestmentValueSetsValue() async throws {
    let (backend, container) = try TestBackend.create()
    _ = seedAccount(
      name: "Invest", type: .investment, balance: Decimal(100000) / 100, in: container)
    let store = AccountStore(
      repository: backend.accounts, conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument)
    await store.load()

    let newValue = InstrumentAmount(
      quantity: Decimal(150000) / 100, instrument: Instrument.defaultTestInstrument)

    let account = store.accounts.first!
    await store.updateInvestmentValue(accountId: account.id, value: newValue)
    #expect(store.investmentValues[account.id] == newValue)
    let balance = try await store.displayBalance(for: account.id)
    #expect(balance == newValue)
  }

  @Test func testUpdateInvestmentValueClearsValue() async throws {
    let (backend, container) = try TestBackend.create()
    _ = seedAccount(
      name: "Invest", type: .investment, balance: Decimal(100000) / 100, in: container)
    let store = AccountStore(
      repository: backend.accounts, conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument)
    await store.load()

    let account = store.accounts.first!
    let investmentValue = InstrumentAmount(
      quantity: Decimal(200000) / 100, instrument: Instrument.defaultTestInstrument)
    await store.updateInvestmentValue(accountId: account.id, value: investmentValue)
    await store.updateInvestmentValue(accountId: account.id, value: nil)

    #expect(store.investmentValues[account.id] == nil)
    // displayBalance sums positions (converted to account's instrument) when investmentValue is nil
    let balance = try await store.displayBalance(for: account.id)
    #expect(
      balance
        == InstrumentAmount(
          quantity: Decimal(100000) / 100, instrument: Instrument.defaultTestInstrument))
  }

  @Test func testUpdateInvestmentValueIgnoresUnknownAccount() async throws {
    let (backend, container) = try TestBackend.create()
    _ = seedAccount(
      name: "Invest", type: .investment, balance: Decimal(100000) / 100, in: container)
    let store = AccountStore(
      repository: backend.accounts, conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument)
    await store.load()

    let newValue = InstrumentAmount(
      quantity: Decimal(150000) / 100, instrument: Instrument.defaultTestInstrument)
    await store.updateInvestmentValue(accountId: UUID(), value: newValue)

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
    let store = AccountStore(
      repository: backend.accounts, conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument)

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
    let store = AccountStore(
      repository: backend.accounts, conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument)

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
    let store = AccountStore(
      repository: backend.accounts, conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument)

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
    let store = AccountStore(
      repository: backend.accounts, conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument)
    await store.load()

    let deltas: PositionDeltas = [acctId: [instrument: Decimal(-5000) / 100]]
    await store.applyDelta(deltas)

    let balance = try await store.displayBalance(for: acctId)
    #expect(balance.quantity == Decimal(95000) / 100)
  }

  @Test func testApplyDeltaIncreasesAccountBalance() async throws {
    let acctId = UUID()
    let instrument = Instrument.defaultTestInstrument
    let (backend, container) = try TestBackend.create()
    _ = seedAccount(
      id: acctId, name: "Checking", balance: Decimal(100000) / 100, in: container)
    let store = AccountStore(
      repository: backend.accounts, conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument)
    await store.load()

    let deltas: PositionDeltas = [acctId: [instrument: Decimal(50000) / 100]]
    await store.applyDelta(deltas)

    let balance = try await store.displayBalance(for: acctId)
    #expect(balance.quantity == Decimal(150000) / 100)
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
    let store = AccountStore(
      repository: backend.accounts, conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument)
    await store.load()

    let deltas: PositionDeltas = [
      checkingId: [instrument: Decimal(-10000) / 100],
      savingsId: [instrument: Decimal(10000) / 100],
    ]
    await store.applyDelta(deltas)

    let checking = try await store.displayBalance(for: checkingId)
    let savings = try await store.displayBalance(for: savingsId)
    #expect(checking.quantity == Decimal(90000) / 100)
    #expect(savings.quantity == Decimal(210000) / 100)
  }

  @Test func testApplyDeltaUpdatesTotals() async throws {
    let checkingId = UUID()
    let instrument = Instrument.defaultTestInstrument
    let (backend, container) = try TestBackend.create()
    _ = seedAccount(
      id: checkingId, name: "Checking", balance: Decimal(100000) / 100, in: container)
    let store = AccountStore(
      repository: backend.accounts, conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument)
    await store.load()

    #expect(store.convertedCurrentTotal?.quantity == Decimal(100000) / 100)

    let deltas: PositionDeltas = [checkingId: [instrument: Decimal(-5000) / 100]]
    await store.applyDelta(deltas)

    #expect(store.convertedCurrentTotal?.quantity == Decimal(95000) / 100)
    #expect(store.convertedNetWorth?.quantity == Decimal(95000) / 100)
  }

  @Test func testApplyDeltaViaBalanceDeltaCalculator() async throws {
    let acctId = UUID()
    let instrument = Instrument.defaultTestInstrument
    let (backend, container) = try TestBackend.create()
    _ = seedAccount(
      id: acctId, name: "Checking", balance: Decimal(100000) / 100, in: container)
    let store = AccountStore(
      repository: backend.accounts, conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument)
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
    await store.applyDelta(delta.accountDeltas)

    let balance = try await store.displayBalance(for: acctId)
    #expect(balance.quantity == Decimal(95000) / 100)
  }

  @Test func testApplyDeltaIgnoresUnknownAccount() async throws {
    let acctId = UUID()
    let unknownId = UUID()
    let instrument = Instrument.defaultTestInstrument
    let (backend, container) = try TestBackend.create()
    _ = seedAccount(
      id: acctId, name: "Checking", balance: Decimal(100000) / 100, in: container)
    let store = AccountStore(
      repository: backend.accounts, conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument)
    await store.load()

    let deltas: PositionDeltas = [unknownId: [instrument: Decimal(-5000) / 100]]
    await store.applyDelta(deltas)

    // Balance should be unchanged
    let balance = try await store.displayBalance(for: acctId)
    #expect(balance.quantity == Decimal(100000) / 100)
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

    #expect(store.convertedCurrentTotal?.quantity == Decimal(100000) / 100)

    let deltas: PositionDeltas = [acctId: [instrument: Decimal(-5000) / 100]]
    await store.applyDelta(deltas)

    #expect(store.convertedCurrentTotal?.quantity == Decimal(95000) / 100)
    #expect(store.convertedNetWorth?.quantity == Decimal(95000) / 100)
  }

  // MARK: - Display Balance

  @Test func testDisplayBalanceReturnsInvestmentValueForInvestmentAccount() async throws {
    let acctId = UUID()
    let (backend, container) = try TestBackend.create()
    _ = seedAccount(
      id: acctId, name: "Invest", type: .investment, balance: Decimal(100000) / 100,
      in: container)
    let store = AccountStore(
      repository: backend.accounts, conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument)
    await store.load()

    let investmentValue = InstrumentAmount(
      quantity: Decimal(150000) / 100, instrument: Instrument.defaultTestInstrument)
    await store.updateInvestmentValue(accountId: acctId, value: investmentValue)

    let balance = try await store.displayBalance(for: acctId)
    #expect(balance == investmentValue)
  }

  @Test func testCanDeleteReturnsTrueForZeroPositions() async throws {
    let acctId = UUID()
    let (backend, container) = try TestBackend.create()
    _ = seedAccount(id: acctId, name: "Empty", in: container)
    let store = AccountStore(
      repository: backend.accounts, conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument)
    await store.load()

    #expect(store.canDelete(acctId))
  }

  @Test func testCanDeleteReturnsFalseForNonZeroPositions() async throws {
    let acctId = UUID()
    let (backend, container) = try TestBackend.create()
    _ = seedAccount(
      id: acctId, name: "Active", balance: Decimal(100000) / 100, in: container)
    let store = AccountStore(
      repository: backend.accounts, conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument)
    await store.load()

    #expect(!store.canDelete(acctId))
  }

  // MARK: - Instrument Persistence

  @Test func testCreatePersistsInstrument() async throws {
    let (backend, _) = try TestBackend.create()
    let store = AccountStore(
      repository: backend.accounts, conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument)
    let usdInstrument = Instrument.fiat(code: "USD")
    let account = Account(
      id: UUID(), name: "USD Checking", type: .bank, instrument: usdInstrument, position: 0,
      isHidden: false)

    let created = try await store.create(account)

    #expect(created.instrument.id == usdInstrument.id)
    #expect(store.accounts.first?.instrument.id == usdInstrument.id)

    let fetched = try await backend.accounts.fetchAll()
    #expect(fetched.first?.instrument.id == usdInstrument.id)
  }

  /// Regression: creating an empty investment account (no positions, no
  /// external investment value) must populate `convertedBalances` with a zero
  /// amount in the account's instrument. Without this, the sidebar row spins
  /// forever because `AccountSidebarRow` reads `convertedBalances[id]` and
  /// `SidebarRowView` renders a `ProgressView` whenever that entry is `nil`.
  @Test func testCreateEmptyInvestmentAccountPopulatesConvertedBalance() async throws {
    let (backend, _) = try TestBackend.create()
    let store = AccountStore(
      repository: backend.accounts, conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument)
    let account = Account(
      id: UUID(), name: "Brokerage", type: .investment,
      instrument: .defaultTestInstrument, position: 0, isHidden: false)

    let created = try await store.create(account)

    let balance = store.convertedBalances[created.id]
    #expect(balance != nil)
    #expect(balance?.quantity == 0)
    #expect(balance?.instrument.id == Instrument.defaultTestInstrument.id)
  }

  @Test func testUpdatePersistsChangedInstrument() async throws {
    let (backend, container) = try TestBackend.create()
    let original = seedAccount(name: "Savings", in: container)
    let store = AccountStore(
      repository: backend.accounts, conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument)

    let eurInstrument = Instrument.fiat(code: "EUR")
    var modified = original
    modified.instrument = eurInstrument

    let updated = try await store.update(modified)

    #expect(updated.instrument.id == eurInstrument.id)

    let fetched = try await backend.accounts.fetchAll()
    #expect(fetched.first?.instrument.id == eurInstrument.id)
  }

  // MARK: - reorderAccounts

  @Test func testReorderAccountsPersistsNewPositions() async throws {
    let idA = UUID()
    let idB = UUID()
    let idC = UUID()
    let (backend, container) = try TestBackend.create()
    let a = seedAccount(id: idA, name: "A", position: 0, in: container)
    let b = seedAccount(id: idB, name: "B", position: 1, in: container)
    let c = seedAccount(id: idC, name: "C", position: 2, in: container)
    let store = AccountStore(
      repository: backend.accounts, conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument)
    await store.load()

    // Reverse order: C, B, A
    await store.reorderAccounts([c, b, a])

    #expect(store.error == nil)
    #expect(store.accounts.ordered.map(\.name) == ["C", "B", "A"])

    let persisted = try await backend.accounts.fetchAll().sorted { $0.position < $1.position }
    #expect(persisted.map(\.name) == ["C", "B", "A"])
  }

  @Test func testReorderAccountsSurfacesErrorOnFailure() async throws {
    let idA = UUID()
    let idB = UUID()
    let repository = FailingAccountRepository(
      accounts: [
        Account(
          id: idA, name: "A", type: .bank, instrument: .defaultTestInstrument, position: 0,
          isHidden: false),
        Account(
          id: idB, name: "B", type: .bank, instrument: .defaultTestInstrument, position: 1,
          isHidden: false),
      ])
    let store = AccountStore(
      repository: repository, conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument)
    await store.load()
    #expect(store.accounts.ordered.map(\.name) == ["A", "B"])

    // Start failing further repository calls (update + fetchAll during reload).
    repository.shouldFail = true
    let accounts = store.accounts.ordered
    await store.reorderAccounts([accounts[1], accounts[0]])

    // Error must be surfaced, not silently swallowed.
    #expect(store.error != nil)
    // State rolls back to the pre-reorder ordering when persistence fails.
    #expect(store.accounts.ordered.map(\.name) == ["A", "B"])
  }

  @Test func testReorderAccountsRollsBackLocalStateOnFailure() async throws {
    let idA = UUID()
    let idB = UUID()
    let original = [
      Account(
        id: idA, name: "A", type: .bank, instrument: .defaultTestInstrument, position: 0,
        isHidden: false),
      Account(
        id: idB, name: "B", type: .bank, instrument: .defaultTestInstrument, position: 1,
        isHidden: false),
    ]
    let repository = FailingAccountRepository(accounts: original)
    let store = AccountStore(
      repository: repository, conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument)
    await store.load()

    // Make update() fail but allow fetchAll() to succeed so the post-failure
    // reload restores the original server-side order.
    repository.failOnUpdate = true
    let accounts = store.accounts.ordered
    await store.reorderAccounts([accounts[1], accounts[0]])

    #expect(store.error != nil)
    // After rollback + reload, the authoritative ordering is preserved.
    #expect(store.accounts.ordered.map(\.name) == ["A", "B"])
    #expect(store.accounts.ordered.map(\.position) == [0, 1])
  }
}

// MARK: - Test helpers

/// In-memory AccountRepository whose methods can be toggled to fail, letting
/// tests exercise error-handling paths without spinning up CloudKit.
private final class FailingAccountRepository: AccountRepository, @unchecked Sendable {
  private var accounts: [Account]
  var shouldFail = false
  var failOnUpdate = false

  init(accounts: [Account]) {
    self.accounts = accounts
  }

  func fetchAll() async throws -> [Account] {
    if shouldFail { throw BackendError.networkUnavailable }
    return accounts
  }

  func create(_ account: Account, openingBalance: InstrumentAmount?) async throws -> Account {
    if shouldFail { throw BackendError.networkUnavailable }
    accounts.append(account)
    return account
  }

  func update(_ account: Account) async throws -> Account {
    if shouldFail || failOnUpdate { throw BackendError.networkUnavailable }
    if let idx = accounts.firstIndex(where: { $0.id == account.id }) {
      accounts[idx] = account
    }
    return account
  }

  func delete(id: UUID) async throws {
    if shouldFail { throw BackendError.networkUnavailable }
    accounts.removeAll { $0.id == id }
  }
}
