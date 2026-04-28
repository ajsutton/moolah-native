import SwiftUI

/// Form-level overlay that draws the simple-mode category dropdown anchored
/// to the field reported via `CategoryPickerAnchorKey`. Shares
/// `CategoryAutocompleteState` with `TransactionDetailCategorySection`.
struct TransactionDetailCategoryOverlay: View {
  let anchor: Anchor<CGRect>?
  @Binding var draft: TransactionDraft
  let categories: Categories
  @Binding var state: CategoryAutocompleteState

  private var visibleSuggestions: [CategorySuggestion] {
    state.visibleSuggestions(for: draft.categoryText, in: categories)
  }

  var body: some View {
    if state.showSuggestions, !visibleSuggestions.isEmpty, let anchor {
      GeometryReader { proxy in
        let rect = proxy[anchor]
        CategorySuggestionDropdown(
          suggestions: visibleSuggestions,
          searchText: draft.categoryText,
          highlightedIndex: $state.highlightedIndex,
          onSelect: select(_:),
          identifier: UITestIdentifiers.Autocomplete.category,
          rowIdentifier: UITestIdentifiers.Autocomplete.categorySuggestion(_:)
        )
        .frame(width: rect.width)
        .offset(x: rect.minX, y: rect.maxY + 4)
      }
    }
  }

  private func select(_ selected: CategorySuggestion) {
    state.dismiss()
    draft.commitCategorySelection(id: selected.id, path: selected.path)
  }
}
