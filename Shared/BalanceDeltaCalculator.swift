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

  /// Project a `PositionBook` into the four delta dicts consumed by stores.
  /// `accountsFromTransfers` is intentionally ignored — it's only used by the
  /// analysis pipeline, never by delta consumers.
  init(from book: PositionBook) {
    self.accountDeltas = book.accounts
    self.earmarkDeltas = book.earmarks
    self.earmarkSavedDeltas = book.earmarksSaved
    self.earmarkSpentDeltas = book.earmarksSpent
  }

  init(
    accountDeltas: PositionDeltas,
    earmarkDeltas: PositionDeltas,
    earmarkSavedDeltas: PositionDeltas,
    earmarkSpentDeltas: PositionDeltas
  ) {
    self.accountDeltas = accountDeltas
    self.earmarkDeltas = earmarkDeltas
    self.earmarkSavedDeltas = earmarkSavedDeltas
    self.earmarkSpentDeltas = earmarkSpentDeltas
  }
}

/// Computes all balance deltas from a transaction create, update, or delete in a single pass.
///
/// - `deltas(old: nil, new: tx)` — transaction created
/// - `deltas(old: tx, new: nil)` — transaction deleted
/// - `deltas(old: oldTx, new: newTx)` — transaction updated
/// - `deltas(old: nil, new: nil)` — no-op, returns `.empty`
///
/// Thin wrapper over `PositionBook`: reverses the old transaction's legs,
/// applies the new transaction's legs, and projects the resulting book into
/// the delta shape. Scheduled transactions are skipped (they don't move money).
enum BalanceDeltaCalculator {

  static func deltas(old: Transaction?, new: Transaction?) -> BalanceDelta {
    var book = PositionBook.empty
    if let old, !old.isScheduled { book.apply(old, sign: -1) }
    if let new, !new.isScheduled { book.apply(new, sign: 1) }
    book.cleanZeros()
    return BalanceDelta(from: book)
  }
}
