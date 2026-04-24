// Backends/YahooFinance/YahooFinancePriceFetcher.swift
import Foundation

/// Minimal seam used by `YahooFinanceStockTickerValidator` to probe
/// whether a parsed ticker corresponds to a real Yahoo-known instrument.
/// Kept narrower than `StockPriceClient` so tests can stub it without
/// constructing a full price-history response.
protocol YahooFinancePriceFetcher: Sendable {
  /// Returns the most recent available price for `ticker`, or nil when
  /// Yahoo has no data for that symbol (i.e. the ticker is unknown).
  func currentPrice(for ticker: String) async throws -> Decimal?
}

extension YahooFinanceClient: YahooFinancePriceFetcher {
  /// Adapts `fetchDailyPrices` into a single-value probe. We look back a
  /// week to tolerate weekends / holidays and return the latest price by
  /// date. Treats "ticker not found" errors (`.apiError` / `.noData`) as
  /// `nil` rather than rethrowing, so the validator can report the
  /// ticker as invalid cleanly. All other errors (e.g. transport
  /// failures) propagate.
  func currentPrice(for ticker: String) async throws -> Decimal? {
    let to = Date()
    let from = to.addingTimeInterval(-7 * 24 * 60 * 60)
    let response: StockPriceResponse
    do {
      response = try await fetchDailyPrices(ticker: ticker, from: from, to: to)
    } catch YahooFinanceError.apiError, YahooFinanceError.noData {
      return nil
    }
    guard let latestKey = response.prices.keys.max() else { return nil }
    return response.prices[latestKey]
  }
}
