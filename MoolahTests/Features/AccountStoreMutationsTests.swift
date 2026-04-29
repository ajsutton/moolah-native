import Foundation
import SwiftData
import Testing

@testable import Moolah

@Suite("AccountStore/Mutations")
@MainActor
struct AccountStoreMutationsTests {

  // MARK: - Show Hidden

  @Test("currentAccounts excludes hidden accounts by default")
  func hiddenAccountsExcluded() async throws {
    let (backend, database) = try TestBackend.create()
    _ = AccountStoreTestSupport.seedAccount(
      name: "Visible", balance: Decimal(100000) / 100, in: database)
    _ = AccountStoreTestSupport.seedAccount(
      name: "Hidden", balance: Decimal(50000) / 100, isHidden: true, in: database)
    let store = AccountStore(
      repository: backend.accounts, conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument)

    await store.load()

    #expect(store.currentAccounts.count == 1)
    #expect(store.currentAccounts[0].name == "Visible")
  }

  @Test("currentAccounts includes hidden accounts when showHidden is true")
  func hiddenAccountsIncluded() async throws {
    let (backend, database) = try TestBackend.create()
    _ = AccountStoreTestSupport.seedAccount(
      name: "Visible", balance: Decimal(100000) / 100, in: database)
    _ = AccountStoreTestSupport.seedAccount(
      name: "Hidden", balance: Decimal(50000) / 100, isHidden: true, in: database)
    let store = AccountStore(
      repository: backend.accounts, conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument)

    await store.load()
    store.showHidden = true

    #expect(store.currentAccounts.count == 2)
  }

  @Test("investmentAccounts respects showHidden flag")
  func hiddenInvestmentAccounts() async throws {
    let (backend, database) = try TestBackend.create()
    _ = AccountStoreTestSupport.seedAccount(
      name: "Visible", type: .investment, balance: Decimal(100000) / 100, in: database)
    _ = AccountStoreTestSupport.seedAccount(
      name: "Hidden", type: .investment, balance: Decimal(50000) / 100, isHidden: true,
      in: database)
    let store = AccountStore(
      repository: backend.accounts, conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument)

    await store.load()

    #expect(store.investmentAccounts.count == 1)
    store.showHidden = true
    #expect(store.investmentAccounts.count == 2)
  }

  // MARK: - Instrument Persistence

  @Test
  func testCreatePersistsInstrument() async throws {
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
  @Test
  func testCreateEmptyInvestmentAccountPopulatesConvertedBalance() async throws {
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

  @Test
  func testUpdatePersistsChangedInstrument() async throws {
    let (backend, database) = try TestBackend.create()
    let original = AccountStoreTestSupport.seedAccount(name: "Savings", in: database)
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

  @Test
  func testReorderAccountsPersistsNewPositions() async throws {
    let firstId = UUID()
    let secondId = UUID()
    let thirdId = UUID()
    let (backend, database) = try TestBackend.create()
    let first = AccountStoreTestSupport.seedAccount(
      id: firstId, name: "A", position: 0, in: database)
    let second = AccountStoreTestSupport.seedAccount(
      id: secondId, name: "B", position: 1, in: database)
    let third = AccountStoreTestSupport.seedAccount(
      id: thirdId, name: "C", position: 2, in: database)
    let store = AccountStore(
      repository: backend.accounts, conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument)
    await store.load()

    // Reverse order: C, B, A
    await store.reorderAccounts([third, second, first])

    #expect(store.error == nil)
    #expect(store.accounts.ordered.map(\.name) == ["C", "B", "A"])

    let persisted = try await backend.accounts.fetchAll().sorted { $0.position < $1.position }
    #expect(persisted.map(\.name) == ["C", "B", "A"])
  }

  @Test
  func testReorderAccountsSurfacesErrorOnFailure() async throws {
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

  @Test
  func testReorderAccountsRollsBackLocalStateOnFailure() async throws {
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
