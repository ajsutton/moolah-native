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

// MARK: - Mode Switching (Forward → Trade)

extension TransactionDraft {
  /// Whether the current draft can transition to trade mode without
  /// losing data semantically. True when the existing legs already match
  /// the trade-shape rule (custom → trade) **or** when the draft is
  /// simple income / expense / transfer with at least one accounted leg.
  func canSwitchToTrade(accounts: Accounts) -> Bool {
    if isCustom {
      // Already-trade-shaped legs: 2 .trade + 0+ .expense, all on one
      // account, no category/earmark on .trade legs.
      let tradeCount = legDrafts.filter { $0.type == .trade }.count
      let nonTrade = legDrafts.filter { $0.type != .trade }
      let accountSet = Set(legDrafts.compactMap(\.accountId))
      return tradeCount == 2
        && nonTrade.allSatisfy { $0.type == .expense }
        && accountSet.count == 1
    }
    return relevantLeg.accountId != nil
  }

  /// Convert the draft into trade shape. Mirrors the rules in design §3.3
  /// "Forward". Caller is responsible for ensuring `canSwitchToTrade` is
  /// true; otherwise the result is ill-defined.
  mutating func switchToTrade(accounts: Accounts) {
    if isCustom {
      isCustom = false
      return
    }

    let existing = relevantLeg
    let acct = existing.accountId
    let acctInstrument =
      acct.flatMap { accounts.by(id: $0) }?.instrument.id ?? existing.instrumentId

    let isReceivedFromIncome = (existing.type == .income)
    let received: LegDraft
    let paid: LegDraft

    if isReceivedFromIncome {
      received = LegDraft(
        type: .trade,
        accountId: acct,
        amountText: existing.amountText,
        categoryId: nil,
        categoryText: "",
        earmarkId: nil,
        instrumentId: existing.instrumentId)
      paid = LegDraft(
        type: .trade,
        accountId: acct,
        amountText: "0",
        categoryId: nil,
        categoryText: "",
        earmarkId: nil,
        instrumentId: acctInstrument)
    } else {
      paid = LegDraft(
        type: .trade,
        accountId: acct,
        amountText: existing.amountText,
        categoryId: nil,
        categoryText: "",
        earmarkId: nil,
        instrumentId: existing.instrumentId)
      received = LegDraft(
        type: .trade,
        accountId: acct,
        amountText: "0",
        categoryId: nil,
        categoryText: "",
        earmarkId: nil,
        instrumentId: acctInstrument)
    }
    // Counterpart legs (transfer) are intentionally discarded here.
    legDrafts = [paid, received]
    relevantLegIndex = 0
    isCustom = false
  }
}
