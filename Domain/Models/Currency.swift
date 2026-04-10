import Foundation

struct Currency: Codable, Sendable, Hashable {
  let code: String
  let symbol: String
  let decimals: Int

  /// Construct Currency from an ISO currency code.
  /// Symbol and decimal places are derived from the system locale database.
  static func from(code: String) -> Currency {
    let formatter = NumberFormatter()
    formatter.numberStyle = .currency
    formatter.currencyCode = code
    return Currency(
      code: code,
      symbol: formatter.currencySymbol ?? code,
      decimals: formatter.maximumFractionDigits
    )
  }

  // Convenience constants — delegate to from(code:) so values are locale-sensitive
  static let AUD = Currency.from(code: "AUD")
  static let USD = Currency.from(code: "USD")
}
