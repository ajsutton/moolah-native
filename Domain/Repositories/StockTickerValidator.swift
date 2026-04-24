import Foundation

/// Successfully parsed stock-ticker identity — the `(exchange, ticker)`
/// pair that uniquely identifies the instrument in the registry.
struct ValidatedStockTicker: Sendable, Hashable {
  let ticker: String
  let exchange: String
}

/// Validates typed stock-ticker search queries before they are persisted
/// as registry instruments.
protocol StockTickerValidator: Sendable {
  /// Attempts to validate a typed stock-ticker query. Accepts two forms:
  /// - `"EXCHANGE:TICKER"` — the canonical id form used throughout the
  ///   registry (e.g. `"ASX:BHP.AX"`).
  /// - Yahoo-native suffixed ticker — e.g. `"BHP.AX"`, `"AAPL"`,
  ///   `"^GSPC"`. The validator normalises both forms to an
  ///   `(exchange, ticker)` pair before fetching a probe price.
  /// Returns nil when no price is available for the parsed ticker.
  func validate(query: String) async throws -> ValidatedStockTicker?
}
