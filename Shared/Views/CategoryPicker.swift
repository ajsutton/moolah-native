import SwiftUI

/// Preference key for positioning the category dropdown relative to the text field.
struct CategoryPickerAnchorKey: PreferenceKey {
  static let defaultValue: Anchor<CGRect>? = nil
  static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
    value = value ?? nextValue()
  }
}

/// Shared state for coordinating between CategoryPicker (in the form) and its dropdown overlay (on the form).
@Observable @MainActor
final class CategoryPickerState {
  var searchText = ""
  var isEditing = false
  var highlightedIndex: Int?
  var categories: Categories = Categories(from: [])
  var selection: UUID?

  // Callback set by the CategoryPicker to propagate selection back to the binding
  var onSelectionChanged: ((UUID?) -> Void)?

  var allEntries: [Categories.FlatEntry] {
    categories.flattenedByPath()
  }

  var filteredEntries: [Categories.FlatEntry] {
    let entries = allEntries
    guard !searchText.trimmingCharacters(in: .whitespaces).isEmpty else {
      return entries
    }
    return entries.filter { matchesCategorySearch($0.path, query: searchText) }
  }

  var visibleEntries: [Categories.FlatEntry] {
    Array(filteredEntries.prefix(8))
  }

  /// Total row count including "None" at index 0.
  var totalRowCount: Int {
    visibleEntries.count + 1
  }

  func open(categories: Categories, selection: UUID?) {
    self.categories = categories
    self.selection = selection
    searchText = ""
    highlightedIndex = nil
    isEditing = true
  }

  func close() {
    isEditing = false
    searchText = ""
    highlightedIndex = nil
  }

  func select(_ id: UUID?) {
    selection = id
    onSelectionChanged?(id)
    close()
  }

  func acceptHighlighted(at index: Int) {
    if index == 0 {
      select(nil)
    } else {
      let entryIndex = index - 1
      guard entryIndex >= 0 && entryIndex < visibleEntries.count else { return }
      select(visibleEntries[entryIndex].category.id)
    }
  }
}

/// A category selection field with autocomplete search and browse-all support.
///
/// Place this inside a Form. Add `.categoryPickerOverlay(state:)` on the Form
/// so the dropdown renders above form content.
struct CategoryPicker: View {
  let categories: Categories
  @Binding var selection: UUID?
  let label: String
  @Bindable var state: CategoryPickerState
  @FocusState private var isFieldFocused: Bool

  private var selectedLabel: String {
    if let id = selection, let cat = categories.by(id: id) {
      return categories.path(for: cat)
    }
    return "None"
  }

  init(
    categories: Categories,
    selection: Binding<UUID?>,
    state: CategoryPickerState,
    label: String = "Category"
  ) {
    self.categories = categories
    self._selection = selection
    self.state = state
    self.label = label
  }

  var body: some View {
    LabeledContent(label) {
      if state.isEditing {
        TextField("", text: $state.searchText)
          .focused($isFieldFocused)
          .textFieldStyle(.plain)
          .anchorPreference(key: CategoryPickerAnchorKey.self, value: .bounds) { $0 }
          .onChange(of: state.searchText) { _, _ in state.highlightedIndex = nil }
          #if os(macOS)
            .onKeyPress(.downArrow) {
              guard state.totalRowCount > 0 else { return .ignored }
              state.highlightedIndex = min(
                (state.highlightedIndex ?? -1) + 1, state.totalRowCount - 1)
              return .handled
            }
            .onKeyPress(.upArrow) {
              guard let current = state.highlightedIndex else { return .ignored }
              state.highlightedIndex = current > 0 ? current - 1 : nil
              return .handled
            }
            .onKeyPress(.return) {
              guard let index = state.highlightedIndex else { return .ignored }
              state.acceptHighlighted(at: index)
              return .handled
            }
            .onKeyPress(.escape) {
              state.close()
              return .handled
            }
          #endif
          .onAppear {
            isFieldFocused = true
            state.onSelectionChanged = { [self] newValue in
              self.selection = newValue
            }
          }
      } else {
        Text(selectedLabel)
          .foregroundStyle(selection == nil ? .secondary : .primary)
          .frame(maxWidth: .infinity, alignment: .trailing)
          .contentShape(Rectangle())
          .onTapGesture {
            state.open(categories: categories, selection: selection)
          }
          .accessibilityLabel("\(label): \(selectedLabel)")
          .accessibilityAddTraits(.isButton)
          .accessibilityHint("Tap to change category")
      }
    }
  }
}

// MARK: - Form Overlay Modifier

/// Adds a category picker dropdown overlay to a Form. Use with `CategoryPickerState`.
struct CategoryPickerOverlayModifier: ViewModifier {
  @Bindable var state: CategoryPickerState

  func body(content: Content) -> some View {
    content
      .overlayPreferenceValue(CategoryPickerAnchorKey.self) { anchor in
        if state.isEditing, let anchor {
          GeometryReader { proxy in
            let rect = proxy[anchor]
            CategoryDropdownContent(
              entries: state.visibleEntries,
              searchText: state.searchText,
              highlightedIndex: $state.highlightedIndex,
              onSelectNone: { state.select(nil) },
              onSelect: { entry in state.select(entry.category.id) }
            )
            .frame(width: rect.width)
            .offset(x: rect.minX, y: rect.maxY + 4)
          }
        }
      }
  }
}

extension View {
  func categoryPickerOverlay(state: CategoryPickerState) -> some View {
    modifier(CategoryPickerOverlayModifier(state: state))
  }
}

// MARK: - CategoryDropdownContent

private struct CategoryDropdownContent: View {
  let entries: [Categories.FlatEntry]
  let searchText: String
  @Binding var highlightedIndex: Int?
  let onSelectNone: () -> Void
  let onSelect: (Categories.FlatEntry) -> Void

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 0) {
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
    .accessibilityLabel("\(entries.count + 1) category suggestions")
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
    @State private var pickerState = CategoryPickerState()

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
        CategoryPicker(
          categories: sampleCategories,
          selection: $selection,
          state: pickerState
        )
      }
      .formStyle(.grouped)
      .categoryPickerOverlay(state: pickerState)
      .frame(width: 400, height: 500)
      .padding()
    }
  }

  return PreviewWrapper()
}
