import Foundation
import Testing

@testable import Moolah

@Suite("CapitalGainsCalculator — Part 2")
struct CapitalGainsCalculatorTestsMore {
  let aud = Instrument.fiat(code: "AUD")

  private func stockInstrument(_ name: String) -> Instrument {
    Instrument.stock(ticker: "\(name).AX", exchange: "ASX", name: name)
  }

  private func cryptoInstrument(_ symbol: String) -> Instrument {
    Instrument(
      id: "1:\(symbol.lowercased())", kind: .cryptoToken, name: symbol, decimals: 8,
      ticker: nil, exchange: nil, chainId: 1, contractAddress: nil)
  }

  private func date(_ daysFromBase: Int) -> Date {
    let base = Calendar(identifier: .gregorian).date(
      from: DateComponents(year: 2024, month: 1, day: 1))!
    return Calendar(identifier: .gregorian).date(byAdding: .day, value: daysFromBase, to: base)!
  }

  @Test
  func sellingOneInstrumentDoesNotTouchCostBasisOfAnother() async throws {
    // If a user sells BHP, CBA cost basis must not change.
    let bhp = stockInstrument("BHP")
    let cba = stockInstrument("CBA")
    let accountId = UUID()

    let buyBHP = LegTransaction(
      date: date(0),
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: aud, quantity: -4000, type: .trade,
          categoryId: nil, earmarkId: nil),
        TransactionLeg(
          accountId: accountId, instrument: bhp, quantity: 100, type: .trade,
          categoryId: nil, earmarkId: nil),
      ])
    let buyCBA = LegTransaction(
      date: date(50),
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: aud, quantity: -5000, type: .trade,
          categoryId: nil, earmarkId: nil),
        TransactionLeg(
          accountId: accountId, instrument: cba, quantity: 50, type: .trade,
          categoryId: nil, earmarkId: nil),
      ])
    let sellAllBHP = LegTransaction(
      date: date(400),
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: bhp, quantity: -100, type: .trade,
          categoryId: nil, earmarkId: nil),
        TransactionLeg(
          accountId: accountId, instrument: aud, quantity: 5000, type: .trade,
          categoryId: nil, earmarkId: nil),
      ])

    let result = try await CapitalGainsCalculator.computeWithConversion(
      transactions: [buyBHP, buyCBA, sellAllBHP],
      profileCurrency: aud,
      conversionService: FixedConversionService(rates: [:])
    )

    // Only BHP sale produces an event; CBA is still held.
    #expect(result.events.count == 1)
    #expect(result.events[0].instrument.id == "ASX:BHP.AX")
    #expect(result.events[0].gain == 1000)
  }

  /// Cross-currency buy with a fee in the profile currency: 100 BHP paid
  /// for with USD 2000 plus an AUD 100 brokerage fee. Profile currency =
  /// AUD at 1 USD = 1.5 AUD. The two `.trade` legs price the position
  /// (USD outflow → BHP) and the AUD fee leg is `.expense` so it does
  /// **not** participate in cost basis under the current design.
  ///
  /// Cost basis is therefore the converted USD outflow only (AUD 3000),
  /// proceeds AUD 4000, gain AUD 1000. Folding the fee into cost basis
  /// is tracked in https://github.com/ajsutton/moolah-native/issues/558.
  @Test
  func crossCurrencyBuyWithFeeExcludesFeeFromCostBasis() async throws {
    let bhp = stockInstrument("BHP")
    let usd = Instrument.fiat(code: "USD")
    let accountId = UUID()

    let buyTx = LegTransaction(
      date: date(0),
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: usd, quantity: -2000, type: .trade,
          categoryId: nil, earmarkId: nil),
        TransactionLeg(
          accountId: accountId, instrument: bhp, quantity: 100, type: .trade,
          categoryId: nil, earmarkId: nil),
        TransactionLeg(
          accountId: accountId, instrument: aud, quantity: -100, type: .expense,
          categoryId: nil, earmarkId: nil),
      ])

    let sellTx = LegTransaction(
      date: date(400),
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: bhp, quantity: -100, type: .trade,
          categoryId: nil, earmarkId: nil),
        TransactionLeg(
          accountId: accountId, instrument: aud, quantity: 4000, type: .trade,
          categoryId: nil, earmarkId: nil),
      ])

    let service = FixedConversionService(rates: ["USD": dec("1.5")])
    let result = try await CapitalGainsCalculator.computeWithConversion(
      transactions: [buyTx, sellTx],
      profileCurrency: aud,
      conversionService: service
    )

    // Cost basis AUD 3000 (USD 2000 × 1.5; fee leg ignored),
    // proceeds AUD 4000. Gain 1000.
    #expect(result.events.count == 1)
    #expect(result.events[0].gain == 1000)
  }

  /// Mixed-fiat sell: 100 BHP sold for USD 3000 with AUD 50 fee,
  /// profile currency = AUD at 1 USD = 1.5 AUD. Proceeds must aggregate
  /// to AUD 4500 − AUD 50 direction depends on the fee side; here the
  /// fee is modelled as an inflow because the existing fiat-paired
  /// classifier only sums absolute inflow. Covers the sell-side symmetry
  /// of the fix.
  @Test
  func mixedFiatLegs_sellSide_convertInflowToProfileCurrency() async throws {
    let bhp = stockInstrument("BHP")
    let usd = Instrument.fiat(code: "USD")
    let accountId = UUID()

    let buyTx = LegTransaction(
      date: date(0),
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: aud, quantity: -3000, type: .trade,
          categoryId: nil, earmarkId: nil),
        TransactionLeg(
          accountId: accountId, instrument: bhp, quantity: 100, type: .trade,
          categoryId: nil, earmarkId: nil),
      ])

    // Sell 100 BHP, receive USD 3000. Expected proceeds: AUD 4500.
    let sellTx = LegTransaction(
      date: date(400),
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: bhp, quantity: -100, type: .trade,
          categoryId: nil, earmarkId: nil),
        TransactionLeg(
          accountId: accountId, instrument: usd, quantity: 3000, type: .trade,
          categoryId: nil, earmarkId: nil),
      ])

    let service = FixedConversionService(rates: ["USD": dec("1.5")])
    let result = try await CapitalGainsCalculator.computeWithConversion(
      transactions: [buyTx, sellTx],
      profileCurrency: aud,
      conversionService: service
    )

    // Cost basis AUD 3000, proceeds AUD 4500. Gain 1500.
    #expect(result.events.count == 1)
    #expect(result.events[0].gain == 1500)
  }

  // MARK: - Date-sensitive routing
  //
  // `computeWithConversion` must convert every fiat or non-fiat-swap leg
  // on the transaction's date (Rule 5). The rate-ignoring
  // `FixedConversionService` would not detect a regression that swapped
  // `tx.date` for `Date()` or another date; this test uses
  // `DateBasedFixedConversionService` to make that observable.

  /// Crypto-to-crypto swap: both legs are valued via the conversion
  /// service. The rate schedule below has a different rate effective at
  /// the swap date than would be returned for "today" (`Date()`), so a
  /// regression that misrouted the lookup date would yield a different
  /// gain than the assertion permits.
}
