import Foundation
import Testing

@testable import Moolah

@Suite("AccountBalanceCalculator + ValuationMode")
struct BalanceCalculatorValuationModeTests {
  @Test("recordedValue + snapshot → balance = snapshot")
  @MainActor
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
  @MainActor
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
  @MainActor
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
  @MainActor
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
}
