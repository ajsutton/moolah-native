import Foundation

struct Instrument: Codable, Sendable, Hashable, Identifiable {
  enum Kind: String, Codable, Sendable {
    case fiatCurrency
    case stock
    case cryptoToken
  }

  let id: String
  let kind: Kind
  let name: String
  let decimals: Int

  // Kind-specific metadata (all optional)
  let ticker: String?
  let exchange: String?
  let chainId: Int?
  let contractAddress: String?

  /// Factory for fiat currency instruments.
  /// Derives decimal places from the system locale database.
  static func fiat(code: String) -> Instrument {
    let formatter = NumberFormatter()
    formatter.numberStyle = .currency
    formatter.currencyCode = code
    return Instrument(
      id: code,
      kind: .fiatCurrency,
      name: code,
      decimals: formatter.maximumFractionDigits,
      ticker: nil,
      exchange: nil,
      chainId: nil,
      contractAddress: nil
    )
  }

  /// Derive the currency symbol from system locale (fiat only).
  /// Returns nil for non-fiat instruments.
  var currencySymbol: String? {
    guard kind == .fiatCurrency else { return nil }
    let formatter = NumberFormatter()
    formatter.numberStyle = .currency
    formatter.currencyCode = id
    return formatter.currencySymbol
  }

  /// Factory for stock instruments.
  /// `ticker` is the Yahoo Finance symbol (e.g., "BHP.AX").
  /// `exchange` is the exchange code (e.g., "ASX", "NASDAQ").
  /// `name` is the display name (e.g., "BHP", "Apple").
  /// `decimals` defaults to 0 (whole shares); override for fractional instruments.
  static func stock(ticker: String, exchange: String, name: String, decimals: Int = 0) -> Instrument
  {
    Instrument(
      id: "\(exchange):\(name)",
      kind: .stock,
      name: name,
      decimals: decimals,
      ticker: ticker,
      exchange: exchange,
      chainId: nil,
      contractAddress: nil
    )
  }

  /// Convenience: the ticker symbol for display. For crypto, this is the short symbol (ETH, BTC).
  /// For stocks, the exchange ticker. For fiat, nil (use currencySymbol instead).
  var displaySymbol: String? {
    ticker
  }

  // Convenience constants
  static let AUD = Instrument.fiat(code: "AUD")
  static let USD = Instrument.fiat(code: "USD")
}

extension Instrument {
  /// Factory for cryptocurrency token instruments.
  /// Uses the same `chainId:address` ID scheme as the legacy CryptoToken type.
  static func crypto(
    chainId: Int,
    contractAddress: String?,
    symbol: String,
    name: String,
    decimals: Int
  ) -> Instrument {
    let normalizedAddress = contractAddress?.lowercased()
    let id: String
    if let address = normalizedAddress {
      id = "\(chainId):\(address)"
    } else {
      id = "\(chainId):native"
    }
    return Instrument(
      id: id,
      kind: .cryptoToken,
      name: name,
      decimals: decimals,
      ticker: symbol,
      exchange: nil,
      chainId: chainId,
      contractAddress: normalizedAddress
    )
  }
}
