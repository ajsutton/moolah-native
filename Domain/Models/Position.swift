import Foundation

/// A computed position for a specific instrument within an account.
/// Derived from leg aggregation -- not persisted.
struct Position: Hashable, Sendable {
  let accountId: UUID
  let instrument: Instrument
  let quantity: Decimal

  /// The quantity as an InstrumentAmount.
  var amount: InstrumentAmount {
    InstrumentAmount(quantity: quantity, instrument: instrument)
  }

  /// Compute positions for a given account from a flat list of legs.
  /// Groups by instrument, sums quantities, excludes zero-quantity results.
  static func compute(for accountId: UUID, from legs: [TransactionLeg]) -> [Position] {
    var totals: [Instrument: Decimal] = [:]
    for leg in legs where leg.accountId == accountId {
      totals[leg.instrument, default: 0] += leg.quantity
    }
    return totals.compactMap { instrument, quantity in
      guard quantity != 0 else { return nil }
      return Position(accountId: accountId, instrument: instrument, quantity: quantity)
    }.sorted { $0.instrument.id < $1.instrument.id }
  }
}
