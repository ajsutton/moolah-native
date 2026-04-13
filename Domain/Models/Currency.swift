import Foundation

struct Currency: Codable, Sendable, Hashable {
  let code: String
  let symbol: String
  let decimals: Int

  // Cache lock and storage — there are only a handful of distinct currency
  // codes in practice, so this dict stays tiny and lookup is O(1).
  // nonisolated(unsafe) is correct: all accesses are protected by cacheLock.
  private static let cacheLock = NSLock()
  private nonisolated(unsafe) static var cache: [String: Currency] = [:]

  /// Construct Currency from an ISO currency code.
  /// Symbol and decimal places are derived from the system locale database.
  /// Results are cached per code so NumberFormatter is only created once.
  static func from(code: String) -> Currency {
    cacheLock.lock()
    if let cached = cache[code] {
      cacheLock.unlock()
      return cached
    }
    cacheLock.unlock()

    let formatter = NumberFormatter()
    formatter.numberStyle = .currency
    formatter.currencyCode = code
    let currency = Currency(
      code: code,
      symbol: formatter.currencySymbol ?? code,
      decimals: formatter.maximumFractionDigits
    )

    cacheLock.lock()
    cache[code] = currency
    cacheLock.unlock()

    return currency
  }

  // Convenience constants — delegate to from(code:) so values are locale-sensitive
  static let AUD = Currency.from(code: "AUD")
  static let USD = Currency.from(code: "USD")
}
