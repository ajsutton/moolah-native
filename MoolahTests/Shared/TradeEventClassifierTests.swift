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

  @Test("fiat-paired buy: emits one buy event with cost-per-unit derived from fiat outflow")
  func fiatPairedBuy() async throws {
    let legs = [
      TransactionLeg(accountId: UUID(), instrument: bhp, quantity: 100, type: .income),
      TransactionLeg(accountId: UUID(), instrument: aud, quantity: -4_000, type: .expense),
    ]
    let result = try await TradeEventClassifier.classify(
      legs: legs, on: date, hostCurrency: aud,
      conversionService: FixedConversionService(rates: [:])
    )
    #expect(result.buys.count == 1)
    #expect(result.buys[0].instrument == bhp)
    #expect(result.buys[0].quantity == 100)
    #expect(result.buys[0].costPerUnit == 40)
    #expect(result.sells.isEmpty)
  }

  @Test("fiat-paired sell: emits one sell event with proceeds-per-unit")
  func fiatPairedSell() async throws {
    let legs = [
      TransactionLeg(accountId: UUID(), instrument: bhp, quantity: -50, type: .income),
      TransactionLeg(accountId: UUID(), instrument: aud, quantity: 2_500, type: .income),
    ]
    let result = try await TradeEventClassifier.classify(
      legs: legs, on: date, hostCurrency: aud,
      conversionService: FixedConversionService(rates: [:])
    )
    #expect(result.sells.count == 1)
    #expect(result.sells[0].instrument == bhp)
    #expect(result.sells[0].quantity == 50)
    #expect(result.sells[0].proceedsPerUnit == 50)
  }

  @Test("crypto-to-crypto swap: emits one buy + one sell, each priced via the conversion service")
  func swap() async throws {
    let legs = [
      TransactionLeg(accountId: UUID(), instrument: eth, quantity: -2, type: .income),
      TransactionLeg(accountId: UUID(), instrument: btc, quantity: 0.1, type: .income),
    ]
    let service = FixedConversionService(rates: [
      eth.id: Decimal(3_000),  // 1 ETH = 3000 AUD
      btc.id: Decimal(60_000),  // 1 BTC = 60000 AUD
    ])
    let result = try await TradeEventClassifier.classify(
      legs: legs, on: date, hostCurrency: aud, conversionService: service
    )
    #expect(result.sells.count == 1)
    #expect(result.sells[0].instrument == eth)
    #expect(result.sells[0].quantity == 2)
    #expect(result.sells[0].proceedsPerUnit == 3_000)

    #expect(result.buys.count == 1)
    #expect(result.buys[0].instrument == btc)
    #expect(result.buys[0].quantity == dec("0.1"))
    #expect(result.buys[0].costPerUnit == 60_000)
  }

  @Test("all-fiat transaction: returns empty classification")
  func allFiatTransaction() async throws {
    let legs = [
      TransactionLeg(accountId: UUID(), instrument: aud, quantity: -100, type: .expense),
      TransactionLeg(accountId: UUID(), instrument: aud, quantity: 100, type: .income),
    ]
    let result = try await TradeEventClassifier.classify(
      legs: legs, on: date, hostCurrency: aud,
      conversionService: FixedConversionService(rates: [:])
    )
    #expect(result.buys.isEmpty)
    #expect(result.sells.isEmpty)
  }
}
