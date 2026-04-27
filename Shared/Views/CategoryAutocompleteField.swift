import SwiftUI

/// Preference key for positioning the category dropdown relative to the text field.
struct CategoryPickerAnchorKey: PreferenceKey {
  static let defaultValue: Anchor<CGRect>? = nil

  static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
    value = value ?? nextValue()
  }
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
  let onCancel: () -> Void

  var body: some View {
    AutocompleteField(
      placeholder: "Category",
      text: $text,
      highlightedIndex: $highlightedIndex,
      suggestionCount: suggestionCount,
      onTextChange: onTextChange,
      onAcceptHighlighted: onAcceptHighlighted,
      onCancel: onCancel
    )
    .anchorPreference(key: CategoryPickerAnchorKey.self, value: .bounds) { $0 }
  }
}

/// The floating dropdown for category suggestions — mirrors PayeeSuggestionDropdown.
///
/// `identifier` + `rowIdentifier` are optional so the simple-mode call site
/// (which doesn't need UI-test targeting today) can keep calling the struct
/// without extra arguments. The multi-leg call site passes both so each
/// leg's dropdown surfaces in the accessibility tree with a distinct
/// identifier (`autocomplete.leg.<legIndex>.category[.suggestion.N]`).
struct CategorySuggestionDropdown: View {
  let suggestions: [CategorySuggestion]
  let searchText: String
  @Binding var highlightedIndex: Int?
  let onSelect: (CategorySuggestion) -> Void
  let identifier: String?
  let rowIdentifier: ((Int) -> String)?

  init(
    suggestions: [CategorySuggestion],
    searchText: String,
    highlightedIndex: Binding<Int?>,
    onSelect: @escaping (CategorySuggestion) -> Void,
    identifier: String? = nil,
    rowIdentifier: ((Int) -> String)? = nil
  ) {
    self.suggestions = suggestions
    self.searchText = searchText
    self._highlightedIndex = highlightedIndex
    self.onSelect = onSelect
    self.identifier = identifier
    self.rowIdentifier = rowIdentifier
  }

  var body: some View {
    let dropdown = AutocompleteSuggestionDropdown(
      items: suggestions,
      searchText: searchText,
      label: { $0.path },
      highlightedIndex: $highlightedIndex,
      onSelect: { onSelect($0) },
      rowIdentifier: rowIdentifier
    )
    if let identifier {
      dropdown.accessibilityIdentifier(identifier)
    } else {
      dropdown
    }
  }
}

/// Preference key for positioning per-leg category dropdowns.
/// Stores anchors keyed by leg index so multiple fields can coexist.
struct LegCategoryPickerAnchorKey: PreferenceKey {
  static let defaultValue: [Int: Anchor<CGRect>] = [:]

  static func reduce(value: inout [Int: Anchor<CGRect>], nextValue: () -> [Int: Anchor<CGRect>]) {
    value.merge(nextValue()) { _, new in new }
  }
}

/// A category autocomplete field for a specific leg index in custom mode.
struct LegCategoryAutocompleteField: View {
  let legIndex: Int
  @Binding var text: String
  @Binding var highlightedIndex: Int?
  let suggestionCount: Int
  let onTextChange: (String) -> Void
  let onAcceptHighlighted: () -> Void
  let onCancel: () -> Void

  var body: some View {
    AutocompleteField(
      placeholder: "Category",
      text: $text,
      highlightedIndex: $highlightedIndex,
      suggestionCount: suggestionCount,
      onTextChange: onTextChange,
      onAcceptHighlighted: onAcceptHighlighted,
      onCancel: onCancel
    )
    .anchorPreference(key: LegCategoryPickerAnchorKey.self, value: .bounds) { anchor in
      [legIndex: anchor]
    }
  }
}
