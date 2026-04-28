import Foundation

// Structural shape queries for `Transaction`. Kept here to keep
// `Transaction.swift` itself under the file_length threshold.
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
}
