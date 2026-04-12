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

  // Convenience constants
  static let AUD = Instrument.fiat(code: "AUD")
  static let USD = Instrument.fiat(code: "USD")
}
