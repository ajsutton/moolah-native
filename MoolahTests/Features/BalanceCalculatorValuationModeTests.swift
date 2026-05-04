import Foundation
import Testing

@testable import Moolah

@Suite("AccountBalanceCalculator + ValuationMode")
@MainActor
struct BalanceCalculatorValuationModeTests {
  @Test("recordedValue + snapshot → balance = snapshot")
  func recordedWithSnapshot() async throws {
    let calculator = AccountBalanceCalculator(
      conversionService: FixedConversionService(), targetInstrument: .AUD)
    let account = Account(
      name: "B", type: .investment, instrument: .AUD,
      valuationMode: .recordedValue)
    let snapshot = InstrumentAmount(quantity: 1234, instrument: .AUD)
    let balance = try await calculator.displayBalance(
      for: account, investmentValue: snapshot)
    #expect(balance == snapshot)
  }

  @Test("recordedValue + missing snapshot → balance = zero (NOT positions sum)")
  func recordedWithoutSnapshotIsZero() async throws {
    let calculator = AccountBalanceCalculator(
      conversionService: FixedConversionService(), targetInstrument: .AUD)
    var account = Account(
      name: "B", type: .investment, instrument: .AUD,
      valuationMode: .recordedValue)
    account.positions = [Position(instrument: .AUD, quantity: 999)]
    let balance = try await calculator.displayBalance(
      for: account, investmentValue: nil)
    #expect(balance == .zero(instrument: .AUD))
  }

  @Test("calculatedFromTrades → positions sum (snapshot ignored)")
  func calculatedSumsPositionsIgnoringSnapshot() async throws {
    let calculator = AccountBalanceCalculator(
      conversionService: FixedConversionService(), targetInstrument: .AUD)
    var account = Account(
      name: "B", type: .investment, instrument: .AUD,
      valuationMode: .calculatedFromTrades)
    account.positions = [Position(instrument: .AUD, quantity: 500)]
    let snapshot = InstrumentAmount(quantity: 9999, instrument: .AUD)
    let balance = try await calculator.displayBalance(
      for: account, investmentValue: snapshot)
    #expect(balance == InstrumentAmount(quantity: 500, instrument: .AUD))
  }

  @Test("non-investment account ignores valuationMode")
  func nonInvestmentIgnoresMode() async throws {
    let calculator = AccountBalanceCalculator(
      conversionService: FixedConversionService(), targetInstrument: .AUD)
    var account = Account(
      name: "Checking", type: .bank, instrument: .AUD,
      valuationMode: .recordedValue)
    account.positions = [Position(instrument: .AUD, quantity: 42)]
    let snapshot = InstrumentAmount(quantity: 9999, instrument: .AUD)
    let balance = try await calculator.displayBalance(
      for: account, investmentValue: snapshot)
    #expect(balance == InstrumentAmount(quantity: 42, instrument: .AUD))
  }

  @Test("totalConverted: recordedValue investment uses cache value")
  func totalConvertedRecordedMode() async throws {
    let calculator = AccountBalanceCalculator(
      conversionService: FixedConversionService(), targetInstrument: .AUD)
    var withSnapshot = Account(
      name: "A", type: .investment, instrument: .AUD,
      valuationMode: .recordedValue)
    withSnapshot.positions = [Position(instrument: .AUD, quantity: 999)]
    var withoutSnapshot = Account(
      name: "B", type: .investment, instrument: .AUD,
      valuationMode: .recordedValue)
    withoutSnapshot.positions = [Position(instrument: .AUD, quantity: 999)]

    let cache = InvestmentValueCache(repository: nil)
    cache.set(InstrumentAmount(quantity: 100, instrument: .AUD), for: withSnapshot.id)
    // withoutSnapshot has no cache entry.

    let total = try await calculator.totalConverted(
      for: [withSnapshot, withoutSnapshot], to: .AUD, using: cache)
    #expect(total == InstrumentAmount(quantity: 100, instrument: .AUD))
  }

  @Test("totalConverted: calculatedFromTrades sums positions, ignores cache")
  func totalConvertedTradesMode() async throws {
    let calculator = AccountBalanceCalculator(
      conversionService: FixedConversionService(), targetInstrument: .AUD)
    var account = Account(
      name: "A", type: .investment, instrument: .AUD,
      valuationMode: .calculatedFromTrades)
    account.positions = [Position(instrument: .AUD, quantity: 500)]
    let cache = InvestmentValueCache(repository: nil)
    cache.set(InstrumentAmount(quantity: 99, instrument: .AUD), for: account.id)
    let total = try await calculator.totalConverted(
      for: [account], to: .AUD, using: cache)
    #expect(total == InstrumentAmount(quantity: 500, instrument: .AUD))
  }
}
