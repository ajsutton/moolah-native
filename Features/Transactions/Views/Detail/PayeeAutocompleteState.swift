import SwiftUI

/// Bundled state for the payee autocomplete dropdown — shared between the
/// in-section field row and the form-level overlay. Conforms to
/// `AutocompleteDropdownState`, which supplies `dismiss()` and `cancel()`.
struct PayeeAutocompleteState: AutocompleteDropdownState {
  var showSuggestions: Bool = false
  var highlightedIndex: Int?
  var justSelected: Bool = false
}

extension PayeeAutocompleteState {
  /// Visible suggestions, capped at 8 to mirror
  /// `PayeeSuggestionDropdown.visibleSuggestions`. Both layers filter the
  /// same source so `Enter` accepts whatever the dropdown highlights.
  func visibleSuggestions(from source: [String]) -> [String] {
    guard showSuggestions else { return [] }
    return Array(source.prefix(8))
  }
}
