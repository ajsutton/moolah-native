// Domain/Repositories/StockSearchClient.swift
import Foundation

/// A hit from a stock-name search provider (typically Yahoo Finance's
/// `/v1/finance/search` endpoint). Filtered to investable instrument
/// types — equities, ETFs, and mutual funds.
struct StockSearchHit: Sendable {
  let symbol: String
  let name: String
  let exchange: String
  let quoteType: QuoteType
}

extension StockSearchHit: Hashable {}

/// Subset of Yahoo Finance `quoteType` values that the picker exposes.
/// Other types (`OPTION`, `INDEX`, `CURRENCY`, `CRYPTOCURRENCY`, …) are
/// dropped at the boundary so callers don't need to filter again.
enum QuoteType: String, Sendable, CaseIterable {
  case equity = "EQUITY"
  case etf = "ETF"
  case mutualFund = "MUTUALFUND"
}

/// Abstract name-search service for investable stock-like instruments.
/// Production: `YahooFinanceStockSearchClient`.
protocol StockSearchClient: Sendable {
  func search(query: String) async throws -> [StockSearchHit]
}
