import SwiftUI

struct CategoryPicker: View {
  let categories: Categories
  @Binding var selection: UUID?
  let label: String

  @State private var searchText = ""
  @State private var isEditing = false
  @State private var highlightedIndex: Int?
  @FocusState private var isFieldFocused: Bool

  private var allEntries: [Categories.FlatEntry] {
    categories.flattenedByPath()
  }

  private var filteredEntries: [Categories.FlatEntry] {
    let entries = allEntries
    guard !searchText.trimmingCharacters(in: .whitespaces).isEmpty else {
      return entries
    }
    return entries.filter { matchesCategorySearch($0.path, query: searchText) }
  }

  /// Total row count including the "None" row at index 0.
  private var totalRowCount: Int {
    min(filteredEntries.count, 8) + 1
  }

  private var selectedLabel: String {
    if let id = selection, let cat = categories.by(id: id) {
      return categories.path(for: cat)
    }
    return "None"
  }

  init(categories: Categories, selection: Binding<UUID?>, label: String = "Category") {
    self.categories = categories
    self._selection = selection
    self.label = label
  }

  var body: some View {
    LabeledContent(label) {
      if isEditing {
        TextField("Search categories...", text: $searchText)
          .focused($isFieldFocused)
          .textFieldStyle(.plain)
          .onChange(of: searchText) { _, _ in highlightedIndex = nil }
          #if os(macOS)
            .onKeyPress(.downArrow) {
              guard totalRowCount > 0 else { return .ignored }
              highlightedIndex = min((highlightedIndex ?? -1) + 1, totalRowCount - 1)
              return .handled
            }
            .onKeyPress(.upArrow) {
              guard let current = highlightedIndex else { return .ignored }
              highlightedIndex = current > 0 ? current - 1 : nil
              return .handled
            }
            .onKeyPress(.return) {
              guard let index = highlightedIndex else { return .ignored }
              acceptHighlighted(at: index)
              return .handled
            }
            .onKeyPress(.escape) {
              closeDropdown()
              return .handled
            }
          #endif
          .onAppear {
            isFieldFocused = true
          }
          .overlay(alignment: .top) {
            CategoryDropdownContent(
              entries: Array(filteredEntries.prefix(8)),
              searchText: searchText,
              highlightedIndex: $highlightedIndex,
              onSelectNone: {
                selection = nil
                closeDropdown()
              },
              onSelect: { entry in
                selection = entry.category.id
                closeDropdown()
              }
            )
            .offset(y: 32)
          }
      } else {
        Text(selectedLabel)
          .foregroundStyle(selection == nil ? .secondary : .primary)
          .frame(maxWidth: .infinity, alignment: .trailing)
          .contentShape(Rectangle())
          .onTapGesture { openDropdown() }
          .accessibilityLabel("\(label): \(selectedLabel)")
          .accessibilityAddTraits(.isButton)
          .accessibilityHint("Tap to change category")
      }
    }
  }

  private func openDropdown() {
    searchText = ""
    highlightedIndex = nil
    isEditing = true
  }

  private func closeDropdown() {
    isEditing = false
    isFieldFocused = false
    searchText = ""
    highlightedIndex = nil
  }

  private func acceptHighlighted(at index: Int) {
    if index == 0 {
      selection = nil
      closeDropdown()
    } else {
      let entries = Array(filteredEntries.prefix(8))
      let entryIndex = index - 1
      guard entryIndex >= 0 && entryIndex < entries.count else { return }
      selection = entries[entryIndex].category.id
      closeDropdown()
    }
  }
}

// MARK: - CategoryDropdownContent

private struct CategoryDropdownContent: View {
  let entries: [Categories.FlatEntry]
  let searchText: String
  @Binding var highlightedIndex: Int?
  let onSelectNone: () -> Void
  let onSelect: (Categories.FlatEntry) -> Void

  /// Total row count: 1 for "None" + category entries.
  private var rowCount: Int {
    entries.count + 1
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 0) {
        // "None" row at index 0
        noneRow

        if !entries.isEmpty {
          Divider()
            .padding(.leading, 12)
        }

        ForEach(Array(entries.enumerated()), id: \.element.category.id) { index, entry in
          categoryRow(entry: entry, index: index + 1)

          if index < entries.count - 1 {
            Divider()
              .padding(.leading, 12)
          }
        }
      }
      .padding(.vertical, 4)
    }
    .frame(maxHeight: 300)
    .fixedSize(horizontal: false, vertical: true)
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
    .accessibilityLabel("\(rowCount) category suggestions")
  }

  private var noneRow: some View {
    HStack {
      Text("None")
        .foregroundStyle(.secondary)
      Spacer()
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .background(
      highlightedIndex == 0
        ? Color.accentColor.opacity(0.12)
        : Color.clear
    )
    .contentShape(Rectangle())
    .onTapGesture { onSelectNone() }
    #if os(macOS)
      .onHover { hovering in
        if hovering { highlightedIndex = 0 }
      }
    #endif
    .accessibilityLabel("None — remove category")
    .accessibilityAddTraits(.isButton)
  }

  private func categoryRow(entry: Categories.FlatEntry, index: Int) -> some View {
    HStack {
      highlightedCategoryText(entry.path, matching: searchText)
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
    .onTapGesture { onSelect(entry) }
    #if os(macOS)
      .onHover { hovering in
        if hovering { highlightedIndex = index }
      }
    #endif
    .accessibilityLabel("Category: \(entry.path)")
    .accessibilityAddTraits(.isButton)
  }

  /// Highlights matched characters as secondary weight, unmatched as bold.
  private func highlightedCategoryText(_ text: String, matching search: String) -> Text {
    let words = search.split(whereSeparator: \.isWhitespace).map { $0.lowercased() }
    guard !words.isEmpty else {
      return Text(text)
    }

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
    for i in 0..<text.count {
      if matched[i] {
        let startIdx = attributed.characters.index(attributed.startIndex, offsetBy: i)
        let endIdx = attributed.characters.index(startIdx, offsetBy: 1)
        attributed[startIdx..<endIdx].font = .body
        attributed[startIdx..<endIdx].foregroundColor = .secondary
      }
    }
    return Text(attributed)
  }
}

// MARK: - Preview

#Preview {
  struct PreviewWrapper: View {
    @State private var selection: UUID?

    private let sampleCategories: Categories = {
      let income = Category(id: UUID(), name: "Income")
      let salary = Category(id: UUID(), name: "Salary", parentId: income.id)
      let expenses = Category(id: UUID(), name: "Expenses")
      let food = Category(id: UUID(), name: "Food", parentId: expenses.id)
      let groceries = Category(id: UUID(), name: "Groceries", parentId: food.id)
      let dining = Category(id: UUID(), name: "Dining Out", parentId: food.id)
      let transport = Category(id: UUID(), name: "Transport", parentId: expenses.id)
      let housing = Category(id: UUID(), name: "Housing", parentId: expenses.id)
      return Categories(from: [
        income, salary, expenses, food, groceries, dining, transport, housing,
      ])
    }()

    var body: some View {
      Form {
        CategoryPicker(categories: sampleCategories, selection: $selection)
      }
      .frame(width: 400, height: 500)
      .padding()
    }
  }

  return PreviewWrapper()
}
