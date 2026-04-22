// MoolahTests/Backends/CoinGeckoClientTests.swift
import Foundation
import Testing

@testable import Moolah

@Suite("CoinGeckoClient")
struct CoinGeckoClientTests {
  private let ethMapping = CryptoProviderMapping(
    instrumentId: "1:native", coingeckoId: "ethereum", cryptocompareSymbol: nil, binanceSymbol: nil
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
    let json = Data(
      """
      {
        "prices": [
          [1743465600000, 1623.45],
          [1743552000000, 1650.00]
        ]
      }
      """.utf8)

    let prices = try CoinGeckoClient.parseMarketChartResponse(json)
    #expect(prices.count == 2)
    #expect(prices.values.contains(Decimal(string: "1623.45")!))
    #expect(prices.values.contains(Decimal(string: "1650")!))
  }

  @Test func parseSimplePriceResponse() throws {
    let json = Data(
      """
      {
        "ethereum": {"usd": 1623.45},
        "bitcoin": {"usd": 67890.12}
      }
      """.utf8)

    let prices = try CoinGeckoClient.parseSimplePriceResponse(json)
    #expect(prices["ethereum"] == Decimal(string: "1623.45")!)
    #expect(prices["bitcoin"] == Decimal(string: "67890.12")!)
  }

  // MARK: - Asset platforms parsing

  @Test func parseAssetPlatformsResponse_mapsChainIdToSlug() throws {
    let json = Data(
      """
      [
          { "id": "ethereum", "chain_identifier": 1, "name": "Ethereum" },
          { "id": "optimistic-ethereum", "chain_identifier": 10, "name": "Optimism" },
          { "id": "polygon-pos", "chain_identifier": 137, "name": "Polygon" },
          { "id": "no-chain", "chain_identifier": null, "name": "No Chain" }
      ]
      """.utf8)

    let mapping = try CoinGeckoClient.parseAssetPlatformsResponse(json)
    #expect(mapping[1] == "ethereum")
    #expect(mapping[10] == "optimistic-ethereum")
    #expect(mapping[137] == "polygon-pos")
    #expect(mapping.count == 3)
  }

  // MARK: - Contract lookup parsing

  @Test func parseContractLookupResponse_extractsTokenDetails() throws {
    let json = Data(
      """
      {
          "id": "uniswap",
          "symbol": "uni",
          "name": "Uniswap",
          "detail_platforms": {
              "ethereum": { "decimal_place": 18, "contract_address": "0x1f9840a85d5af5bf1d1762f925bdaddc4201f984" }
          }
      }
      """.utf8)

    let result = try CoinGeckoClient.parseContractLookupResponse(json)
    #expect(result.id == "uniswap")
    #expect(result.symbol == "uni")
    #expect(result.name == "Uniswap")
    #expect(result.decimals == 18)
  }

  // MARK: - Mapping without CoinGecko ID

  @Test func mappingWithoutCoinGeckoIdThrows() async {
    let mapping = CryptoProviderMapping(
      instrumentId: "1:0xabc", coingeckoId: nil, cryptocompareSymbol: nil, binanceSymbol: nil
    )
    let client = CoinGeckoClient(session: URLSession.shared, apiKey: "key")
    await #expect(throws: CryptoPriceError.self) {
      try await client.dailyPrice(for: mapping, on: Date())
    }
  }
}
