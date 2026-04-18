import SwiftUI

/// Preference key to communicate an autocomplete field's bounds to the parent view for dropdown positioning.
struct AutocompleteFieldAnchorKey: PreferenceKey {
  static let defaultValue: Anchor<CGRect>? = nil
  static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
    value = value ?? nextValue()
  }
}

/// A text field that reports its anchor for autocomplete dropdown positioning and handles keyboard navigation.
struct AutocompleteField: View {
  let placeholder: String
  @Binding var text: String
  @Binding var highlightedIndex: Int?
  let suggestionCount: Int
  let onTextChange: (String) -> Void
  let onAcceptHighlighted: () -> Void

  var body: some View {
    TextField(placeholder, text: $text)
      .anchorPreference(key: AutocompleteFieldAnchorKey.self, value: .bounds) { $0 }
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
          onTextChange("")
          return .handled
        }
      #endif
  }
}

/// A floating dropdown showing autocomplete suggestions. Renders as an overlay positioned by the parent.
struct AutocompleteSuggestionDropdown<Item: Identifiable>: View {
  let items: [Item]
  let searchText: String
  let label: (Item) -> String
  let icon: Image?
  @Binding var highlightedIndex: Int?
  let onSelect: (Item) -> Void

  init(
    items: [Item],
    searchText: String,
    label: @escaping (Item) -> String,
    icon: Image? = nil,
    highlightedIndex: Binding<Int?>,
    onSelect: @escaping (Item) -> Void
  ) {
    self.items = items
    self.searchText = searchText
    self.label = label
    self.icon = icon
    self._highlightedIndex = highlightedIndex
    self.onSelect = onSelect
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      ForEach(Array(items.prefix(8).enumerated()), id: \.offset) { index, item in
        suggestionRow(item: item, index: index)

        if index < min(items.count, 8) - 1 {
          Divider()
            .padding(.leading, icon != nil ? 32 : 12)
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
        .shadow(color: Color.primary.opacity(0.15), radius: 10, y: 4)
    }
    .overlay(
      RoundedRectangle(cornerRadius: 8)
        .stroke(.separator, lineWidth: 0.5)
    )
    .compositingGroup()
    .accessibilityLabel("\(min(items.count, 8)) suggestions")
  }

  private func suggestionRow(item: Item, index: Int) -> some View {
    Button {
      onSelect(item)
    } label: {
      HStack(spacing: 8) {
        if let icon {
          icon
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
        highlightedText(label(item), matching: searchText)
        Spacer()
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .background(
      highlightedIndex == index
        ? Color.accentColor.opacity(0.12)
        : Color.clear
    )
    #if os(macOS)
      .onHover { hovering in
        if hovering {
          highlightedIndex = index
        }
      }
    #endif
    .accessibilityLabel("Suggestion: \(label(item))")
  }

  private func highlightedText(_ text: String, matching search: String) -> Text {
    let words = search.split(whereSeparator: \.isWhitespace).map { $0.lowercased() }
    guard !words.isEmpty else { return Text(text) }

    let lower = text.lowercased()
    var matched = Array(repeating: false, count: text.count)
    for word in words {
      var searchFrom = lower.startIndex
      while let range = lower.range(of: word, range: searchFrom..<lower.endIndex) {
        let startOffset = lower.distance(from: lower.startIndex, to: range.lowerBound)
        let endOffset = lower.distance(from: lower.startIndex, to: range.upperBound)
        for i in startOffset..<endOffset {
          matched[i] = true
        }
        searchFrom = range.upperBound
      }
    }

    var attributed = AttributedString(text)
    attributed.font = .body.bold()
    let chars = Array(text)
    var i = 0
    while i < chars.count {
      if matched[i] {
        var j = i
        while j < chars.count && matched[j] { j += 1 }
        let startIdx = attributed.characters.index(attributed.startIndex, offsetBy: i)
        let endIdx = attributed.characters.index(attributed.startIndex, offsetBy: j)
        attributed[startIdx..<endIdx].font = .body
        attributed[startIdx..<endIdx].foregroundColor = .secondary
        i = j
      } else {
        i += 1
      }
    }
    return Text(attributed)
  }
}
