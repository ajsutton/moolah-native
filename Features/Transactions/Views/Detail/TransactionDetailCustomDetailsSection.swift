import SwiftUI

/// Custom-mode (multi-leg) details section: just the payee field and the
/// date. Per-leg account/amount/category fields live in the leg-row
/// subviews.
struct TransactionDetailCustomDetailsSection: View {
  @Binding var draft: TransactionDraft
  let suggestionSource: PayeeSuggestionSource
  let editingTransactionId: UUID?
  @Binding var payeeState: PayeeAutocompleteState
  let onAutofill: (String) -> Void
  @FocusState.Binding var focusedField: TransactionDetailFocus?

  var body: some View {
    Section {
      PayeeAutocompleteRow(
        payee: $draft.payee,
        state: $payeeState,
        suggestionSource: suggestionSource,
        editingTransactionId: editingTransactionId,
        onAutofill: onAutofill
      )
      .focused($focusedField, equals: .payee)

      DatePicker("Date", selection: $draft.date, displayedComponents: .date)
    }
  }
}
