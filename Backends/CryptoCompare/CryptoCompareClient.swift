// Backends/CryptoCompare/CryptoCompareClient.swift
import Foundation

struct CryptoCompareClient: CryptoPriceClient, Sendable {
  private static let baseURL =
    URL(string: "https://min-api.cryptocompare.com") ?? URL(fileURLWithPath: "/")
  private let session: URLSession

  init(session: URLSession = .shared) {
    self.session = session
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
    guard let symbol = mapping.cryptocompareSymbol else {
      throw CryptoPriceError.noProviderMapping(
        tokenId: mapping.instrumentId, provider: "CryptoCompare")
    }
    let url = Self.histodayURL(symbol: symbol, from: range.lowerBound, to: range.upperBound)
    let (data, response) = try await session.data(for: URLRequest(url: url))
    guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
      throw URLError(.badServerResponse)
    }
    return try Self.parseHistodayResponse(data)
  }

  func currentPrices(for mappings: [CryptoProviderMapping]) async throws -> [String: Decimal] {
    let symbolToMapping = Dictionary(
      mappings.compactMap { mapping -> (String, CryptoProviderMapping)? in
        guard let sym = mapping.cryptocompareSymbol else { return nil }
        return (sym, mapping)
      },
      uniquingKeysWith: { first, _ in first }
    )
    guard !symbolToMapping.isEmpty else { return [:] }

    let url = Self.priceMultiURL(symbols: Array(symbolToMapping.keys))
    let (data, response) = try await session.data(for: URLRequest(url: url))
    guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
      throw URLError(.badServerResponse)
    }
    let symbolPrices = try Self.parsePriceMultiResponse(data)

    var result: [String: Decimal] = [:]
    for (symbol, price) in symbolPrices {
      if let mapping = symbolToMapping[symbol] {
        result[mapping.instrumentId] = price
      }
    }
    return result
  }

  // MARK: - URL builders (internal for testing)

  static func histodayURL(symbol: String, from: Date, to: Date) -> URL {
    let calendar = Calendar(identifier: .gregorian)
    let days = max(0, calendar.dateComponents([.day], from: from, to: to).day ?? 0)
    let toTimestamp = Int(to.timeIntervalSince1970)
    let pathURL = baseURL.appendingPathComponent("/data/v2/histoday")
    var components =
      URLComponents(url: pathURL, resolvingAgainstBaseURL: false) ?? URLComponents()
    components.queryItems = [
      URLQueryItem(name: "fsym", value: symbol),
      URLQueryItem(name: "tsym", value: "USD"),
      URLQueryItem(name: "limit", value: String(days)),
      URLQueryItem(name: "toTs", value: String(toTimestamp)),
    ]
    return components.url ?? pathURL
  }

  static func coinListURL() -> URL {
    let pathURL = baseURL.appendingPathComponent("/data/all/coinlist")
    var components =
      URLComponents(url: pathURL, resolvingAgainstBaseURL: false) ?? URLComponents()
    components.queryItems = [
      URLQueryItem(name: "summary", value: "true")
    ]
    return components.url ?? pathURL
  }

  static func priceMultiURL(symbols: [String]) -> URL {
    let pathURL = baseURL.appendingPathComponent("/data/pricemulti")
    var components =
      URLComponents(url: pathURL, resolvingAgainstBaseURL: false) ?? URLComponents()
    components.queryItems = [
      URLQueryItem(name: "fsyms", value: symbols.joined(separator: ",")),
      URLQueryItem(name: "tsyms", value: "USD"),
    ]
    return components.url ?? pathURL
  }

  // MARK: - Response parsers (internal for testing)

  static func parseHistodayResponse(_ data: Data) throws -> [String: Decimal] {
    let container = try JSONDecoder().decode(HistodayContainer.self, from: data)
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withFullDate]
    var result: [String: Decimal] = [:]
    for entry in container.Data.Data {
      let date = Date(timeIntervalSince1970: TimeInterval(entry.time))
      let key = formatter.string(from: date)
      result[key] = entry.close
    }
    return result
  }

  /// Parses the coin list response and builds a reverse index: lowercased contract address → symbol.
  /// Entries with "N/A" or empty contract addresses are excluded.
  static func parseCoinListResponse(_ data: Data) throws -> [String: String] {
    let container = try JSONDecoder().decode(CoinListContainer.self, from: data)
    var index: [String: String] = [:]
    for (_, coin) in container.Data {
      let addr = coin.SmartContractAddress
      guard addr != "N/A", !addr.isEmpty else { continue }
      index[addr.lowercased()] = coin.Symbol
    }
    return index
  }

  /// Parses the coin list to find symbols that have no smart contract address (native tokens).
  static func parseNativeSymbols(_ data: Data) throws -> Set<String> {
    let container = try JSONDecoder().decode(CoinListContainer.self, from: data)
    var symbols: Set<String> = []
    for (_, coin) in container.Data {
      let addr = coin.SmartContractAddress
      if addr == "N/A" || addr.isEmpty {
        symbols.insert(coin.Symbol)
      }
    }
    return symbols
  }

  static func parsePriceMultiResponse(_ data: Data) throws -> [String: Decimal] {
    let raw = try JSONDecoder().decode([String: [String: Decimal]].self, from: data)
    var result: [String: Decimal] = [:]
    for (symbol, currencies) in raw {
      if let usd = currencies["USD"] {
        result[symbol] = usd
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

// MARK: - Response types

private struct CoinListContainer: Decodable {
  let Data: [String: CoinListEntry]  // swiftlint:disable:this identifier_name
}

private struct CoinListEntry: Decodable {
  let Symbol: String  // swiftlint:disable:this identifier_name
  let CoinName: String  // swiftlint:disable:this identifier_name
  let SmartContractAddress: String  // swiftlint:disable:this identifier_name
}

private struct HistodayContainer: Decodable {
  let Data: HistodayData  // swiftlint:disable:this identifier_name
}

private struct HistodayData: Decodable {
  let Data: [HistodayEntry]  // swiftlint:disable:this identifier_name
}

private struct HistodayEntry: Decodable {
  let time: Int
  let close: Decimal
}
