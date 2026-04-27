import SwiftUI

/// Bundled state for the payee autocomplete dropdown — shared between the
/// in-section field row and the form-level overlay.
struct PayeeAutocompleteState: Equatable {
  /// `true` while the dropdown should be considered visible (subject to
  /// other gates: a non-empty payee and at least one suggestion in the
  /// source).
  var showSuggestions: Bool = false
  /// Index of the visible suggestion that ↑/↓ have moved through and that
  /// `Enter` will accept. `nil` means nothing is highlighted yet.
  var highlightedIndex: Int?
  /// Mirrors the legacy `payeeJustSelected` flag — set when a suggestion
  /// is accepted so the resulting binding-driven `onTextChange` does not
  /// immediately re-open the dropdown and re-trigger a prefix fetch.
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

  /// Closes the dropdown and arms `justSelected` so the next
  /// binding-driven `onTextChange` (caused by us writing the accepted
  /// payee back into the field) does not immediately re-open the picker
  /// and re-fetch suggestions.
  mutating func dismiss() {
    justSelected = true
    showSuggestions = false
    highlightedIndex = nil
  }

  /// Closes the dropdown without arming `justSelected`. Used when the user
  /// dismisses the picker without changing the field text — Escape, or
  /// moving focus away — so the next character they type is still
  /// recognised as user-driven editing and re-opens the dropdown.
  mutating func cancel() {
    showSuggestions = false
    highlightedIndex = nil
  }
}
