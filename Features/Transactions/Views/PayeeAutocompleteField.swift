import SwiftUI

/// Preference key to communicate the payee field's bounds to the parent view.
struct PayeeFieldAnchorKey: PreferenceKey {
  static let defaultValue: Anchor<CGRect>? = nil
  static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
    value = value ?? nextValue()
  }
}

/// A text field for payee entry that reports its anchor for dropdown positioning.
/// The actual dropdown is rendered by the parent using `PayeeSuggestionDropdown`.
struct PayeeAutocompleteField: View {
  @Binding var text: String
  @Binding var highlightedIndex: Int?
  let suggestionCount: Int
  let onTextChange: (String) -> Void
  let onAcceptHighlighted: () -> Void

  var body: some View {
    TextField("Payee", text: $text)
      .anchorPreference(key: PayeeFieldAnchorKey.self, value: .bounds) { $0 }
      .onChange(of: text) { _, newValue in
        highlightedIndex = nil
        onTextChange(newValue)
      }
      #if os(macOS)
        .onKeyPress(.downArrow) {
          guard suggestionCount > 0 else { return .ignored }
          highlightedIndex = min((highlightedIndex ?? -1) + 1, suggestionCount - 1)
          return .handled
        }
        .onKeyPress(.upArrow) {
          guard let current = highlightedIndex else { return .ignored }
          highlightedIndex = current > 0 ? current - 1 : nil
          return .handled
        }
        .onKeyPress(.return) {
          guard highlightedIndex != nil else { return .ignored }
          onAcceptHighlighted()
          return .handled
        }
        .onKeyPress(.escape) {
          guard suggestionCount > 0 else { return .ignored }
          highlightedIndex = nil
          onTextChange("")  // triggers hide
          return .handled
        }
      #endif
  }
}

/// The floating dropdown rendered above the Form by the parent view.
struct PayeeSuggestionDropdown: View {
  let suggestions: [String]
  let searchText: String
  @Binding var highlightedIndex: Int?
  let onSelect: (String) -> Void

  var visibleSuggestions: [String] {
    suggestions.filter { $0.localizedCaseInsensitiveCompare(searchText) != .orderedSame }.prefix(8)
      .map { $0 }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      ForEach(Array(visibleSuggestions.enumerated()), id: \.offset) { index, payee in
        suggestionRow(payee: payee, index: index)

        if index < visibleSuggestions.count - 1 {
          Divider()
            .padding(.leading, 32)
        }
      }
    }
    .padding(.vertical, 4)
    .background {
      RoundedRectangle(cornerRadius: 8)
        #if os(macOS)
          .fill(Color(nsColor: .controlBackgroundColor))
        #else
          .fill(Color(uiColor: .secondarySystemGroupedBackground))
        #endif
        .shadow(color: .black.opacity(0.2), radius: 10, y: 4)
    }
    .overlay(
      RoundedRectangle(cornerRadius: 8)
        #if os(macOS)
          .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
        #else
          .stroke(Color(uiColor: .separator), lineWidth: 0.5)
        #endif
    )
    .compositingGroup()
    .accessibilityLabel("\(visibleSuggestions.count) payee suggestions")
  }

  private func suggestionRow(payee: String, index: Int) -> some View {
    HStack(spacing: 8) {
      Image(systemName: "magnifyingglass")
        .font(.caption)
        .foregroundStyle(.tertiary)
      highlightedText(payee, matching: searchText)
      Spacer()
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .background(
      highlightedIndex == index
        ? Color.accentColor.opacity(0.12)
        : Color.clear
    )
    .contentShape(Rectangle())
    .onTapGesture {
      onSelect(payee)
    }
    #if os(macOS)
      .onHover { hovering in
        if hovering {
          highlightedIndex = index
        }
      }
    #endif
    .accessibilityLabel("Suggestion: \(payee)")
    .accessibilityAddTraits(.isButton)
  }

  private func highlightedText(_ payee: String, matching prefix: String) -> Text {
    let lower = payee.lowercased()
    let prefixLower = prefix.lowercased()

    if lower.hasPrefix(prefixLower), !prefix.isEmpty {
      let matchEnd = payee.index(payee.startIndex, offsetBy: prefix.count)
      let matchPart = String(payee[..<matchEnd])
      let restPart = String(payee[matchEnd...])
      return Text("\(Text(matchPart).foregroundStyle(.secondary))\(Text(restPart).bold())")
    }
    return Text(payee).bold()
  }
}

#Preview("Autocomplete in Form") {
  @Previewable @State var payee = "My Schoo"
  @Previewable @State var highlighted: Int? = 1
  let suggestions = ["My School Connect", "My School Tuckshop", "My School Uniform"]

  Form {
    Section {
      PayeeAutocompleteField(
        text: $payee,
        highlightedIndex: $highlighted,
        suggestionCount: suggestions.count,
        onTextChange: { _ in },
        onAcceptHighlighted: {}
      )

      HStack {
        TextField("Amount", text: .constant("0.00"))
          .multilineTextAlignment(.trailing)
        Text("AUD").foregroundStyle(.secondary)
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
  .frame(width: 400, height: 400)
  .overlayPreferenceValue(PayeeFieldAnchorKey.self) { anchor in
    if let anchor {
      GeometryReader { proxy in
        let rect = proxy[anchor]
        PayeeSuggestionDropdown(
          suggestions: suggestions,
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
