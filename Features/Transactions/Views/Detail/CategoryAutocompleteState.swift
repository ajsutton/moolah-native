import SwiftUI

/// Bundled state for the simple-mode category autocomplete dropdown.
/// Shared between `TransactionDetailCategorySection` (the field row) and
/// `TransactionDetailCategoryOverlay` (the floating dropdown).
struct CategoryAutocompleteState: Equatable {
  /// `true` while the dropdown should render (subject to having
  /// suggestions to show).
  var showSuggestions: Bool = false
  /// Index of the visible suggestion that ↑/↓ have moved through and that
  /// `Enter` will accept. `nil` means nothing is highlighted yet.
  var highlightedIndex: Int?
  /// Set when a suggestion is accepted so the resulting binding-driven
  /// `onTextChange` does not immediately re-open the dropdown.
  var justSelected: Bool = false
}

extension CategoryAutocompleteState {
  /// Closes the dropdown and arms `justSelected` so the next
  /// binding-driven `onTextChange` (caused by us writing the accepted
  /// path back into the field, or by the blur handler normalising stray
  /// text against the canonical path) does not immediately re-open the
  /// picker.
  mutating func dismiss() {
    justSelected = true
    showSuggestions = false
    highlightedIndex = nil
  }

  /// Closes the dropdown without arming `justSelected`. Used when the user
  /// dismisses the picker without changing the field text — Escape — so
  /// the next character they type is still recognised as user-driven
  /// editing and re-opens the dropdown.
  mutating func cancel() {
    showSuggestions = false
    highlightedIndex = nil
  }

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
}
