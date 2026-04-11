// Backends/Frankfurter/FrankfurterClient.swift
import Foundation

struct FrankfurterClient: ExchangeRateClient, Sendable {
  private static let baseURL = URL(string: "https://api.frankfurter.dev/v2/")!
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

    let request = URLRequest(url: components.url!)
    let (data, response) = try await session.data(for: request)

    guard let httpResponse = response as? HTTPURLResponse,
      (200...299).contains(httpResponse.statusCode)
    else {
      throw URLError(.badServerResponse)
    }

    return try Self.parseResponse(data)
  }

  static func parseResponse(_ data: Data) throws -> [String: [String: Decimal]] {
    let entries = try JSONDecoder().decode([FrankfurterEntry].self, from: data)
    var result: [String: [String: Decimal]] = [:]
    for entry in entries {
      result[entry.date, default: [:]][entry.quote] = entry.rate
    }
    return result
  }
}

private struct FrankfurterEntry: Decodable {
  let date: String
  let base: String
  let quote: String
  let rate: Decimal
}
