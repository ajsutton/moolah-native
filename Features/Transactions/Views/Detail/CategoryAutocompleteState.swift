import SwiftUI

/// Bundled state for the simple-mode category autocomplete dropdown.
/// Shared between `TransactionDetailCategorySection` (the field row) and
/// `TransactionDetailCategoryOverlay` (the floating dropdown). Conforms
/// to `AutocompleteDropdownState`, which supplies `dismiss()` and
/// `cancel()`.
struct CategoryAutocompleteState: AutocompleteDropdownState {
  var showSuggestions: Bool = false
  var highlightedIndex: Int?
  var justSelected: Bool = false
}

extension CategoryAutocompleteState {
  /// Visible category suggestions for the current `query`. Returns up to
  /// 8 entries to match the dropdown's render budget; an empty/whitespace
  /// query returns the full (capped) list so users can browse without
  /// typing. Returns an empty array when the dropdown is hidden, so call
  /// sites can drive both visibility and content from one accessor.
  func visibleSuggestions(
    for query: String, in categories: Categories
  ) -> [CategorySuggestion] {
    guard showSuggestions else { return [] }
    let allEntries = categories.flattenedByPath()
    let filtered: [Categories.FlatEntry]
    if query.trimmingCharacters(in: .whitespaces).isEmpty {
      filtered = allEntries
    } else {
      filtered = allEntries.filter { matchesCategorySearch($0.path, query: query) }
    }
    return filtered.prefix(8).map { CategorySuggestion(id: $0.category.id, path: $0.path) }
  }

  /// The `CategorySuggestion` the user has arrow-keyed to, or `nil` if
  /// nothing is highlighted, the dropdown is hidden, or the index has
  /// drifted out of bounds. Lets blur handlers commit the highlight in
  /// one call without re-doing the index-bounds check at the call site.
  func highlightedSuggestion(
    for query: String, in categories: Categories
  ) -> CategorySuggestion? {
    let visible = visibleSuggestions(for: query, in: categories)
    guard let index = highlightedIndex, visible.indices.contains(index) else {
      return nil
    }
    return visible[index]
  }
}
