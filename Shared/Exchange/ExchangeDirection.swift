import Foundation

/// Credit/debit sign for an imported leg. A closed enum (not a bare Int)
/// so an unrecognised provider value is a compile-time impossibility, not
/// a silent zero-quantity leg.
enum ExchangeDirection: Sendable, Hashable {
  case credit
  case debit

  /// Sign multiplier for `Decimal` quantity math — keeps business-logic call
  /// sites readable (`direction.multiplier * amount`).
  var multiplier: Decimal {
    switch self {
    case .credit: return 1
    case .debit: return -1
    }
  }
}
