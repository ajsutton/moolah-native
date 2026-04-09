import Foundation

struct MonetaryAmount: Codable, Sendable, Hashable, Comparable {
  let cents: Int
  let currency: Currency

  static let zero = MonetaryAmount(cents: 0, currency: Currency.defaultCurrency)

  init(cents: Int, currency: Currency) {
    self.cents = cents
    self.currency = currency
  }

  var isPositive: Bool { cents > 0 }
  var isNegative: Bool { cents < 0 }
  var isZero: Bool { cents == 0 }

  /// The amount as a Decimal suitable for currency formatting (e.g. 5023 cents -> 50.23).
  var decimalValue: Decimal {
    Decimal(cents) / pow(10, self.currency.decimals)
  }

  var formatted: String {
    self.decimalValue.formatted(.currency(code: currency.code))
  }

  var formatNoSymbol: String {
    self.decimalValue.formatted(.number.precision(.fractionLength(currency.decimals)))
  }

  static func + (lhs: MonetaryAmount, rhs: MonetaryAmount) -> MonetaryAmount {
    MonetaryAmount(cents: lhs.cents + rhs.cents, currency: lhs.currency)
  }

  static func - (lhs: MonetaryAmount, rhs: MonetaryAmount) -> MonetaryAmount {
    MonetaryAmount(cents: lhs.cents - rhs.cents, currency: lhs.currency)
  }

  static prefix func - (amount: MonetaryAmount) -> MonetaryAmount {
    MonetaryAmount(cents: -amount.cents, currency: amount.currency)
  }

  static func += (lhs: inout MonetaryAmount, rhs: MonetaryAmount) {
    lhs = lhs + rhs
  }

  static func -= (lhs: inout MonetaryAmount, rhs: MonetaryAmount) {
    lhs = lhs - rhs
  }

  static func < (lhs: MonetaryAmount, rhs: MonetaryAmount) -> Bool {
    lhs.cents < rhs.cents
  }

  /// Parses a currency string (e.g. "50.23", "$1,234.56") into cents.
  /// Strips non-numeric characters except decimal point, multiplies by 100.
  static func parseCents(from text: String) -> Int {
    let cleaned = text.replacingOccurrences(of: "[^0-9.]", with: "", options: .regularExpression)
    guard let decimal = Decimal(string: cleaned) else { return 0 }
    return Int(truncating: (decimal * 100) as NSNumber)
  }
}
