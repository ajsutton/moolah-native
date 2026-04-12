// Backends/Binance/BinanceClient.swift
import Foundation

struct BinanceClient: CryptoPriceClient, Sendable {
  private static let baseURL = URL(string: "https://api.binance.com")!
  private let session: URLSession
  private let usdtUsdRate: Decimal

  init(session: URLSession = .shared, usdtUsdRate: Decimal = Decimal(1)) {
    self.session = session
    self.usdtUsdRate = usdtUsdRate
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
    guard let symbol = token.binanceSymbol else {
      throw CryptoPriceError.noProviderMapping(tokenId: token.id, provider: "Binance")
    }

    var allPrices: [String: Decimal] = [:]
    let calendar = Calendar(identifier: .gregorian)
    var chunkStart = range.lowerBound

    // Binance max 1000 candles per request — paginate if needed
    while chunkStart <= range.upperBound {
      let chunkEnd = min(
        calendar.date(byAdding: .day, value: 999, to: chunkStart)!,
        range.upperBound
      )
      let url = Self.klinesURL(symbol: symbol, from: chunkStart, to: chunkEnd)
      let (data, response) = try await session.data(for: URLRequest(url: url))
      guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
        throw URLError(.badServerResponse)
      }
      let chunk = try Self.parseKlinesResponse(data)
      for (key, value) in chunk { allPrices[key] = value }
      chunkStart = calendar.date(byAdding: .day, value: 1, to: chunkEnd)!
    }

    return Self.applyUsdtRate(allPrices, rate: usdtUsdRate)
  }

  func currentPrices(for tokens: [CryptoToken]) async throws -> [String: Decimal] {
    // Binance has no batch endpoint — fetch one at a time
    var result: [String: Decimal] = [:]
    for token in tokens {
      guard token.binanceSymbol != nil else { continue }
      do {
        let price = try await dailyPrice(for: token, on: Date())
        result[token.id] = price
      } catch {
        continue
      }
    }
    return result
  }

  // MARK: - URL builders (internal for testing)

  static func klinesURL(symbol: String, from: Date, to: Date) -> URL {
    let startMs = Int(from.timeIntervalSince1970 * 1000)
    let endMs = Int(to.timeIntervalSince1970 * 1000)
    var components = URLComponents(
      url: baseURL.appendingPathComponent("/api/v3/klines"),
      resolvingAgainstBaseURL: false
    )!
    components.queryItems = [
      URLQueryItem(name: "symbol", value: symbol),
      URLQueryItem(name: "interval", value: "1d"),
      URLQueryItem(name: "startTime", value: String(startMs)),
      URLQueryItem(name: "endTime", value: String(endMs)),
      URLQueryItem(name: "limit", value: "1000"),
    ]
    return components.url!
  }

  // MARK: - Response parsers (internal for testing)

  static func parseKlinesResponse(_ data: Data) throws -> [String: Decimal] {
    let klines = try JSONDecoder().decode([[KlineValue]].self, from: data)
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withFullDate]
    var result: [String: Decimal] = [:]
    for kline in klines {
      guard kline.count >= 5 else { continue }
      guard case .int(let openTimeMs) = kline[0],
        case .string(let closeStr) = kline[4],
        let close = Decimal(string: closeStr)
      else { continue }
      let date = Date(timeIntervalSince1970: TimeInterval(openTimeMs) / 1000)
      let key = formatter.string(from: date)
      result[key] = close
    }
    return result
  }

  static func applyUsdtRate(_ prices: [String: Decimal], rate: Decimal) -> [String: Decimal] {
    prices.mapValues { $0 * rate }
  }

  private static func dateString(from date: Date) -> String {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withFullDate]
    return f.string(from: date)
  }
}

// MARK: - Binance kline array values are mixed types (int, string)

private enum KlineValue: Decodable {
  case int(Int)
  case string(String)
  case double(Double)

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if let v = try? container.decode(Int.self) {
      self = .int(v)
      return
    }
    if let v = try? container.decode(String.self) {
      self = .string(v)
      return
    }
    if let v = try? container.decode(Double.self) {
      self = .double(v)
      return
    }
    throw DecodingError.typeMismatch(
      KlineValue.self,
      DecodingError.Context(
        codingPath: decoder.codingPath,
        debugDescription: "Unexpected kline value type"
      )
    )
  }
}
