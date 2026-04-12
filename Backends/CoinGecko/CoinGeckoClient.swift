// Backends/CoinGecko/CoinGeckoClient.swift
import Foundation

struct CoinGeckoClient: CryptoPriceClient, Sendable {
  private static let baseURL = URL(string: "https://pro-api.coingecko.com/api/v3")!
  private let session: URLSession
  private let apiKey: String

  init(session: URLSession = .shared, apiKey: String) {
    self.session = session
    self.apiKey = apiKey
  }

  func dailyPrice(for token: CryptoToken, on date: Date) async throws -> Decimal {
    let prices = try await dailyPrices(for: token, in: date...date)
    let dateString = Self.dateString(from: date)
    guard let price = prices[dateString] else {
      throw CryptoPriceError.noPriceAvailable(tokenId: token.id, date: dateString)
    }
    return price
  }

  func dailyPrices(
    for token: CryptoToken, in range: ClosedRange<Date>
  ) async throws -> [String: Decimal] {
    guard let coinId = token.coingeckoId else {
      throw CryptoPriceError.noProviderMapping(tokenId: token.id, provider: "CoinGecko")
    }
    let calendar = Calendar(identifier: .gregorian)
    let days = max(
      1,
      calendar.dateComponents([.day], from: range.lowerBound, to: range.upperBound).day ?? 1
    )
    let url = Self.marketChartURL(coinId: coinId, days: days, apiKey: apiKey)
    let (data, response) = try await session.data(for: URLRequest(url: url))
    guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
      throw URLError(.badServerResponse)
    }
    return try Self.parseMarketChartResponse(data)
  }

  func currentPrices(for tokens: [CryptoToken]) async throws -> [String: Decimal] {
    let idToToken = Dictionary(
      tokens.compactMap { token -> (String, CryptoToken)? in
        guard let id = token.coingeckoId else { return nil }
        return (id, token)
      },
      uniquingKeysWith: { first, _ in first }
    )
    guard !idToToken.isEmpty else { return [:] }

    let url = Self.simplePriceURL(coinIds: Array(idToToken.keys), apiKey: apiKey)
    let (data, response) = try await session.data(for: URLRequest(url: url))
    guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
      throw URLError(.badServerResponse)
    }
    let coinPrices = try Self.parseSimplePriceResponse(data)

    var result: [String: Decimal] = [:]
    for (coinId, price) in coinPrices {
      if let token = idToToken[coinId] {
        result[token.id] = price
      }
    }
    return result
  }

  // MARK: - URL builders (internal for testing)

  static func marketChartURL(coinId: String, days: Int, apiKey: String) -> URL {
    var components = URLComponents(
      url: baseURL.appendingPathComponent("coins/\(coinId)/market_chart"),
      resolvingAgainstBaseURL: false
    )!
    components.queryItems = [
      URLQueryItem(name: "vs_currency", value: "usd"),
      URLQueryItem(name: "days", value: String(days)),
      URLQueryItem(name: "interval", value: "daily"),
      URLQueryItem(name: "x_cg_pro_api_key", value: apiKey),
    ]
    return components.url!
  }

  static func simplePriceURL(coinIds: [String], apiKey: String) -> URL {
    var components = URLComponents(
      url: baseURL.appendingPathComponent("simple/price"),
      resolvingAgainstBaseURL: false
    )!
    components.queryItems = [
      URLQueryItem(name: "ids", value: coinIds.joined(separator: ",")),
      URLQueryItem(name: "vs_currencies", value: "usd"),
      URLQueryItem(name: "x_cg_pro_api_key", value: apiKey),
    ]
    return components.url!
  }

  // MARK: - Response parsers (internal for testing)

  static func parseMarketChartResponse(_ data: Data) throws -> [String: Decimal] {
    let container = try JSONDecoder().decode(MarketChartResponse.self, from: data)
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withFullDate]
    var result: [String: Decimal] = [:]
    for pair in container.prices {
      guard pair.count == 2 else { continue }
      let date = Date(timeIntervalSince1970: (pair[0] as NSDecimalNumber).doubleValue / 1000)
      let key = formatter.string(from: date)
      result[key] = pair[1]
    }
    return result
  }

  static func parseSimplePriceResponse(_ data: Data) throws -> [String: Decimal] {
    let raw = try JSONDecoder().decode([String: [String: Decimal]].self, from: data)
    var result: [String: Decimal] = [:]
    for (coinId, currencies) in raw {
      if let usd = currencies["usd"] {
        result[coinId] = usd
      }
    }
    return result
  }

  private static func dateString(from date: Date) -> String {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withFullDate]
    return f.string(from: date)
  }
}

private struct MarketChartResponse: Decodable {
  let prices: [[Decimal]]
}
