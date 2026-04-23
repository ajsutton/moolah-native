import Foundation
import SwiftData
import Testing

@testable import Moolah

@Suite("AccountStore/ApplyDelta")
@MainActor
struct AccountStoreApplyDeltaTests {

  // MARK: - applyDelta

  @Test
  func testApplyDeltaReducesAccountBalance() async throws {
    let acctId = UUID()
    let instrument = Instrument.defaultTestInstrument
    let (backend, container) = try TestBackend.create()
    _ = AccountStoreTestSupport.seedAccount(
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

  @Test
  func testApplyDeltaIncreasesAccountBalance() async throws {
    let acctId = UUID()
    let instrument = Instrument.defaultTestInstrument
    let (backend, container) = try TestBackend.create()
    _ = AccountStoreTestSupport.seedAccount(
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

  @Test
  func testApplyDeltaUpdatesBothAccounts() async throws {
    let checkingId = UUID()
    let savingsId = UUID()
    let instrument = Instrument.defaultTestInstrument
    let (backend, container) = try TestBackend.create()
    _ = AccountStoreTestSupport.seedAccount(
      id: checkingId, name: "Checking", balance: Decimal(100000) / 100, in: container)
    _ = AccountStoreTestSupport.seedAccount(
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

  @Test
  func testApplyDeltaUpdatesTotals() async throws {
    let checkingId = UUID()
    let instrument = Instrument.defaultTestInstrument
    let (backend, container) = try TestBackend.create()
    _ = AccountStoreTestSupport.seedAccount(
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

  @Test
  func testApplyDeltaViaBalanceDeltaCalculator() async throws {
    let acctId = UUID()
    let instrument = Instrument.defaultTestInstrument
    let (backend, container) = try TestBackend.create()
    _ = AccountStoreTestSupport.seedAccount(
      id: acctId, name: "Checking", balance: Decimal(100000) / 100, in: container)
    let store = AccountStore(
      repository: backend.accounts, conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument)
    await store.load()

    let transaction = Transaction(
      date: Date(),
      payee: "Coffee",
      legs: [
        TransactionLeg(
          accountId: acctId, instrument: instrument,
          quantity: Decimal(-5000) / 100, type: .expense)
      ]
    )
    let delta = BalanceDeltaCalculator.deltas(old: nil, new: transaction)
    await store.applyDelta(delta.accountDeltas)

    let balance = try await store.displayBalance(for: acctId)
    #expect(balance.quantity == Decimal(95000) / 100)
  }

  @Test
  func testApplyDeltaIgnoresUnknownAccount() async throws {
    let acctId = UUID()
    let unknownId = UUID()
    let instrument = Instrument.defaultTestInstrument
    let (backend, container) = try TestBackend.create()
    _ = AccountStoreTestSupport.seedAccount(
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

  @Test
  func testConvertedTotalsAreNilBeforeLoad() async throws {
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

  @Test
  func testConvertedTotalsPopulatedAfterLoad() async throws {
    let instrument = Instrument.defaultTestInstrument
    let (backend, container) = try TestBackend.create()
    _ = AccountStoreTestSupport.seedAccount(
      name: "Checking", balance: Decimal(100000) / 100, in: container)
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

  @Test
  func testConvertedTotalsUpdateAfterApplyDelta() async throws {
    let acctId = UUID()
    let instrument = Instrument.defaultTestInstrument
    let (backend, container) = try TestBackend.create()
    _ = AccountStoreTestSupport.seedAccount(
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
}
