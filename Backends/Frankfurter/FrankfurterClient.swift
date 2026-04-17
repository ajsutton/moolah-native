// Backends/Frankfurter/FrankfurterClient.swift
import Foundation
import OSLog

/// Client for the public Frankfurter exchange-rate API.
/// Uses the range endpoint `<from>..<to>?base=<code>` which returns rates
/// keyed by trading date. When the requested range has no trading data
/// (weekends/holidays/today before the daily post), Frankfurter shifts the
/// response to the nearest available trading day; 404 is returned only when
/// the requested dates are wholly outside coverage (e.g. far-future).
struct FrankfurterClient: ExchangeRateClient, Sendable {
  private static let baseURL = URL(string: "https://api.frankfurter.app/")!
  private static let logger = Logger(subsystem: "com.moolah.app", category: "FrankfurterClient")
  private let session: URLSession

  init(session: URLSession = .shared) {
    self.session = session
  }

  func fetchRates(
    base: String, from: Date, to: Date
  ) async throws -> [String: [String: Decimal]] {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withFullDate]

    let fromStr = formatter.string(from: from)
    let toStr = formatter.string(from: to)

    let url = Self.baseURL.appendingPathComponent("\(fromStr)..\(toStr)")
    var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
    components.queryItems = [URLQueryItem(name: "base", value: base)]

    let requestURL = components.url!
    let request = URLRequest(url: requestURL)
    let (data, response) = try await session.data(for: request)

    guard let httpResponse = response as? HTTPURLResponse,
      (200...299).contains(httpResponse.statusCode)
    else {
      let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
      let body = String(data: data, encoding: .utf8) ?? "<non-utf8>"
      Self.logger.error(
        "Exchange rate request failed: \(statusCode, privacy: .public) for \(requestURL.absoluteString, privacy: .public) — \(body, privacy: .public)"
      )
      throw URLError(.badServerResponse)
    }

    return try Self.parseResponse(data)
  }

  /// Parses the Frankfurter range response. Shape:
  /// `{"amount":1.0,"base":"GBP","start_date":"...","end_date":"...","rates":{"2026-04-10":{"AUD":1.9,...}}}`
  static func parseResponse(_ data: Data) throws -> [String: [String: Decimal]] {
    let response = try JSONDecoder().decode(FrankfurterRangeResponse.self, from: data)
    return response.rates
  }
}

private struct FrankfurterRangeResponse: Decodable {
  let rates: [String: [String: Decimal]]
}
