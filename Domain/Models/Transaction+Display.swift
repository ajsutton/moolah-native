import Foundation

extension Array where Element: Hashable {
  /// Returns elements in order of first appearance, removing duplicates.
  func uniqued() -> [Element] {
    var seen = Set<Element>()
    return filter { seen.insert($0).inserted }
  }
}

// MARK: - Display Helpers

extension Transaction {
  /// Builds a display label for the transaction, handling transfers, earmarks, and payees.
  /// - Parameters:
  ///   - viewingAccountId: The account the user is viewing from (nil for scheduled/unfiltered views).
  ///   - accounts: Account lookup collection.
  ///   - earmarks: Earmark lookup collection.
  /// - Returns: A human-readable label for the transaction.
  func displayPayee(
    viewingAccountId: UUID?, accounts: Accounts, earmarks: Earmarks
  ) -> String {
    if isTransfer {
      if isSimple, let viewingAccountId,
        let otherLeg = legs.first(where: { $0.accountId != viewingAccountId })
      {
        // Account-scoped view: show direction relative to the viewer
        let otherAccountName =
          otherLeg.accountId.flatMap { accounts.by(id: $0) }?.name ?? "Unknown Account"
        let viewingLeg = legs.first(where: { $0.accountId == viewingAccountId })
        let isOutgoing = (viewingLeg?.quantity ?? 0) < 0
        let transferLabel =
          isOutgoing
          ? "Transfer to \(otherAccountName)"
          : "Transfer from \(otherAccountName)"

        if let payee, !payee.isEmpty {
          return "\(payee) (\(transferLabel))"
        }
        return transferLabel
      }

      // No account context (scheduled/upcoming): show "Transfer from A to B"
      let fromAccount = legs.first(where: { $0.quantity < 0 })?.accountId
      let toAccount = legs.first(where: { $0.quantity > 0 })?.accountId
      let fromName = fromAccount.flatMap { accounts.by(id: $0)?.name } ?? "Unknown"
      let toName = toAccount.flatMap { accounts.by(id: $0)?.name } ?? "Unknown"
      return "Transfer from \(fromName) to \(toName)"
    }

    if !isSimple {
      if let payee, !payee.isEmpty {
        return "\(payee) (\(legs.count) sub-transactions)"
      }
      return "\(legs.count) sub-transactions"
    }

    if let payee, !payee.isEmpty {
      return payee
    }

    let earmarkIds = legs.compactMap(\.earmarkId).uniqued()
    let earmarkNames = earmarkIds.compactMap { earmarks.by(id: $0)?.name }
    if !earmarkNames.isEmpty {
      return "Earmark funds for \(earmarkNames.joined(separator: ", "))"
    }

    return ""
  }
}

// MARK: - Trade Title

extension Transaction {
  /// The action sentence for a `.trade`-shaped transaction row title.
  /// Returns `nil` for non-trade transactions. See design §4.3.
  ///
  /// `scopeReference` is the row's reference instrument: the account's
  /// instrument when account-scoped, the earmark's instrument when
  /// earmark-scoped, otherwise the profile currency.
  func tradeTitleSentence(scopeReference: Instrument) -> String? {
    guard isTrade else { return nil }
    let tradeLegs = legs.filter { $0.type == .trade }
    guard tradeLegs.count == 2 else { return nil }
    let (legA, legB) = (tradeLegs[0], tradeLegs[1])

    let aMatches = legA.instrument == scopeReference
    let bMatches = legB.instrument == scopeReference
    if aMatches != bMatches {
      let matching = aMatches ? legA : legB
      let other = aMatches ? legB : legA
      let verb = matching.quantity < 0 ? "Bought" : "Sold"
      return "\(verb) \(formatLegMagnitude(other))"
    }
    // Neither matches, or both match — render Paid → Received.
    let paid = legA.quantity < 0 ? legA : legB
    let received = legA.quantity < 0 ? legB : legA
    return "Swapped \(formatLegMagnitude(paid)) for \(formatLegMagnitude(received))"
  }

  /// Formats the absolute magnitude of `leg` as a positive
  /// `InstrumentAmount.formatted` — locale-currency symbol for fiat,
  /// `"{number} {ticker}"` for stocks and crypto — for use in trade title
  /// sentences. `abs()` here produces a *display* magnitude only; the stored
  /// sign is not modified.
  private func formatLegMagnitude(_ leg: TransactionLeg) -> String {
    InstrumentAmount(quantity: abs(leg.quantity), instrument: leg.instrument).formatted
  }
}
