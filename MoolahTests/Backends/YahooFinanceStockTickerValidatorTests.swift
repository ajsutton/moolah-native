import Foundation
import Testing

@testable import Moolah

@Suite("YahooFinanceStockTickerValidator")
struct YahooFinanceStockTickerValidatorTests {
  @Test("parses EXCHANGE:TICKER form")
  func parsesExchangeTickerForm() async throws {
    let stub = StubYahooFinancePriceFetcher(available: ["BHP.AX": 45.0])
    let validator = YahooFinanceStockTickerValidator(priceFetcher: stub)
    let result = try await validator.validate(query: "ASX:BHP.AX")
    #expect(result?.ticker == "BHP.AX")
    #expect(result?.exchange == "ASX")
  }

  @Test("parses Yahoo-native suffix form")
  func parsesYahooSuffixForm() async throws {
    let stub = StubYahooFinancePriceFetcher(available: ["BHP.AX": 45.0])
    let validator = YahooFinanceStockTickerValidator(priceFetcher: stub)
    let result = try await validator.validate(query: "BHP.AX")
    #expect(result?.ticker == "BHP.AX")
    #expect(result?.exchange == "ASX")
  }

  @Test("returns nil when price fetcher finds nothing")
  func returnsNilWhenUnknown() async throws {
    let stub = StubYahooFinancePriceFetcher(available: [:])
    let validator = YahooFinanceStockTickerValidator(priceFetcher: stub)
    let result = try await validator.validate(query: "UNKNOWN")
    #expect(result == nil)
  }

  @Test("bare ticker without Yahoo suffix defaults to NASDAQ")
  func bareTickerDefaultsToNasdaq() async throws {
    let stub = StubYahooFinancePriceFetcher(available: ["AAPL": 180.0])
    let validator = YahooFinanceStockTickerValidator(priceFetcher: stub)
    let result = try await validator.validate(query: "AAPL")
    #expect(result?.ticker == "AAPL")
    #expect(result?.exchange == "NASDAQ")
  }
}

private struct StubYahooFinancePriceFetcher: YahooFinancePriceFetcher {
  let available: [String: Double]

  func currentPrice(for ticker: String) async throws -> Decimal? {
    guard let price = available[ticker] else { return nil }
    return Decimal(price)
  }
}
