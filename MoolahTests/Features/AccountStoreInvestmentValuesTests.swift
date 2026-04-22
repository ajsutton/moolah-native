import Foundation
import SwiftData
import Testing

@testable import Moolah

@Suite("AccountStore/InvestmentValues")
@MainActor
struct AccountStoreInvestmentValuesTests {

  // MARK: - Preload investment values on load

  @Test("load populates investmentValues from latest repository value for investment accounts")
  func loadPreloadsLatestInvestmentValues() async throws {
    let acctId = UUID()
    let instrument = Instrument.defaultTestInstrument
    let (backend, container) = try TestBackend.create()
    _ = AccountStoreTestSupport.seedAccount(
      id: acctId, name: "Brokerage", type: .investment, balance: Decimal(100000) / 100,
      in: container)
    let latestDate = Date()
    let olderDate = try #require(Calendar.current.date(byAdding: .day, value: -7, to: latestDate))
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
    _ = AccountStoreTestSupport.seedAccount(
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
    _ = AccountStoreTestSupport.seedAccount(
      name: "Invest", type: .investment, balance: Decimal(100000) / 100, in: container)
    let store = AccountStore(
      repository: backend.accounts, conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument)
    await store.load()

    let newValue = InstrumentAmount(
      quantity: Decimal(150000) / 100, instrument: Instrument.defaultTestInstrument)

    let account = try #require(store.accounts.first)
    await store.updateInvestmentValue(accountId: account.id, value: newValue)
    #expect(store.investmentValues[account.id] == newValue)
    let balance = try await store.displayBalance(for: account.id)
    #expect(balance == newValue)
  }

  @Test func testUpdateInvestmentValueClearsValue() async throws {
    let (backend, container) = try TestBackend.create()
    _ = AccountStoreTestSupport.seedAccount(
      name: "Invest", type: .investment, balance: Decimal(100000) / 100, in: container)
    let store = AccountStore(
      repository: backend.accounts, conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument)
    await store.load()

    let account = try #require(store.accounts.first)
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
    _ = AccountStoreTestSupport.seedAccount(
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

  // MARK: - Display Balance

  @Test func testDisplayBalanceReturnsInvestmentValueForInvestmentAccount() async throws {
    let acctId = UUID()
    let (backend, container) = try TestBackend.create()
    _ = AccountStoreTestSupport.seedAccount(
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
    _ = AccountStoreTestSupport.seedAccount(id: acctId, name: "Empty", in: container)
    let store = AccountStore(
      repository: backend.accounts, conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument)
    await store.load()

    #expect(store.canDelete(acctId))
  }

  @Test func testCanDeleteReturnsFalseForNonZeroPositions() async throws {
    let acctId = UUID()
    let (backend, container) = try TestBackend.create()
    _ = AccountStoreTestSupport.seedAccount(
      id: acctId, name: "Active", balance: Decimal(100000) / 100, in: container)
    let store = AccountStore(
      repository: backend.accounts, conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument)
    await store.load()

    #expect(!store.canDelete(acctId))
  }
}
