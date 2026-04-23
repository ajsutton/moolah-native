import Foundation

extension TransactionDraft {
  /// Replace this draft with data from a matching transaction, preserving the current date.
  /// Category text is populated from the categories collection.
  ///
  /// When the draft has a `viewingAccountId` (autofill was triggered while the
  /// user was scoped to a specific account list), the relevant leg is pinned to
  /// the viewed account so a past transaction from a different account can't
  /// silently move the new transaction out of the list the user is working in.
  /// Pass `accounts` to also realign the leg's instrument with the viewed
  /// account's instrument.
  mutating func applyAutofill(
    from match: Transaction,
    categories: Categories,
    accounts: Accounts = Accounts(from: [])
  ) {
    let preservedDate = self.date
    let preservedViewingAccountId = self.viewingAccountId

    // Build a fresh draft from the match
    var newDraft = TransactionDraft(
      from: match, viewingAccountId: preservedViewingAccountId, accounts: accounts)
    newDraft.date = preservedDate

    // Populate category text for all legs
    for i in newDraft.legDrafts.indices {
      if let catId = newDraft.legDrafts[i].categoryId,
        let cat = categories.by(id: catId)
      {
        newDraft.legDrafts[i].categoryText = categories.path(for: cat)
      }
    }

    // Preserve the viewed account. Skip custom mode: a complex match has no
    // single "viewed" leg, and adopting its structure means the user is
    // already accepting whatever accounts it references.
    if let viewingId = preservedViewingAccountId, !newDraft.isCustom {
      let idx = newDraft.relevantLegIndex
      if newDraft.legDrafts[idx].accountId != viewingId {
        newDraft.legDrafts[idx].accountId = viewingId
        if let viewedAccount = accounts.by(id: viewingId) {
          newDraft.legDrafts[idx].instrumentId = viewedAccount.instrument.id
        }
      }
    }

    self = newDraft
  }
}
