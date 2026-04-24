import SwiftUI

/// Backwards-compatible alias for overlay code that references the old key name.
typealias PayeeFieldAnchorKey = AutocompleteFieldAnchorKey

/// A text field for payee entry that reports its anchor for dropdown positioning.
struct PayeeAutocompleteField: View {
  @Binding var text: String
  @Binding var highlightedIndex: Int?
  let suggestionCount: Int
  let onTextChange: (String) -> Void
  let onAcceptHighlighted: () -> Void

  var body: some View {
    AutocompleteField(
      placeholder: "Payee",
      text: $text,
      highlightedIndex: $highlightedIndex,
      suggestionCount: suggestionCount,
      onTextChange: onTextChange,
      onAcceptHighlighted: onAcceptHighlighted
    )
  }
}

/// Identifiable wrapper for payee suggestion strings.
private struct PayeeSuggestion: Identifiable {
  let id: Int
  let name: String
}

/// The floating dropdown for payee suggestions.
struct PayeeSuggestionDropdown: View {
  let suggestions: [String]
  let searchText: String
  @Binding var highlightedIndex: Int?
  let onSelect: (String) -> Void

  private var visibleSuggestions: [PayeeSuggestion] {
    // Include exact matches: when the user has typed a known payee in
    // full, seeing that payee highlighted in the dropdown is the
    // confirmation that the app recognised it. Suppressing it made the
    // suggestion look forgotten.
    suggestions
      .prefix(8)
      .enumerated()
      .map { PayeeSuggestion(id: $0.offset, name: $0.element) }
  }

  var body: some View {
    AutocompleteSuggestionDropdown(
      items: visibleSuggestions,
      searchText: searchText,
      label: { $0.name },
      icon: Image(systemName: "magnifyingglass"),
      highlightedIndex: $highlightedIndex,
      onSelect: { onSelect($0.name) },
      rowIdentifier: { UITestIdentifiers.Autocomplete.payeeSuggestion($0) }
    )
    .accessibilityIdentifier(UITestIdentifiers.Autocomplete.payee)
  }
}

private let autocompletePreviewSuggestions = [
  "My School Connect", "My School Tuckshop", "My School Uniform",
]

private struct AutocompletePreviewForm: View {
  @Binding var payee: String
  @Binding var highlighted: Int?

  var body: some View {
    Form {
      Section {
        PayeeAutocompleteField(
          text: $payee,
          highlightedIndex: $highlighted,
          suggestionCount: autocompletePreviewSuggestions.count,
          onTextChange: { _ in },
          onAcceptHighlighted: {}
        )
        HStack {
          TextField("Amount", text: .constant("0.00"))
            .multilineTextAlignment(.trailing)
          Text(Instrument.AUD.id).foregroundStyle(.secondary)
        }
        DatePicker("Date", selection: .constant(Date()), displayedComponents: .date)
      }
      Section {
        Picker("Account", selection: .constant(UUID?.none)) {
          Text("Checking").tag(UUID?.none)
        }
      }
    }
    .formStyle(.grouped)
  }
}

#Preview("Autocomplete in Form") {
  @Previewable @State var payee = "My Schoo"
  @Previewable @State var highlighted: Int? = 1

  AutocompletePreviewForm(payee: $payee, highlighted: $highlighted)
    .frame(width: 400, height: 400)
    .overlayPreferenceValue(PayeeFieldAnchorKey.self) { anchor in
      if let anchor {
        GeometryReader { proxy in
          let rect = proxy[anchor]
          PayeeSuggestionDropdown(
            suggestions: autocompletePreviewSuggestions,
            searchText: "My Schoo",
            highlightedIndex: $highlighted,
            onSelect: { selected in payee = selected }
          )
          .frame(width: rect.width)
          .offset(x: rect.minX, y: rect.maxY + 4)
        }
      }
    }
}
