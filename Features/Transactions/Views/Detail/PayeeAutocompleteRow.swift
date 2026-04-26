import SwiftUI

/// The payee text field with autocomplete callbacks wired to a shared
/// `PayeeAutocompleteState`. The matching dropdown is rendered by
/// `PayeeAutocompleteOverlay` at the form level.
struct PayeeAutocompleteRow: View {
  @Binding var payee: String
  @Binding var state: PayeeAutocompleteState
  let suggestionSource: PayeeSuggestionSource
  let onAutofill: (String) -> Void

  var body: some View {
    PayeeAutocompleteField(
      text: $payee,
      highlightedIndex: $state.highlightedIndex,
      suggestionCount: state.visibleSuggestions(from: suggestionSource.suggestions).count,
      onTextChange: handleTextChange,
      onAcceptHighlighted: acceptHighlighted
    )
    .accessibilityIdentifier(UITestIdentifiers.Detail.payee)
  }

  private func handleTextChange(_ newValue: String) {
    if state.justSelected {
      state.justSelected = false
    } else {
      state.showSuggestions = !newValue.isEmpty
      suggestionSource.fetch(prefix: newValue)
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
