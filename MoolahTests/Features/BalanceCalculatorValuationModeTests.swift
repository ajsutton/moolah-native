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

  // MARK: - .knownZero positions (issue #790)

  /// Issue #790: positions whose conversion resolves to `.knownZero`
  /// (an `.unpriced` / `.spam` crypto registration) contribute zero to
  /// `displayBalance`, mixed with other priced positions. The balance
  /// is computed (not throwing) so the user sees the priced portion.
  @Test("displayBalance: .knownZero positions contribute zero alongside priced positions")
  func displayBalance_knownZeroPositionsFoldToZero() async throws {
    let spam = Instrument.crypto(
      chainId: 10,
      contractAddress: "0x7e087b1c173441f6c96b00231c1eab9e59f9a5a7",
      symbol: "OP",
      name: "Spam OP",
      decimals: 18)
    let calculator = AccountBalanceCalculator(
      conversionService: FixedConversionService(
        rates: ["USD": Decimal(15) / Decimal(10)],
        knownZeroInstrumentIds: [spam.id]),
      targetInstrument: .AUD)
    var account = Account(
      name: "Wallet", type: .crypto, instrument: .AUD,
      valuationMode: .calculatedFromTrades)
    account.positions = [
      Position(instrument: .AUD, quantity: 100),
      Position(instrument: .USD, quantity: 200),  // → 300 AUD via rate 1.5
      Position(instrument: spam, quantity: 1_000_000),  // → 0
    ]

    let balance = try await calculator.displayBalance(
      for: account, investmentValue: nil)
    #expect(balance == InstrumentAmount(quantity: 400, instrument: .AUD))
  }

  /// Issue #790: a transient conversion failure (real provider outage)
  /// must still throw — `.knownZero` is not a fallback for failed
  /// conversions, only for intentionally-unpriced sources.
  @Test("displayBalance: transient rate failure still throws")
  func displayBalance_transientFailureStillThrows() async {
    let usd = Instrument.USD
    let conversion = FailingConversionService(failingInstrumentIds: [usd.id])
    let calculator = AccountBalanceCalculator(
      conversionService: conversion, targetInstrument: .AUD)
    var account = Account(
      name: "Bank", type: .bank, instrument: .AUD)
    account.positions = [
      Position(instrument: .AUD, quantity: 100),
      Position(instrument: usd, quantity: 50),
    ]

    await #expect(throws: (any Error).self) {
      _ = try await calculator.displayBalance(
        for: account, investmentValue: nil)
    }
  }

  /// Issue #790: `totalConverted` direct path (used by the sidebar's
  /// per-account-positions aggregation) also folds `.knownZero` to zero.
  @Test("totalConverted: .knownZero positions contribute zero")
  func totalConverted_knownZeroFoldsToZero() async throws {
    let spam = Instrument.crypto(
      chainId: 10,
      contractAddress: "0x7e087b1c173441f6c96b00231c1eab9e59f9a5a7",
      symbol: "OP",
      name: "Spam OP",
      decimals: 18)
    let calculator = AccountBalanceCalculator(
      conversionService: FixedConversionService(
        knownZeroInstrumentIds: [spam.id]),
      targetInstrument: .AUD)
    var account = Account(
      name: "Wallet", type: .crypto, instrument: .AUD,
      valuationMode: .calculatedFromTrades)
    account.positions = [
      Position(instrument: .AUD, quantity: 50),
      Position(instrument: spam, quantity: 1_000_000),
    ]
    let total = try await calculator.totalConverted(
      for: [account], to: .AUD)
    #expect(total == InstrumentAmount(quantity: 50, instrument: .AUD))
  }
}
