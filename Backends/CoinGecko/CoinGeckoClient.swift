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

  func dailyPrice(for mapping: CryptoProviderMapping, on date: Date) async throws -> Decimal {
    let prices = try await dailyPrices(for: mapping, in: date...date)
    let dateString = Self.dateString(from: date)
    guard let price = prices[dateString] else {
      throw CryptoPriceError.noPriceAvailable(tokenId: mapping.instrumentId, date: dateString)
    }
    return price
  }

  func dailyPrices(
    for mapping: CryptoProviderMapping, in range: ClosedRange<Date>
  ) async throws -> [String: Decimal] {
    guard let coinId = mapping.coingeckoId else {
      throw CryptoPriceError.noProviderMapping(tokenId: mapping.instrumentId, provider: "CoinGecko")
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

  func currentPrices(for mappings: [CryptoProviderMapping]) async throws -> [String: Decimal] {
    let idToMapping = Dictionary(
      mappings.compactMap { mapping -> (String, CryptoProviderMapping)? in
        guard let id = mapping.coingeckoId else { return nil }
        return (id, mapping)
      },
      uniquingKeysWith: { first, _ in first }
    )
    guard !idToMapping.isEmpty else { return [:] }

    let url = Self.simplePriceURL(coinIds: Array(idToMapping.keys), apiKey: apiKey)
    let (data, response) = try await session.data(for: URLRequest(url: url))
    guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
      throw URLError(.badServerResponse)
    }
    let coinPrices = try Self.parseSimplePriceResponse(data)

    var result: [String: Decimal] = [:]
    for (coinId, price) in coinPrices {
      if let mapping = idToMapping[coinId] {
        result[mapping.instrumentId] = price
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

  // MARK: - Token resolution

  static func assetPlatformsURL(apiKey: String) -> URL {
    var components = URLComponents(
      url: baseURL.appendingPathComponent("asset_platforms"),
      resolvingAgainstBaseURL: false
    )!
    components.queryItems = [
      URLQueryItem(name: "x_cg_pro_api_key", value: apiKey)
    ]
    return components.url!
  }

  static func contractLookupURL(platformId: String, contractAddress: String, apiKey: String) -> URL
  {
    var components = URLComponents(
      url: baseURL.appendingPathComponent(
        "coins/\(platformId)/contract/\(contractAddress.lowercased())"),
      resolvingAgainstBaseURL: false
    )!
    components.queryItems = [
      URLQueryItem(name: "x_cg_pro_api_key", value: apiKey)
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

  /// Parses the asset platforms response into a chain ID → platform slug mapping.
  static func parseAssetPlatformsResponse(_ data: Data) throws -> [Int: String] {
    let platforms = try JSONDecoder().decode([AssetPlatform].self, from: data)
    var mapping: [Int: String] = [:]
    for platform in platforms {
      if let chainId = platform.chain_identifier {
        mapping[chainId] = platform.id
      }
    }
    return mapping
  }

  struct ContractLookupResult: Sendable {
    let id: String
    let symbol: String
    let name: String
    let decimals: Int?
  }

  /// Parses the contract lookup response to extract token details.
  static func parseContractLookupResponse(_ data: Data) throws -> ContractLookupResult {
    let raw = try JSONDecoder().decode(ContractLookupRaw.self, from: data)
    let decimals = raw.detail_platforms?.values.first?.decimal_place
    return ContractLookupResult(
      id: raw.id, symbol: raw.symbol, name: raw.name, decimals: decimals
    )
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

private struct AssetPlatform: Decodable {
  let id: String
  let chain_identifier: Int?
  let name: String
}

private struct ContractLookupRaw: Decodable {
  let id: String
  let symbol: String
  let name: String
  let detail_platforms: [String: DetailPlatform]?
}

private struct DetailPlatform: Decodable {
  let decimal_place: Int?
  let contract_address: String?
}
