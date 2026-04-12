// Backends/CryptoCompare/CryptoCompareClient.swift
import Foundation

struct CryptoCompareClient: CryptoPriceClient, Sendable {
  private static let baseURL = URL(string: "https://min-api.cryptocompare.com")!
  private let session: URLSession

  init(session: URLSession = .shared) {
    self.session = session
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
    guard let symbol = token.cryptocompareSymbol else {
      throw CryptoPriceError.noProviderMapping(tokenId: token.id, provider: "CryptoCompare")
    }
    let url = Self.histodayURL(symbol: symbol, from: range.lowerBound, to: range.upperBound)
    let (data, response) = try await session.data(for: URLRequest(url: url))
    guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
      throw URLError(.badServerResponse)
    }
    return try Self.parseHistodayResponse(data)
  }

  func currentPrices(for tokens: [CryptoToken]) async throws -> [String: Decimal] {
    let symbolToToken = Dictionary(
      tokens.compactMap { token -> (String, CryptoToken)? in
        guard let sym = token.cryptocompareSymbol else { return nil }
        return (sym, token)
      },
      uniquingKeysWith: { first, _ in first }
    )
    guard !symbolToToken.isEmpty else { return [:] }

    let url = Self.priceMultiURL(symbols: Array(symbolToToken.keys))
    let (data, response) = try await session.data(for: URLRequest(url: url))
    guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
      throw URLError(.badServerResponse)
    }
    let symbolPrices = try Self.parsePriceMultiResponse(data)

    var result: [String: Decimal] = [:]
    for (symbol, price) in symbolPrices {
      if let token = symbolToToken[symbol] {
        result[token.id] = price
      }
    }
    return result
  }

  // MARK: - URL builders (internal for testing)

  static func histodayURL(symbol: String, from: Date, to: Date) -> URL {
    let calendar = Calendar(identifier: .gregorian)
    let days = max(0, calendar.dateComponents([.day], from: from, to: to).day ?? 0)
    let toTimestamp = Int(to.timeIntervalSince1970)

    var components = URLComponents(
      url: baseURL.appendingPathComponent("/data/v2/histoday"),
      resolvingAgainstBaseURL: false
    )!
    components.queryItems = [
      URLQueryItem(name: "fsym", value: symbol),
      URLQueryItem(name: "tsym", value: "USD"),
      URLQueryItem(name: "limit", value: String(days)),
      URLQueryItem(name: "toTs", value: String(toTimestamp)),
    ]
    return components.url!
  }

  static func priceMultiURL(symbols: [String]) -> URL {
    var components = URLComponents(
      url: baseURL.appendingPathComponent("/data/pricemulti"),
      resolvingAgainstBaseURL: false
    )!
    components.queryItems = [
      URLQueryItem(name: "fsyms", value: symbols.joined(separator: ",")),
      URLQueryItem(name: "tsyms", value: "USD"),
    ]
    return components.url!
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
