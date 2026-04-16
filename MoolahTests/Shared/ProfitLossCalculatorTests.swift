import Foundation
import Testing

@testable import Moolah

@Suite("ProfitLossCalculator")
struct ProfitLossCalculatorTests {
  let aud = Instrument.fiat(code: "AUD")

  @Test func singleInstrument_noSales_unrealizedOnly() async throws {
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

    // BHP now worth $50/share
    let service = FixedConversionService(rates: ["ASX:BHP": 50])
    let results = try await ProfitLossCalculator.compute(
      transactions: [buyTx],
      profileCurrency: aud,
      conversionService: service,
      asOfDate: date(365)
    )

    #expect(results.count == 1)
    let bhpPL = results[0]
    #expect(bhpPL.instrument.id == "ASX:BHP")
    #expect(bhpPL.totalInvested == 4000)
    #expect(bhpPL.currentValue == 5000)
    #expect(bhpPL.unrealizedGain == 1000)
    #expect(bhpPL.realizedGain == 0)
    #expect(bhpPL.currentQuantity == 100)
  }

  @Test func partialSale_showsBothRealizedAndUnrealized() async throws {
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
      date: date(200),
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: bhp, quantity: -50, type: .transfer,
          categoryId: nil, earmarkId: nil),
        TransactionLeg(
          accountId: accountId, instrument: aud, quantity: 3000, type: .transfer,
          categoryId: nil, earmarkId: nil),
      ])

    // BHP now worth $50/share
    let service = FixedConversionService(rates: ["ASX:BHP": 50])
    let results = try await ProfitLossCalculator.compute(
      transactions: [buyTx, sellTx],
      profileCurrency: aud,
      conversionService: service,
      asOfDate: date(365)
    )

    #expect(results.count == 1)
    let bhpPL = results[0]
    #expect(bhpPL.currentQuantity == 50)
    #expect(bhpPL.totalInvested == 4000)
    #expect(bhpPL.currentValue == 2500)
    #expect(bhpPL.realizedGain == 1000)
    // Remaining cost basis: 50 * 40 = 2000. Current value: 2500. Unrealized: 500.
    #expect(bhpPL.unrealizedGain == 500)
  }

  @Test func fullySold_onlyRealizedGain() async throws {
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
      date: date(200),
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: bhp, quantity: -100, type: .transfer,
          categoryId: nil, earmarkId: nil),
        TransactionLeg(
          accountId: accountId, instrument: aud, quantity: 5000, type: .transfer,
          categoryId: nil, earmarkId: nil),
      ])

    let service = FixedConversionService(rates: [:])
    let results = try await ProfitLossCalculator.compute(
      transactions: [buyTx, sellTx],
      profileCurrency: aud,
      conversionService: service,
      asOfDate: date(365)
    )

    // Fully sold instruments should still appear (realized gain exists)
    #expect(results.count == 1)
    #expect(results[0].currentQuantity == 0)
    #expect(results[0].currentValue == 0)
    #expect(results[0].unrealizedGain == 0)
    #expect(results[0].realizedGain == 1000)
  }

  @Test func fiatOnlyTransactions_excludedFromResults() async throws {
    let accountId = UUID()
    let tx = LegTransaction(
      date: date(0),
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: aud, quantity: -500, type: .expense,
          categoryId: nil, earmarkId: nil)
      ])

    let service = FixedConversionService(rates: [:])
    let results = try await ProfitLossCalculator.compute(
      transactions: [tx],
      profileCurrency: aud,
      conversionService: service,
      asOfDate: date(0)
    )
    #expect(results.isEmpty)
  }

  // MARK: - Multi-instrument portfolios

  @Test func multipleStocks_eachGetsOwnRow() async throws {
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

  @Test func portfolioMixesStockAndCrypto() async throws {
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
