import Foundation

struct MonetaryAmount: Codable, Sendable, Hashable, Comparable {
  let cents: Int
  let currency: String

  static let zero = MonetaryAmount(cents: 0, currency: Constants.defaultCurrency)

  init(cents: Int, currency: String = Constants.defaultCurrency) {
    self.cents = cents
    self.currency = currency
  }

  var isPositive: Bool { cents > 0 }
  var isNegative: Bool { cents < 0 }
  var isZero: Bool { cents == 0 }

  /// The amount as a Decimal suitable for currency formatting (e.g. 5023 cents -> 50.23).
  var decimalValue: Decimal {
    Decimal(cents) / 100
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

  static func < (lhs: MonetaryAmount, rhs: MonetaryAmount) -> Bool {
    lhs.cents < rhs.cents
  }
}
