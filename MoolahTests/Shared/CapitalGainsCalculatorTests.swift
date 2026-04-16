import Foundation
import Testing

@testable import Moolah

@Suite("CapitalGainsCalculator")
struct CapitalGainsCalculatorTests {
  let aud = Instrument.fiat(code: "AUD")

  @Test func stockPurchase_thenSale_producesGainEvent() {
    let bhp = stockInstrument("BHP")
    let accountId = UUID()

    // Buy: transfer AUD out, BHP in
    let buyTx = LegTransaction(
      date: date(0),
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: aud, quantity: -4000, type: .transfer,
          categoryId: nil, earmarkId: nil),
        TransactionLeg(
          accountId: accountId, instrument: bhp, quantity: 100, type: .transfer,
          categoryId: nil, earmarkId: nil),
      ])

    // Sell: BHP out, AUD in
    let sellTx = LegTransaction(
      date: date(400),
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: bhp, quantity: -100, type: .transfer,
          categoryId: nil, earmarkId: nil),
        TransactionLeg(
          accountId: accountId, instrument: aud, quantity: 5000, type: .transfer,
          categoryId: nil, earmarkId: nil),
      ])

    let result = CapitalGainsCalculator.compute(
      transactions: [buyTx, sellTx],
      profileCurrency: aud
    )

    #expect(result.events.count == 1)
    #expect(result.events[0].gain == 1000)
    #expect(result.events[0].isLongTerm == true)
    #expect(result.totalRealizedGain == 1000)
  }

  @Test func noSales_noGainEvents() {
    let bhp = stockInstrument("BHP")
    let accountId = UUID()

    let buyTx = LegTransaction(
      date: date(0),
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: aud, quantity: -4000, type: .transfer,
          categoryId: nil, earmarkId: nil),
        TransactionLeg(
          accountId: accountId, instrument: bhp, quantity: 100, type: .transfer,
          categoryId: nil, earmarkId: nil),
      ])

    let result = CapitalGainsCalculator.compute(
      transactions: [buyTx],
      profileCurrency: aud
    )

    #expect(result.events.isEmpty)
    #expect(result.openLots.count == 1)
    #expect(result.openLots[0].remainingQuantity == 100)
  }

  @Test func cryptoSwap_tracksGainOnSoldToken() async throws {
    let eth = cryptoInstrument("ETH")
    let uni = cryptoInstrument("UNI")
    let accountId = UUID()

    // Buy ETH with AUD
    let buyTx = LegTransaction(
      date: date(0),
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: aud, quantity: -3000, type: .transfer,
          categoryId: nil, earmarkId: nil),
        TransactionLeg(
          accountId: accountId, instrument: eth, quantity: 1, type: .transfer,
          categoryId: nil, earmarkId: nil),
      ])

    // Swap ETH for UNI
    let swapTx = LegTransaction(
      date: date(200),
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: eth, quantity: -1, type: .transfer,
          categoryId: nil, earmarkId: nil),
        TransactionLeg(
          accountId: accountId, instrument: uni, quantity: 500, type: .transfer,
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

  @Test func financialYearFilter_onlyIncludesEventsInRange() {
    let bhp = stockInstrument("BHP")
    let accountId = UUID()

    let buyTx = LegTransaction(
      date: date(0),
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: aud, quantity: -4000, type: .transfer,
          categoryId: nil, earmarkId: nil),
        TransactionLeg(
          accountId: accountId, instrument: bhp, quantity: 100, type: .transfer,
          categoryId: nil, earmarkId: nil),
      ])

    let sellTx = LegTransaction(
      date: date(400),
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: bhp, quantity: -100, type: .transfer,
          categoryId: nil, earmarkId: nil),
        TransactionLeg(
          accountId: accountId, instrument: aud, quantity: 5000, type: .transfer,
          categoryId: nil, earmarkId: nil),
      ])

    let allResult = CapitalGainsCalculator.compute(
      transactions: [buyTx, sellTx],
      profileCurrency: aud
    )
    #expect(allResult.events.count == 1)

    let earlyResult = CapitalGainsCalculator.compute(
      transactions: [buyTx, sellTx],
      profileCurrency: aud,
      sellDateRange: date(0)...date(100)
    )
    // Sale on day 400 is outside the range
    #expect(earlyResult.events.isEmpty)
  }

  // MARK: - Multi-instrument scenarios

  @Test func multipleStocks_produceIndependentGainEvents() {
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
    let sellBHP = LegTransaction(
      date: date(400),
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: bhp, quantity: -100, type: .transfer,
          categoryId: nil, earmarkId: nil),
        TransactionLeg(
          accountId: accountId, instrument: aud, quantity: 5000, type: .transfer,
          categoryId: nil, earmarkId: nil),
      ])
    let buyCBA = LegTransaction(
      date: date(50),
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: aud, quantity: -5000, type: .transfer,
          categoryId: nil, earmarkId: nil),
        TransactionLeg(
          accountId: accountId, instrument: cba, quantity: 50, type: .transfer,
          categoryId: nil, earmarkId: nil),
      ])
    let sellCBA = LegTransaction(
      date: date(500),
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: cba, quantity: -50, type: .transfer,
          categoryId: nil, earmarkId: nil),
        TransactionLeg(
          accountId: accountId, instrument: aud, quantity: 7000, type: .transfer,
          categoryId: nil, earmarkId: nil),
      ])

    let result = CapitalGainsCalculator.compute(
      transactions: [buyBHP, buyCBA, sellBHP, sellCBA],
      profileCurrency: aud
    )

    #expect(result.events.count == 2)
    let bhpGain = result.events.first { $0.instrument.id == "ASX:BHP" }?.gain
    let cbaGain = result.events.first { $0.instrument.id == "ASX:CBA" }?.gain
    #expect(bhpGain == 1000)
    #expect(cbaGain == 2000)
    #expect(result.totalRealizedGain == 3000)
  }

  @Test func sellingOneInstrumentDoesNotTouchCostBasisOfAnother() {
    // If a user sells BHP, CBA cost basis must not change.
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
      date: date(50),
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: aud, quantity: -5000, type: .transfer,
          categoryId: nil, earmarkId: nil),
        TransactionLeg(
          accountId: accountId, instrument: cba, quantity: 50, type: .transfer,
          categoryId: nil, earmarkId: nil),
      ])
    let sellAllBHP = LegTransaction(
      date: date(400),
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: bhp, quantity: -100, type: .transfer,
          categoryId: nil, earmarkId: nil),
        TransactionLeg(
          accountId: accountId, instrument: aud, quantity: 5000, type: .transfer,
          categoryId: nil, earmarkId: nil),
      ])

    let result = CapitalGainsCalculator.compute(
      transactions: [buyBHP, buyCBA, sellAllBHP],
      profileCurrency: aud
    )

    // Only BHP sale produces an event; CBA is still held.
    #expect(result.events.count == 1)
    #expect(result.events[0].instrument.id == "ASX:BHP")
    #expect(result.events[0].gain == 1000)
  }

  // MARK: - Helpers

  private func stockInstrument(_ name: String) -> Instrument {
    Instrument(
      id: "ASX:\(name)", kind: .stock, name: name, decimals: 0,
      ticker: "\(name).AX", exchange: "ASX", chainId: nil, contractAddress: nil)
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
}
