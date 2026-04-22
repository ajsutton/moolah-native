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
