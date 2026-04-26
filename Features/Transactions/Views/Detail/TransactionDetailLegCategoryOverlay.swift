import SwiftUI

/// Form-level overlay that draws *the* leg-category dropdown — at most
/// one is visible at any moment, since the user can only have one leg
/// field focused. Iterates the per-leg `legStates` to find the active
/// leg, then renders its dropdown anchored to the leg's reported anchor.
struct TransactionDetailLegCategoryOverlay: View {
  let anchors: [Int: Anchor<CGRect>]
  @Binding var draft: TransactionDraft
  let categories: Categories
  @Binding var legStates: [Int: CategoryAutocompleteState]

  var body: some View {
    if let activeIndex, let anchor = anchors[activeIndex] {
      GeometryReader { proxy in
        let rect = proxy[anchor]
        CategorySuggestionDropdown(
          suggestions: suggestions(for: activeIndex),
          searchText: draft.legDrafts[activeIndex].categoryText,
          highlightedIndex: highlightedIndexBinding(for: activeIndex),
          onSelect: { selected in select(selected, at: activeIndex) },
          identifier: UITestIdentifiers.Autocomplete.legCategory(activeIndex),
          rowIdentifier: { rowIndex in
            UITestIdentifiers.Autocomplete.legCategorySuggestion(activeIndex, rowIndex)
          }
        )
        .frame(width: rect.width)
        .offset(x: rect.minX, y: rect.maxY + 4)
      }
    }
  }

  private var activeIndex: Int? {
    anchors.keys.sorted().first { index in
      legStates[index]?.showSuggestions == true
        && !suggestions(for: index).isEmpty
    }
  }

  private func suggestions(for index: Int) -> [CategorySuggestion] {
    let state = legStates[index] ?? CategoryAutocompleteState()
    return state.visibleSuggestions(
      for: draft.legDrafts[index].categoryText, in: categories)
  }

  private func highlightedIndexBinding(for index: Int) -> Binding<Int?> {
    Binding(
      get: { legStates[index]?.highlightedIndex },
      set: { newValue in
        var state = legStates[index] ?? CategoryAutocompleteState()
        state.highlightedIndex = newValue
        legStates[index] = state
      }
    )
  }

  private func select(_ selected: CategorySuggestion, at index: Int) {
    var state = legStates[index] ?? CategoryAutocompleteState()
    state.dismiss()
    legStates[index] = state
    draft.legDrafts[index].categoryId = selected.id
    draft.legDrafts[index].categoryText = selected.path
  }
}
