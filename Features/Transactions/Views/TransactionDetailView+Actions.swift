import SwiftUI

// MARK: - Actions

extension TransactionDetailView {
  func autofillFromPayee(_ selectedPayee: String) {
    // Only auto-copy amount/type/category from a past transaction when
    // the user is filling in a fresh draft. Editing an existing
    // transaction's payee must never rewrite other fields — do not
    // remove this guard without replacing the invariant it enforces.
    guard openedAsNewTransaction else { return }
    Task {
      guard
        let match = await transactionStore.payeeSuggestionSource.fetchTransactionForAutofill(
          payee: selectedPayee)
      else { return }
      draft.applyAutofill(from: match, categories: categories, accounts: accounts)
    }
  }

  func debouncedSave() {
    transactionStore.debouncedSave { [self] in
      saveIfValid()
    }
  }

  func saveIfValid() {
    guard
      let updated = draft.toTransaction(
        id: transaction.id,
        accounts: accounts,
        earmarks: earmarks)
    else { return }
    onUpdate(updated)
  }
}
