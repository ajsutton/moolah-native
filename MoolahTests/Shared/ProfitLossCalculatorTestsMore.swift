import Foundation
import Testing

@testable import Moolah

@Suite("ProfitLossCalculator — Part 2")
struct ProfitLossCalculatorTestsMore {
  let aud = Instrument.fiat(code: "AUD")

  @Test
  func multipleStocks_eachGetsOwnRow() async throws {
    let bhp = stockInstrument("BHP")
    let cba = stockInstrument("CBA")
    let accountId = UUID()

    let buyBHP = LegTransaction(
      date: date(0),
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: aud, quantity: -4000, type: .transfer,
          categoryId: nil, earmarkId: nil),
        TransactionLeg(
          accountId: accountId, instrument: bhp, quantity: 100, type: .transfer,
          categoryId: nil, earmarkId: nil),
      ])
    let buyCBA = LegTransaction(
      date: date(0),
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: aud, quantity: -5000, type: .transfer,
          categoryId: nil, earmarkId: nil),
        TransactionLeg(
          accountId: accountId, instrument: cba, quantity: 50, type: .transfer,
          categoryId: nil, earmarkId: nil),
      ])

    // BHP $50/share (100 * 50 = 5000). CBA $120/share (50 * 120 = 6000).
    let service = FixedConversionService(rates: ["ASX:BHP": 50, "ASX:CBA": 120])
    let results = try await ProfitLossCalculator.compute(
      transactions: [buyBHP, buyCBA],
      profileCurrency: aud,
      conversionService: service,
      asOfDate: date(365)
    )

    #expect(results.count == 2)
    let bhpPL = results.first { $0.instrument.id == "ASX:BHP" }
    let cbaPL = results.first { $0.instrument.id == "ASX:CBA" }
    #expect(bhpPL?.unrealizedGain == 1000)
    #expect(cbaPL?.unrealizedGain == 1000)
  }

  @Test
  func portfolioMixesStockAndCrypto() async throws {
    let bhp = stockInstrument("BHP")
    let eth = Instrument.crypto(
      chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18
    )
    let accountId = UUID()

    let buyBHP = LegTransaction(
      date: date(0),
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: aud, quantity: -4000, type: .transfer,
          categoryId: nil, earmarkId: nil),
        TransactionLeg(
          accountId: accountId, instrument: bhp, quantity: 100, type: .transfer,
          categoryId: nil, earmarkId: nil),
      ])
    let buyETH = LegTransaction(
      date: date(0),
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: aud, quantity: -2000, type: .transfer,
          categoryId: nil, earmarkId: nil),
        TransactionLeg(
          accountId: accountId, instrument: eth,
          quantity: Decimal(string: "1.0")!, type: .transfer,
          categoryId: nil, earmarkId: nil),
      ])

    let service = FixedConversionService(rates: ["ASX:BHP": 50, eth.id: 2500])
    let results = try await ProfitLossCalculator.compute(
      transactions: [buyBHP, buyETH],
      profileCurrency: aud,
      conversionService: service,
      asOfDate: date(365)
    )

    #expect(results.count == 2)
    let kinds = Set(results.map { $0.instrument.kind })
    #expect(kinds == [.stock, .cryptoToken])
    // Each row is independent; gains aggregate separately.
    let bhpPL = results.first { $0.instrument.kind == .stock }
    let ethPL = results.first { $0.instrument.kind == .cryptoToken }
    #expect(bhpPL?.unrealizedGain == 1000)
    #expect(ethPL?.unrealizedGain == 500)
  }

  /// A multi-currency purchase (USD 2000 + AUD 100 fee) must aggregate
  /// into the profile currency before contributing to `totalInvested`.
  /// Without the conversion, USD and AUD quantities would be summed as
  /// raw decimals and produce a meaningless 2100 rather than 3100 AUD.
  @Test
  func mixedFiatLegs_totalInvestedConvertsEachLegToProfileCurrency() async throws {
    let bhp = stockInstrument("BHP")
    let usd = Instrument.fiat(code: "USD")
    let accountId = UUID()

    let buyTx = LegTransaction(
      date: date(0),
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: usd, quantity: -2000, type: .transfer,
          categoryId: nil, earmarkId: nil),
        TransactionLeg(
          accountId: accountId, instrument: aud, quantity: -100, type: .transfer,
          categoryId: nil, earmarkId: nil),
        TransactionLeg(
          accountId: accountId, instrument: bhp, quantity: 100, type: .transfer,
          categoryId: nil, earmarkId: nil),
      ])

    // 1 USD = 1.5 AUD, BHP now worth AUD 50/share.
    let service = FixedConversionService(rates: [
      "USD": Decimal(string: "1.5")!,
      "ASX:BHP": 50,
    ])
    let results = try await ProfitLossCalculator.compute(
      transactions: [buyTx],
      profileCurrency: aud,
      conversionService: service,
      asOfDate: date(365)
    )

    #expect(results.count == 1)
    // totalInvested: USD 2000×1.5 + AUD 100 = AUD 3100.
    // currentValue: 100 × AUD 50 = AUD 5000.
    // unrealizedGain: 5000 − 3100 = 1900.
    #expect(results[0].totalInvested == 3100)
    #expect(results[0].currentValue == 5000)
    #expect(results[0].unrealizedGain == 1900)
  }

  // MARK: - Date-sensitive routing
  //
  // These tests use `DateBasedFixedConversionService` to verify that
  // `compute` routes its two conversion calls to the correct dates:
  // historic cost basis (`transaction.date`, Rule 5) and current valuation
  // (`asOfDate`, Rule 6). The rate-ignoring `FixedConversionService`
  // would pass even if production code swapped the dates.

  /// Cost basis must convert each fiat outflow leg on `transaction.date` while
  /// `currentValue` must convert the open position on `asOfDate`. The
  /// rate schedule below makes both choices observable: swapping the
  /// dates would yield different totals.
  @Test
  func datesRouteCorrectly_costBasisOnTxDate_currentValueOnAsOfDate() async throws {
    let bhp = stockInstrument("BHP")
    let usd = Instrument.fiat(code: "USD")
    let accountId = UUID()

    let buyTx = LegTransaction(
      date: date(0),
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: usd, quantity: -2000, type: .transfer,
          categoryId: nil, earmarkId: nil),
        TransactionLeg(
          accountId: accountId, instrument: bhp, quantity: 100, type: .transfer,
          categoryId: nil, earmarkId: nil),
      ])

    // date(0):   USD→AUD 1.5,  BHP→AUD 30   (cost basis must use these)
    // date(365): USD→AUD 2.0,  BHP→AUD 50   (current valuation must use these)
    //
    // Correct routing: totalInvested = 2000 × 1.5 = 3000; currentValue = 100 × 50 = 5000.
    // If dates were swapped: totalInvested = 2000 × 2.0 = 4000; currentValue = 100 × 30 = 3000.
    let service = DateBasedFixedConversionService(rates: [
      date(0): ["USD": Decimal(string: "1.5")!, "ASX:BHP": 30],
      date(365): ["USD": Decimal(string: "2.0")!, "ASX:BHP": 50],
    ])
    let results = try await ProfitLossCalculator.compute(
      transactions: [buyTx],
      profileCurrency: aud,
      conversionService: service,
      asOfDate: date(365)
    )

    #expect(results.count == 1)
    let result = results[0]
    #expect(result.totalInvested == 3000)
    #expect(result.currentValue == 5000)
    #expect(result.unrealizedGain == 2000)
  }

  // MARK: - Helpers

  private func stockInstrument(_ name: String) -> Instrument {
    Instrument(
      id: "ASX:\(name)", kind: .stock, name: name, decimals: 0,
      ticker: "\(name).AX", exchange: "ASX", chainId: nil, contractAddress: nil)
  }

  private func date(_ daysFromBase: Int) -> Date {
    let base = Calendar(identifier: .gregorian).date(
      from: DateComponents(year: 2024, month: 1, day: 1))!
    return Calendar(identifier: .gregorian).date(byAdding: .day, value: daysFromBase, to: base)!
  }
}
