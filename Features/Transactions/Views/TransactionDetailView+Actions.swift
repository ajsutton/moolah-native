import SwiftUI

// Common fiat instruments available to leg-instrument resolution when the
// instrument registry has not yet loaded (e.g. on first render). Registered
// stocks/crypto are supplied by `knownInstruments` loaded via `.task`.
private let commonFiatInstruments: [Instrument] = [
  "AUD", "CAD", "CHF", "CNY", "EUR", "GBP", "HKD", "INR", "JPY", "KRW",
  "MXN", "NOK", "NZD", "SEK", "SGD", "USD", "ZAR",
].map { Instrument.fiat(code: $0) }

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
    let allKnownInstruments = knownInstruments + commonFiatInstruments
    guard
      let updated = draft.toTransaction(
        id: transaction.id,
        accounts: accounts,
        earmarks: earmarks,
        availableInstruments: allKnownInstruments)
    else { return }
    onUpdate(updated)
  }
}
