import Foundation

/// Credit/debit sign for an imported leg. A closed enum (not a bare Int)
/// so an unrecognised provider value is a compile-time impossibility, not
/// a silent zero-quantity leg.
enum ExchangeDirection: Int, Sendable, Hashable {
  case credit = 1
  case debit = -1

  /// Sign multiplier for `Decimal` quantity math — keeps the `Int` backing
  /// out of business-logic call sites (`direction.multiplier * amount`).
  var multiplier: Decimal {
    switch self {
    case .credit: return 1
    case .debit: return -1
    }
  }
}
