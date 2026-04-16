import Foundation

/// Position deltas keyed by entity ID and instrument.
typealias PositionDeltas = [UUID: [Instrument: Decimal]]

/// The net balance changes resulting from a transaction create, update, or delete.
struct BalanceDelta: Equatable, Sendable {
  let accountDeltas: PositionDeltas
  let earmarkDeltas: PositionDeltas
  /// Per-earmark saved amounts (income + openingBalance legs).
  let earmarkSavedDeltas: PositionDeltas
  /// Per-earmark spent amounts (expense + transfer legs).
  let earmarkSpentDeltas: PositionDeltas

  static let empty = BalanceDelta(
    accountDeltas: [:], earmarkDeltas: [:], earmarkSavedDeltas: [:], earmarkSpentDeltas: [:])

  var isEmpty: Bool {
    accountDeltas.isEmpty && earmarkDeltas.isEmpty && earmarkSavedDeltas.isEmpty
      && earmarkSpentDeltas.isEmpty
  }
}

/// Computes all balance deltas from a transaction create, update, or delete in a single pass.
///
/// - `deltas(old: nil, new: tx)` — transaction created
/// - `deltas(old: tx, new: nil)` — transaction deleted
/// - `deltas(old: oldTx, new: newTx)` — transaction updated
/// - `deltas(old: nil, new: nil)` — no-op, returns `.empty`
enum BalanceDeltaCalculator {

  static func deltas(old: Transaction?, new: Transaction?) -> BalanceDelta {
    var accountDeltas: [UUID: [Instrument: Decimal]] = [:]
    var earmarkDeltas: [UUID: [Instrument: Decimal]] = [:]
    var earmarkSavedDeltas: [UUID: [Instrument: Decimal]] = [:]
    var earmarkSpentDeltas: [UUID: [Instrument: Decimal]] = [:]

    // Reverse old legs (skip scheduled transactions)
    if let old, !old.isScheduled {
      for leg in old.legs {
        applyLeg(
          leg,
          sign: -1,
          accountDeltas: &accountDeltas,
          earmarkDeltas: &earmarkDeltas,
          earmarkSavedDeltas: &earmarkSavedDeltas,
          earmarkSpentDeltas: &earmarkSpentDeltas
        )
      }
    }

    // Apply new legs (skip scheduled transactions)
    if let new, !new.isScheduled {
      for leg in new.legs {
        applyLeg(
          leg,
          sign: 1,
          accountDeltas: &accountDeltas,
          earmarkDeltas: &earmarkDeltas,
          earmarkSavedDeltas: &earmarkSavedDeltas,
          earmarkSpentDeltas: &earmarkSpentDeltas
        )
      }
    }

    // Clean up zero entries
    cleanZeros(&accountDeltas)
    cleanZeros(&earmarkDeltas)
    cleanZeros(&earmarkSavedDeltas)
    cleanZeros(&earmarkSpentDeltas)

    return BalanceDelta(
      accountDeltas: accountDeltas,
      earmarkDeltas: earmarkDeltas,
      earmarkSavedDeltas: earmarkSavedDeltas,
      earmarkSpentDeltas: earmarkSpentDeltas
    )
  }

  // MARK: - Private

  private static func applyLeg(
    _ leg: TransactionLeg,
    sign: Decimal,
    accountDeltas: inout [UUID: [Instrument: Decimal]],
    earmarkDeltas: inout [UUID: [Instrument: Decimal]],
    earmarkSavedDeltas: inout [UUID: [Instrument: Decimal]],
    earmarkSpentDeltas: inout [UUID: [Instrument: Decimal]]
  ) {
    let quantity = leg.quantity

    if let accountId = leg.accountId {
      accountDeltas[accountId, default: [:]][leg.instrument, default: 0] += sign * quantity
    }

    if let earmarkId = leg.earmarkId {
      earmarkDeltas[earmarkId, default: [:]][leg.instrument, default: 0] += sign * quantity

      switch leg.type {
      case .income, .openingBalance:
        // Saved delta tracks the change to the saved total.
        // Income/openingBalance quantities are positive, so sign * quantity gives the right direction.
        earmarkSavedDeltas[earmarkId, default: [:]][leg.instrument, default: 0] += sign * quantity

      case .expense, .transfer:
        // Spent delta tracks the change to the spent total.
        // Expense/transfer quantities are negative (outflows), so we use abs to get the positive
        // spent amount, then apply sign for add/reverse direction.
        earmarkSpentDeltas[earmarkId, default: [:]][leg.instrument, default: 0] +=
          sign
          * abs(
            quantity)
      }
    }
  }

  private static func cleanZeros(_ deltas: inout [UUID: [Instrument: Decimal]]) {
    for (entityId, instruments) in deltas {
      var cleaned = instruments
      for (instrument, value) in cleaned where value == 0 {
        cleaned.removeValue(forKey: instrument)
      }
      if cleaned.isEmpty {
        deltas.removeValue(forKey: entityId)
      } else {
        deltas[entityId] = cleaned
      }
    }
  }
}
