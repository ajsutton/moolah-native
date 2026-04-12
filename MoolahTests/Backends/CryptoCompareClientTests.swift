// MoolahTests/Backends/CryptoCompareClientTests.swift
import Foundation
import Testing

@testable import Moolah

@Suite("CryptoCompareClient")
struct CryptoCompareClientTests {
  private let eth = CryptoToken(
    chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum",
    decimals: 18, coingeckoId: nil, cryptocompareSymbol: "ETH", binanceSymbol: nil
  )

  private func date(_ string: String) -> Date {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withFullDate]
    return f.date(from: string)!
  }

  // MARK: - URL construction

  @Test func dailyPricesURLIncludesSymbolAndDateRange() throws {
    let from = date("2026-04-01")
    let to = date("2026-04-10")
    let url = CryptoCompareClient.histodayURL(symbol: "ETH", from: from, to: to)
    let components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
    #expect(components.host == "min-api.cryptocompare.com")
    #expect(components.path == "/data/v2/histoday")
    let queryItems = Dictionary(
      uniqueKeysWithValues: components.queryItems!.map { ($0.name, $0.value!) })
    #expect(queryItems["fsym"] == "ETH")
    #expect(queryItems["tsym"] == "USD")
    #expect(queryItems["limit"] != nil)
    #expect(queryItems["toTs"] != nil)
  }

  @Test func currentPricesURLIncludesMultipleSymbols() throws {
    let url = CryptoCompareClient.priceMultiURL(symbols: ["ETH", "BTC"])
    let components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
    let queryItems = Dictionary(
      uniqueKeysWithValues: components.queryItems!.map { ($0.name, $0.value!) })
    #expect(queryItems["fsyms"] == "ETH,BTC")
    #expect(queryItems["tsyms"] == "USD")
  }

  // MARK: - Response parsing

  @Test func parseHistodayResponse() throws {
    let json = """
      {
        "Response": "Success",
        "Data": {
          "Data": [
            {"time": 1743465600, "close": 1623.45},
            {"time": 1743552000, "close": 1650.00}
          ]
        }
      }
      """.data(using: .utf8)!

    let prices = try CryptoCompareClient.parseHistodayResponse(json)
    #expect(prices.count == 2)
    #expect(prices.values.contains(Decimal(string: "1623.45")!))
    #expect(prices.values.contains(Decimal(string: "1650")!))
  }

  @Test func parsePriceMultiResponse() throws {
    let json = """
      {
        "ETH": {"USD": 1623.45},
        "BTC": {"USD": 67890.12}
      }
      """.data(using: .utf8)!

    let prices = try CryptoCompareClient.parsePriceMultiResponse(json)
    #expect(prices["ETH"] == Decimal(string: "1623.45")!)
    #expect(prices["BTC"] == Decimal(string: "67890.12")!)
  }

  // MARK: - Coin list parsing

  @Test func parseCoinListResponse_extractsSymbolByContractAddress() throws {
    let json = """
      {
          "Data": {
              "ETH": {
                  "Symbol": "ETH",
                  "CoinName": "Ethereum",
                  "SmartContractAddress": "N/A"
              },
              "UNI": {
                  "Symbol": "UNI",
                  "CoinName": "Uniswap",
                  "SmartContractAddress": "0x1f9840a85d5af5bf1d1762f925bdaddc4201f984"
              },
              "SCAM": {
                  "Symbol": "SCAM",
                  "CoinName": "Scam Token",
                  "SmartContractAddress": "0xdeadbeef"
              }
          }
      }
      """.data(using: .utf8)!

    let index = try CryptoCompareClient.parseCoinListResponse(json)
    #expect(index["0x1f9840a85d5af5bf1d1762f925bdaddc4201f984"] == "UNI")
    #expect(index["0xdeadbeef"] == "SCAM")
    #expect(index["N/A"] == nil)
  }

  @Test func parseCoinListResponse_nativeTokenHasNoContractEntry() throws {
    let json = """
      {
          "Data": {
              "BTC": {
                  "Symbol": "BTC",
                  "CoinName": "Bitcoin",
                  "SmartContractAddress": "N/A"
              }
          }
      }
      """.data(using: .utf8)!

    let index = try CryptoCompareClient.parseCoinListResponse(json)
    #expect(index.isEmpty)
  }

  @Test func findNativeSymbol_matchesBySymbol() throws {
    let json = """
      {
          "Data": {
              "BTC": { "Symbol": "BTC", "CoinName": "Bitcoin", "SmartContractAddress": "N/A" },
              "ETH": { "Symbol": "ETH", "CoinName": "Ethereum", "SmartContractAddress": "N/A" }
          }
      }
      """.data(using: .utf8)!

    let nativeSymbols = try CryptoCompareClient.parseNativeSymbols(json)
    #expect(nativeSymbols.contains("BTC"))
    #expect(nativeSymbols.contains("ETH"))
  }

  // MARK: - Token without CryptoCompare mapping

  @Test func tokenWithoutCryptoCompareSymbolThrows() async {
    let token = CryptoToken(
      chainId: 1, contractAddress: "0xabc", symbol: "OBSCURE", name: "Obscure",
      decimals: 18, coingeckoId: nil, cryptocompareSymbol: nil, binanceSymbol: nil
    )
    let client = CryptoCompareClient(session: URLSession.shared)
    await #expect(throws: CryptoPriceError.self) {
      try await client.dailyPrice(for: token, on: Date())
    }
  }
}
