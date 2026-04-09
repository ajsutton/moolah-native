@testable import Moolah

extension Currency {
  /// Default currency for test fixtures. Production code should get currency
  /// from the backend, which stamps it on all MonetaryAmount values.
  static let defaultTestCurrency: Currency = .AUD
}
