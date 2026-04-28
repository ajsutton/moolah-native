import Foundation
import Testing

@testable import Moolah

@Suite("TradeEventClassifier")
struct TradeEventClassifierTests {
  let aud = Instrument.AUD
  let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")
  let eth = Instrument.crypto(
    chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18)
  let btc = Instrument.crypto(
    chainId: 0, contractAddress: nil, symbol: "BTC", name: "Bitcoin", decimals: 8)
  let date = Date(timeIntervalSince1970: 1_700_000_000)
  let account = UUID()

  private func tradeLeg(_ instr: Instrument, _ qty: Decimal) -> TransactionLeg {
    TransactionLeg(accountId: account, instrument: instr, quantity: qty, type: .trade)
  }

  private func feeLeg(_ instr: Instrument, _ qty: Decimal) -> TransactionLeg {
    TransactionLeg(accountId: account, instrument: instr, quantity: qty, type: .expense)
  }

  @Test("buy: positive trade leg + negative trade leg")
  func buy() async throws {
    let legs = [tradeLeg(aud, -4_000), tradeLeg(bhp, 100)]
    let result = try await TradeEventClassifier.classify(
      legs: legs, on: date, hostCurrency: aud,
      conversionService: FixedConversionService(rates: [:]))
    #expect(result.buys.count == 1)
    #expect(result.buys[0].instrument == bhp)
    #expect(result.buys[0].quantity == 100)
    #expect(result.buys[0].costPerUnit == 40)
    #expect(result.sells.isEmpty)
  }

  @Test("sell: positive fiat + negative non-fiat")
  func sell() async throws {
    let legs = [tradeLeg(aud, 2_500), tradeLeg(bhp, -50)]
    let result = try await TradeEventClassifier.classify(
      legs: legs, on: date, hostCurrency: aud,
      conversionService: FixedConversionService(rates: [:]))
    #expect(result.sells.count == 1)
    #expect(result.sells[0].instrument == bhp)
    #expect(result.sells[0].quantity == 50)
    #expect(result.sells[0].proceedsPerUnit == 50)
  }

  @Test("non-fiat swap is priced via host-currency conversion")
  func swap() async throws {
    let legs = [tradeLeg(eth, -2), tradeLeg(btc, 0.1)]
    let service = FixedConversionService(rates: [
      eth.id: Decimal(3_000),
      btc.id: Decimal(60_000),
    ])
    let result = try await TradeEventClassifier.classify(
      legs: legs, on: date, hostCurrency: aud, conversionService: service)
    #expect(result.buys.count == 1)
    #expect(result.buys[0].instrument == btc)
    #expect(result.buys[0].quantity == Decimal(string: "0.1"))
    #expect(result.buys[0].costPerUnit == Decimal(60_000))
    #expect(result.sells.count == 1)
    #expect(result.sells[0].instrument == eth)
    #expect(result.sells[0].quantity == 2)
    #expect(result.sells[0].proceedsPerUnit == Decimal(3_000))
  }

  @Test("fee legs are ignored")
  func feeIgnored() async throws {
    let legs = [tradeLeg(aud, -4_000), tradeLeg(bhp, 100), feeLeg(aud, -10)]
    let result = try await TradeEventClassifier.classify(
      legs: legs, on: date, hostCurrency: aud,
      conversionService: FixedConversionService(rates: [:]))
    try #require(result.buys.count == 1)
    #expect(result.buys[0].costPerUnit == 40)  // 4000/100, not (4000+10)/100
  }

  @Test("non-trade-typed legs are ignored entirely (older custom shapes)")
  func nonTradeLegsIgnored() async throws {
    let legs = [
      TransactionLeg(
        accountId: account, instrument: aud,
        quantity: -4_000, type: .expense),
      TransactionLeg(
        accountId: account, instrument: bhp,
        quantity: 100, type: .income),
    ]
    let result = try await TradeEventClassifier.classify(
      legs: legs, on: date, hostCurrency: aud,
      conversionService: FixedConversionService(rates: [:]))
    #expect(result.buys.isEmpty)
    #expect(result.sells.isEmpty)
  }

  @Test("zero-quantity trade leg is skipped (no divide-by-zero)")
  func zeroQuantityTradeLeg() async throws {
    let legs = [tradeLeg(aud, -4_000), tradeLeg(bhp, 0)]
    let result = try await TradeEventClassifier.classify(
      legs: legs, on: date, hostCurrency: aud,
      conversionService: FixedConversionService(rates: [:]))
    #expect(result.buys.isEmpty)
    #expect(result.sells.isEmpty)
  }

  @Test("fewer than two .trade legs returns empty")
  func fewerThanTwo() async throws {
    let result = try await TradeEventClassifier.classify(
      legs: [tradeLeg(aud, -100)], on: date, hostCurrency: aud,
      conversionService: FixedConversionService(rates: [:]))
    #expect(result.buys.isEmpty)
    #expect(result.sells.isEmpty)
  }
}
