import Foundation

// Structural shape queries and display-amount computation for `Transaction`.
// Kept here to keep `Transaction.swift` itself under the file_length threshold.
extension Transaction {
  /// Whether this transaction has the structural shape of a trade per
  /// `plans/2026-04-28-trade-transaction-ui-design.md` §1.2:
  /// exactly two `.trade` legs (no category, no earmark) plus zero or
  /// more `.expense` fee legs (which may have a category and/or earmark),
  /// all on the same non-nil account. Sign and instrument of the
  /// `.trade` legs are unrestricted.
  var isTrade: Bool {
    let tradeLegs = legs.filter { $0.type == .trade }
    guard tradeLegs.count == 2 else { return false }
    guard tradeLegs.allSatisfy({ $0.categoryId == nil && $0.earmarkId == nil })
    else { return false }
    let extraLegs = legs.filter { $0.type != .trade }
    guard extraLegs.allSatisfy({ $0.type == .expense }) else { return false }
    guard !legs.contains(where: { $0.accountId == nil }) else { return false }
    return accountIds.count == 1
  }

  /// Returns one entry per distinct native instrument for the legs that match
  /// the row's scope (account, earmark, or all legs). Zero-net entries are
  /// dropped. When every per-instrument net is zero (e.g. a same-currency
  /// transfer whose legs cancel), falls back to the negative-quantity transfer
  /// leg(s) so the row still shows something sensible — preserving existing
  /// behaviour for unfiltered transfers (design §4.2).
  static func computeDisplayAmounts(
    for transaction: Transaction,
    accountId: UUID?,
    earmarkId: UUID?
  ) -> [InstrumentAmount] {
    let scopedLegs: [TransactionLeg]
    if let accountId {
      scopedLegs = transaction.legs.filter { $0.accountId == accountId }
    } else if let earmarkId {
      scopedLegs = transaction.legs.filter { $0.earmarkId == earmarkId }
    } else {
      scopedLegs = transaction.legs
    }

    // Sum per instrument, preserving first-seen order for stable rendering.
    var order: [Instrument] = []
    var sums: [Instrument: Decimal] = [:]
    for leg in scopedLegs {
      if sums[leg.instrument] == nil { order.append(leg.instrument) }
      sums[leg.instrument, default: 0] += leg.quantity
    }
    let nonZero = order.compactMap { instrument -> InstrumentAmount? in
      guard let qty = sums[instrument], qty != 0 else { return nil }
      return InstrumentAmount(quantity: qty, instrument: instrument)
    }
    if !nonZero.isEmpty { return nonZero }

    // Zero-sum fallback: surface the negative-quantity transfer leg(s).
    let negatives = scopedLegs.filter { $0.type == .transfer && $0.quantity < 0 }
    return negatives.map(\.amount)
  }
}
