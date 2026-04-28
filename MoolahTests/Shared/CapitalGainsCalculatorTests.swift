import Foundation
import Testing

@testable import Moolah

@Suite("CapitalGainsCalculator")
struct CapitalGainsCalculatorTests {
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
  func stockPurchase_thenSale_producesGainEvent() async throws {
    let bhp = stockInstrument("BHP")
    let accountId = UUID()

    // Buy: transfer AUD out, BHP in
    let buyTx = LegTransaction(
      date: date(0),
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: aud, quantity: -4000, type: .trade,
          categoryId: nil, earmarkId: nil),
        TransactionLeg(
          accountId: accountId, instrument: bhp, quantity: 100, type: .trade,
          categoryId: nil, earmarkId: nil),
      ])

    // Sell: BHP out, AUD in
    let sellTx = LegTransaction(
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
      transactions: [buyTx, sellTx],
      profileCurrency: aud,
      conversionService: FixedConversionService(rates: [:])
    )

    #expect(result.events.count == 1)
    #expect(result.events[0].gain == 1000)
    #expect(result.events[0].isLongTerm == true)
    #expect(result.totalRealizedGain == 1000)
  }

  @Test
  func noSales_noGainEvents() async throws {
    let bhp = stockInstrument("BHP")
    let accountId = UUID()

    let buyTx = LegTransaction(
      date: date(0),
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: aud, quantity: -4000, type: .trade,
          categoryId: nil, earmarkId: nil),
        TransactionLeg(
          accountId: accountId, instrument: bhp, quantity: 100, type: .trade,
          categoryId: nil, earmarkId: nil),
      ])

    let result = try await CapitalGainsCalculator.computeWithConversion(
      transactions: [buyTx],
      profileCurrency: aud,
      conversionService: FixedConversionService(rates: [:])
    )

    #expect(result.events.isEmpty)
    #expect(result.openLots.count == 1)
    #expect(result.openLots[0].remainingQuantity == 100)
  }

  @Test
  func cryptoSwap_tracksGainOnSoldToken() async throws {
    let eth = cryptoInstrument("ETH")
    let uni = cryptoInstrument("UNI")
    let accountId = UUID()

    // Buy ETH with AUD
    let buyTx = LegTransaction(
      date: date(0),
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: aud, quantity: -3000, type: .trade,
          categoryId: nil, earmarkId: nil),
        TransactionLeg(
          accountId: accountId, instrument: eth, quantity: 1, type: .trade,
          categoryId: nil, earmarkId: nil),
      ])

    // Swap ETH for UNI
    let swapTx = LegTransaction(
      date: date(200),
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: eth, quantity: -1, type: .trade,
          categoryId: nil, earmarkId: nil),
        TransactionLeg(
          accountId: accountId, instrument: uni, quantity: 500, type: .trade,
          categoryId: nil, earmarkId: nil),
      ])

    let service = FixedConversionService(rates: [eth.id: 4000, uni.id: 8])
    let result = try await CapitalGainsCalculator.computeWithConversion(
      transactions: [buyTx, swapTx],
      profileCurrency: aud,
      conversionService: service
    )

    // ETH sold: cost basis 3000, proceeds 4000 (1 ETH at AUD 4000 on swap date)
    #expect(result.events.count == 1)
    #expect(result.events[0].instrument.id == eth.id)
    #expect(result.events[0].gain == 1000)
  }

  @Test
  func financialYearFilter_onlyIncludesEventsInRange() async throws {
    let bhp = stockInstrument("BHP")
    let accountId = UUID()

    let buyTx = LegTransaction(
      date: date(0),
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: aud, quantity: -4000, type: .trade,
          categoryId: nil, earmarkId: nil),
        TransactionLeg(
          accountId: accountId, instrument: bhp, quantity: 100, type: .trade,
          categoryId: nil, earmarkId: nil),
      ])

    let sellTx = LegTransaction(
      date: date(400),
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: bhp, quantity: -100, type: .trade,
          categoryId: nil, earmarkId: nil),
        TransactionLeg(
          accountId: accountId, instrument: aud, quantity: 5000, type: .trade,
          categoryId: nil, earmarkId: nil),
      ])

    let allResult = try await CapitalGainsCalculator.computeWithConversion(
      transactions: [buyTx, sellTx],
      profileCurrency: aud,
      conversionService: FixedConversionService(rates: [:])
    )
    #expect(allResult.events.count == 1)

    let earlyResult = try await CapitalGainsCalculator.computeWithConversion(
      transactions: [buyTx, sellTx],
      profileCurrency: aud,
      conversionService: FixedConversionService(rates: [:]),
      sellDateRange: date(0)...date(100)
    )
    // Sale on day 400 is outside the range
    #expect(earlyResult.events.isEmpty)
  }

  // MARK: - Multi-instrument scenarios

  @Test
  func multipleStocks_produceIndependentGainEvents() async throws {
    let bhp = stockInstrument("BHP")
    let cba = stockInstrument("CBA")
    let accountId = UUID()

    let buyBHP = buyTrade(on: 0, cash: -4000, qty: 100, of: bhp, accountId: accountId)
    let sellBHP = sellTrade(on: 400, qty: -100, of: bhp, proceeds: 5000, accountId: accountId)
    let buyCBA = buyTrade(on: 50, cash: -5000, qty: 50, of: cba, accountId: accountId)
    let sellCBA = sellTrade(on: 500, qty: -50, of: cba, proceeds: 7000, accountId: accountId)

    let result = try await CapitalGainsCalculator.computeWithConversion(
      transactions: [buyBHP, buyCBA, sellBHP, sellCBA],
      profileCurrency: aud,
      conversionService: FixedConversionService(rates: [:])
    )

    #expect(result.events.count == 2)
    let bhpGain = result.events.first { $0.instrument.id == "ASX:BHP.AX" }?.gain
    let cbaGain = result.events.first { $0.instrument.id == "ASX:CBA.AX" }?.gain
    #expect(bhpGain == 1000)
    #expect(cbaGain == 2000)
    #expect(result.totalRealizedGain == 3000)
  }

  /// Helper: buy `qty` of `instrument` on day `day`, funded by `cash` (negative)
  /// from `accountId`.
  private func buyTrade(
    on day: Int, cash: Decimal, qty: Decimal, of instrument: Instrument, accountId: UUID
  ) -> LegTransaction {
    LegTransaction(
      date: date(day),
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: aud, quantity: cash, type: .trade,
          categoryId: nil, earmarkId: nil),
        TransactionLeg(
          accountId: accountId, instrument: instrument, quantity: qty, type: .trade,
          categoryId: nil, earmarkId: nil),
      ])
  }

  /// Helper: sell `qty` (negative) of `instrument` on day `day`, receiving
  /// `proceeds` (positive) into `accountId`.
  private func sellTrade(
    on day: Int, qty: Decimal, of instrument: Instrument, proceeds: Decimal, accountId: UUID
  ) -> LegTransaction {
    LegTransaction(
      date: date(day),
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: instrument, quantity: qty, type: .trade,
          categoryId: nil, earmarkId: nil),
        TransactionLeg(
          accountId: accountId, instrument: aud, quantity: proceeds, type: .trade,
          categoryId: nil, earmarkId: nil),
      ])
  }
}
