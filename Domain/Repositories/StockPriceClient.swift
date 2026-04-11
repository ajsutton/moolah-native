// Domain/Repositories/StockPriceClient.swift
import Foundation

/// Response from a stock price data source.
struct StockPriceResponse: Sendable {
  let currency: Currency
  let prices: [String: Decimal]  // date string -> adjusted close price
}

/// Abstraction for fetching stock prices from an external source.
/// Production: YahooFinanceClient. Tests: FixedStockPriceClient.
protocol StockPriceClient: Sendable {
  /// Fetch daily adjusted close prices for a ticker over a date range.
  func fetchDailyPrices(ticker: String, from: Date, to: Date) async throws -> StockPriceResponse
}
