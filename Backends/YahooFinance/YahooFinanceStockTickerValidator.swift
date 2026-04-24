// Backends/YahooFinance/YahooFinanceStockTickerValidator.swift
import Foundation

/// Default `StockTickerValidator` implementation — parses the query into
/// an `(exchange, ticker)` pair and probes Yahoo Finance to confirm the
/// ticker resolves to a real instrument.
struct YahooFinanceStockTickerValidator: StockTickerValidator {
  private let priceFetcher: any YahooFinancePriceFetcher

  init(priceFetcher: any YahooFinancePriceFetcher) {
    self.priceFetcher = priceFetcher
  }

  func validate(query: String) async throws -> ValidatedStockTicker? {
    guard let parsed = parse(query: query) else { return nil }
    let price = try await priceFetcher.currentPrice(for: parsed.ticker)
    guard price != nil else { return nil }
    return parsed
  }

  private func parse(query: String) -> ValidatedStockTicker? {
    let trimmed = query.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return nil }

    if trimmed.contains(":") {
      let parts = trimmed.split(separator: ":", maxSplits: 1)
      guard parts.count == 2 else { return nil }
      return ValidatedStockTicker(
        ticker: String(parts[1]),
        exchange: String(parts[0]).uppercased())
    }

    if trimmed.contains(".") {
      let parts = trimmed.split(separator: ".", maxSplits: 1)
      guard parts.count == 2 else { return nil }
      let exchange = Self.yahooSuffixToExchange(String(parts[1]))
      return ValidatedStockTicker(ticker: trimmed, exchange: exchange)
    }

    // Bare ticker — default to NASDAQ.
    return ValidatedStockTicker(ticker: trimmed.uppercased(), exchange: "NASDAQ")
  }

  private static func yahooSuffixToExchange(_ suffix: String) -> String {
    switch suffix.uppercased() {
    case "AX": "ASX"
    case "L": "LSE"
    case "TO": "TSX"
    case "HK": "HKEX"
    case "T": "TYO"
    case "PA": "EPA"
    case "DE": "FRA"
    default: suffix.uppercased()
    }
  }
}
