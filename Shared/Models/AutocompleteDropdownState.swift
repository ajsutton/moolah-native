import Foundation

/// Shared dropdown-visibility state for autocomplete fields. Each
/// suggestion-source-specific type (`PayeeAutocompleteState`,
/// `CategoryAutocompleteState`, ...) conforms so the shared
/// `dismiss()` and `cancel()` semantics live in one place.
protocol AutocompleteDropdownState: Equatable {
  /// `true` while the dropdown should render (subject to the
  /// suggestion-source-specific gates that a non-empty query / non-empty
  /// suggestion list adds).
  var showSuggestions: Bool { get set }
  /// Index of the visible suggestion that ↑/↓ have moved through and
  /// that `Enter`/Tab will accept. `nil` means nothing is highlighted.
  var highlightedIndex: Int? { get set }
  /// Set when a suggestion is accepted so the binding-driven
  /// `onChange(of: text)` that fires as a side effect of writing the
  /// accepted value back into the field doesn't immediately re-open the
  /// dropdown and re-fetch suggestions.
  var justSelected: Bool { get set }
}

extension AutocompleteDropdownState {
  /// Closes the dropdown and arms `justSelected`. Use this from the
  /// suggestion-acceptance path: writing the accepted value back into
  /// the field triggers an `onChange(of: text)` we want to ignore.
  mutating func dismiss() {
    justSelected = true
    showSuggestions = false
    highlightedIndex = nil
  }

  /// Closes the dropdown without arming `justSelected`. Use this when
  /// the user dismisses the picker without changing the field text —
  /// Escape, or moving focus away — so the next character they type is
  /// still recognised as user-driven editing and re-opens the dropdown.
  mutating func cancel() {
    showSuggestions = false
    highlightedIndex = nil
  }
}
