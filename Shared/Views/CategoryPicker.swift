import SwiftUI

/// Preference key for positioning the category dropdown relative to the text field.
struct CategoryPickerAnchorKey: PreferenceKey {
  static let defaultValue: Anchor<CGRect>? = nil
  static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
    value = value ?? nextValue()
  }
}

/// Identifiable wrapper for a category suggestion in the dropdown.
struct CategorySuggestion: Identifiable {
  let id: UUID
  let path: String
}

/// A category autocomplete field using the same pattern as PayeeAutocompleteField.
///
/// The text field shows the selected category path. Typing filters suggestions.
/// The parent view owns `showSuggestions` and `highlightedIndex` state and wires
/// the dropdown overlay on the Form.
struct CategoryAutocompleteField: View {
  @Binding var text: String
  @Binding var highlightedIndex: Int?
  let suggestionCount: Int
  let onTextChange: (String) -> Void
  let onAcceptHighlighted: () -> Void

  var body: some View {
    AutocompleteField(
      placeholder: "Category",
      text: $text,
      highlightedIndex: $highlightedIndex,
      suggestionCount: suggestionCount,
      onTextChange: onTextChange,
      onAcceptHighlighted: onAcceptHighlighted
    )
    .anchorPreference(key: CategoryPickerAnchorKey.self, value: .bounds) { $0 }
  }
}

/// The floating dropdown for category suggestions — mirrors PayeeSuggestionDropdown.
struct CategorySuggestionDropdown: View {
  let suggestions: [CategorySuggestion]
  let searchText: String
  @Binding var highlightedIndex: Int?
  let onSelect: (CategorySuggestion) -> Void

  var body: some View {
    AutocompleteSuggestionDropdown(
      items: suggestions,
      searchText: searchText,
      label: { $0.path },
      highlightedIndex: $highlightedIndex,
      onSelect: { onSelect($0) }
    )
  }
}
