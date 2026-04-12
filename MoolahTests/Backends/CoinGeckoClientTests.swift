// MoolahTests/Backends/CoinGeckoClientTests.swift
import Foundation
import Testing

@testable import Moolah

@Suite("CoinGeckoClient")
struct CoinGeckoClientTests {
  private let eth = CryptoToken(
    chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum",
    decimals: 18, coingeckoId: "ethereum", cryptocompareSymbol: nil, binanceSymbol: nil
  )

  private func date(_ string: String) -> Date {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withFullDate]
    return f.date(from: string)!
  }

  // MARK: - URL construction

  @Test func marketChartURLIncludesCoinIdAndDays() {
    let url = CoinGeckoClient.marketChartURL(
      coinId: "ethereum", days: 10, apiKey: "test-key"
    )
    let components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
    #expect(components.host == "pro-api.coingecko.com")
    #expect(components.path == "/api/v3/coins/ethereum/market_chart")
    let queryItems = Dictionary(
      uniqueKeysWithValues: components.queryItems!.map { ($0.name, $0.value!) })
    #expect(queryItems["vs_currency"] == "usd")
    #expect(queryItems["days"] == "10")
    #expect(queryItems["interval"] == "daily")
    #expect(queryItems["x_cg_pro_api_key"] == "test-key")
  }

  @Test func simplePriceURLIncludesMultipleIds() {
    let url = CoinGeckoClient.simplePriceURL(
      coinIds: ["ethereum", "bitcoin"], apiKey: "test-key"
    )
    let components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
    #expect(components.path == "/api/v3/simple/price")
    let queryItems = Dictionary(
      uniqueKeysWithValues: components.queryItems!.map { ($0.name, $0.value!) })
    #expect(queryItems["ids"] == "ethereum,bitcoin")
    #expect(queryItems["vs_currencies"] == "usd")
  }

  // MARK: - Response parsing

  @Test func parseMarketChartResponse() throws {
    let json = """
      {
        "prices": [
          [1743465600000, 1623.45],
          [1743552000000, 1650.00]
        ]
      }
      """.data(using: .utf8)!

    let prices = try CoinGeckoClient.parseMarketChartResponse(json)
    #expect(prices.count == 2)
    #expect(prices.values.contains(Decimal(string: "1623.45")!))
    #expect(prices.values.contains(Decimal(string: "1650")!))
  }

  @Test func parseSimplePriceResponse() throws {
    let json = """
      {
        "ethereum": {"usd": 1623.45},
        "bitcoin": {"usd": 67890.12}
      }
      """.data(using: .utf8)!

    let prices = try CoinGeckoClient.parseSimplePriceResponse(json)
    #expect(prices["ethereum"] == Decimal(string: "1623.45")!)
    #expect(prices["bitcoin"] == Decimal(string: "67890.12")!)
  }

  // MARK: - Token without CoinGecko mapping

  @Test func tokenWithoutCoinGeckoIdThrows() async {
    let token = CryptoToken(
      chainId: 1, contractAddress: "0xabc", symbol: "X", name: "X",
      decimals: 18, coingeckoId: nil, cryptocompareSymbol: nil, binanceSymbol: nil
    )
    let client = CoinGeckoClient(session: URLSession.shared, apiKey: "key")
    await #expect(throws: CryptoPriceError.self) {
      try await client.dailyPrice(for: token, on: Date())
    }
  }
}
