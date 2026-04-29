import SwiftUI

/// The payee text field with autocomplete callbacks wired to a shared
/// `PayeeAutocompleteState`. The matching dropdown is rendered by
/// `PayeeAutocompleteOverlay` at the form level.
///
/// Owns a private `@FocusState` so it can dismiss the dropdown without
/// clearing the field text when the user moves focus away (Tab, click
/// elsewhere). Per #510, the typed text must be preserved on focus loss
/// — only `Enter` / clicking a suggestion should replace it.
struct PayeeAutocompleteRow: View {
  @Binding var payee: String
  @Binding var state: PayeeAutocompleteState
  let suggestionSource: PayeeSuggestionSource
  /// Id of the transaction the field is editing; forwarded to the
  /// suggestion source so the row's own payee is dropped from the
  /// frequency count and the visible list (#538). `nil` for fresh /
  /// unsaved drafts where no row exists in the repo yet.
  let editingTransactionId: UUID?
  let onAutofill: (String) -> Void

  @FocusState private var fieldFocused: Bool

  var body: some View {
    PayeeAutocompleteField(
      text: $payee,
      highlightedIndex: $state.highlightedIndex,
      suggestionCount: state.visibleSuggestions(from: suggestionSource.suggestions).count,
      onTextChange: handleTextChange,
      onAcceptHighlighted: acceptHighlighted,
      onCancel: { state.cancel() }
    )
    .focused($fieldFocused)
    .accessibilityIdentifier(UITestIdentifiers.Detail.payee)
    .onChange(of: fieldFocused) { _, focused in
      if !focused { state.cancel() }
    }
  }

  private func handleTextChange(_ newValue: String) {
    if state.justSelected {
      state.justSelected = false
    } else {
      state.showSuggestions = !newValue.isEmpty
      suggestionSource.fetch(
        prefix: newValue, excludingTransactionId: editingTransactionId)
    }
  }

  private func acceptHighlighted() {
    let visible = state.visibleSuggestions(from: suggestionSource.suggestions)
    guard let index = state.highlightedIndex, index < visible.count else { return }
    accept(suggestion: visible[index])
  }

  private func accept(suggestion: String) {
    state.dismiss()
    payee = suggestion
    suggestionSource.clear()
    onAutofill(suggestion)
  }
}
