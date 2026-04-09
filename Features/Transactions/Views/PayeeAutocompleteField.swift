import SwiftUI

/// A text field with a floating suggestion dropdown for payee autocomplete.
/// Suggestions appear below the field as you type, with keyboard navigation on macOS.
struct PayeeAutocompleteField: View {
  @Binding var text: String
  let suggestions: [String]
  let onTextChange: (String) -> Void
  let onSelect: (String) -> Void

  @FocusState private var isFieldFocused: Bool
  @State private var highlightedIndex: Int?
  @State private var showSuggestions = false

  private var visibleSuggestions: [String] {
    // Filter out exact match and limit to 8
    suggestions.filter { $0.localizedCaseInsensitiveCompare(text) != .orderedSame }.prefix(8)
      .map { $0 }
  }

  var body: some View {
    ZStack(alignment: .topLeading) {
      TextField("Payee", text: $text)
        .focused($isFieldFocused)
        .onChange(of: text) { _, newValue in
          onTextChange(newValue)
          highlightedIndex = nil
          showSuggestions = true
        }
        .onChange(of: isFieldFocused) { _, focused in
          if !focused {
            // Delay dismissal to allow tap on suggestion
            Task {
              try? await Task.sleep(nanoseconds: 150_000_000)
              showSuggestions = false
            }
          } else {
            showSuggestions = true
          }
        }
        #if os(macOS)
          .onKeyPress(.downArrow) {
            if !visibleSuggestions.isEmpty {
              highlightedIndex = min((highlightedIndex ?? -1) + 1, visibleSuggestions.count - 1)
              return .handled
            }
            return .ignored
          }
          .onKeyPress(.upArrow) {
            if let current = highlightedIndex {
              highlightedIndex = current > 0 ? current - 1 : nil
              return .handled
            }
            return .ignored
          }
          .onKeyPress(.return) {
            if let index = highlightedIndex, index < visibleSuggestions.count {
              selectSuggestion(visibleSuggestions[index])
              return .handled
            }
            return .ignored
          }
          .onKeyPress(.escape) {
            if showSuggestions && !visibleSuggestions.isEmpty {
              showSuggestions = false
              return .handled
            }
            return .ignored
          }
        #endif
        .overlay(alignment: .topLeading) {
          if showSuggestions && isFieldFocused && !visibleSuggestions.isEmpty {
            suggestionDropdown
              .offset(y: 32)
          }
        }
        .zIndex(1)
    }
  }

  private var suggestionDropdown: some View {
    VStack(alignment: .leading, spacing: 0) {
      ForEach(Array(visibleSuggestions.enumerated()), id: \.offset) { index, payee in
        Button {
          selectSuggestion(payee)
        } label: {
          HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
              .font(.caption)
              .foregroundStyle(.tertiary)
            highlightedText(payee, matching: text)
            Spacer()
          }
          .padding(.horizontal, 10)
          .padding(.vertical, 7)
          .contentShape(Rectangle())
          .background(
            highlightedIndex == index
              ? Color.accentColor.opacity(0.12)
              : Color.clear
          )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Suggestion: \(payee)")

        if index < visibleSuggestions.count - 1 {
          Divider()
            .padding(.leading, 30)
        }
      }
    }
    .padding(.vertical, 4)
    .background(.regularMaterial)
    .clipShape(RoundedRectangle(cornerRadius: 8))
    .shadow(color: .black.opacity(0.12), radius: 8, y: 4)
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityLabel("\(visibleSuggestions.count) payee suggestions")
    .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
    .animation(.easeOut(duration: 0.15), value: visibleSuggestions)
  }

  /// Renders text with the matching prefix in regular weight and the rest bold.
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

  private func selectSuggestion(_ payee: String) {
    text = payee
    showSuggestions = false
    highlightedIndex = nil
    onSelect(payee)
  }
}
