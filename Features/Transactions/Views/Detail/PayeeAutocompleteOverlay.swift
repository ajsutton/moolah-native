import SwiftUI

/// Form-level overlay that draws the payee suggestion dropdown anchored
/// to the field reported via `PayeeFieldAnchorKey`. Shares
/// `PayeeAutocompleteState` with `PayeeAutocompleteRow` so accepting a
/// suggestion in the dropdown clears the same flags the field consults.
struct PayeeAutocompleteOverlay: View {
  let anchor: Anchor<CGRect>?
  @Binding var payee: String
  @Binding var state: PayeeAutocompleteState
  let suggestionSource: PayeeSuggestionSource
  let onAutofill: (String) -> Void

  var body: some View {
    if state.showSuggestions, !payee.isEmpty,
      !suggestionSource.suggestions.isEmpty, let anchor
    {
      GeometryReader { proxy in
        let rect = proxy[anchor]
        PayeeSuggestionDropdown(
          suggestions: suggestionSource.suggestions,
          searchText: payee,
          highlightedIndex: $state.highlightedIndex,
          onSelect: accept(suggestion:)
        )
        .frame(width: rect.width)
        .offset(x: rect.minX, y: rect.maxY + 4)
      }
    }
  }

  private func accept(suggestion: String) {
    state.dismiss()
    payee = suggestion
    suggestionSource.clear()
    onAutofill(suggestion)
  }
}
