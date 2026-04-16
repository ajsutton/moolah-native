import Foundation

/// A computed position for a specific instrument within an account or earmark.
/// Derived from leg aggregation -- not persisted.
struct Position: Hashable, Sendable {
  let instrument: Instrument
  let quantity: Decimal

  /// The quantity as an InstrumentAmount.
  var amount: InstrumentAmount {
    InstrumentAmount(quantity: quantity, instrument: instrument)
  }

  /// Compute positions for a given account from a flat list of legs.
  /// Groups by instrument, sums quantities, excludes zero-quantity results.
  static func computeForAccount(_ accountId: UUID, from legs: [TransactionLeg]) -> [Position] {
    computePositions(from: legs.filter { $0.accountId == accountId })
  }

  /// Compute positions for a given earmark from a flat list of legs.
  /// Groups by instrument, sums quantities, excludes zero-quantity results.
  static func computeForEarmark(_ earmarkId: UUID, from legs: [TransactionLeg]) -> [Position] {
    computePositions(from: legs.filter { $0.earmarkId == earmarkId })
  }

  /// Shared implementation: aggregate filtered legs into positions.
  private static func computePositions(from legs: [TransactionLeg]) -> [Position] {
    var totals: [Instrument: Decimal] = [:]
    for leg in legs {
      totals[leg.instrument, default: 0] += leg.quantity
    }
    return totals.compactMap { instrument, quantity in
      guard quantity != 0 else { return nil }
      return Position(instrument: instrument, quantity: quantity)
    }.sorted { $0.instrument.id < $1.instrument.id }
  }
}
