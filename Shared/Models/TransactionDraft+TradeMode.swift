import Foundation

// MARK: - Computed Accessors (Trade Mode)

extension TransactionDraft {
  /// Index of the first `.trade` leg (the "Paid" side). `nil` when the
  /// draft is not in trade shape.
  var paidLegIndex: Int? {
    legDrafts.firstIndex { $0.type == .trade }
  }

  /// Index of the second `.trade` leg (the "Received" side). `nil` when
  /// the draft does not have two `.trade` legs.
  var receivedLegIndex: Int? {
    let trade = legDrafts.enumerated().filter { $0.element.type == .trade }
    return trade.count == 2 ? trade[1].offset : nil
  }

  /// Indices of all `.expense` fee legs, in storage order.
  var feeIndices: [Int] {
    legDrafts.enumerated().compactMap { $0.element.type == .expense ? $0.offset : nil }
  }
}

// MARK: - Editing Methods (Trade Mode)

extension TransactionDraft {
  /// Append a new fee leg defaulting to amount `0` in the supplied
  /// instrument and the current trade account.
  mutating func appendFee(defaultInstrumentId: String) {
    legDrafts.append(
      LegDraft(
        type: .expense,
        accountId: paidLegIndex.flatMap { legDrafts[$0].accountId },
        amountText: "0",
        categoryId: nil,
        categoryText: "",
        earmarkId: nil,
        instrumentId: defaultInstrumentId
      ))
  }

  /// Remove the fee leg at the absolute draft index. No-op if the index
  /// is out of bounds or the leg is not `.expense`.
  mutating func removeFee(at index: Int) {
    guard legDrafts.indices.contains(index),
      legDrafts[index].type == .expense
    else { return }
    legDrafts.remove(at: index)
  }
}
