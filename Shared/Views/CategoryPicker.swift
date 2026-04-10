import SwiftUI

/// Preference key for positioning the category dropdown relative to the text field.
struct CategoryPickerAnchorKey: PreferenceKey {
  static let defaultValue: Anchor<CGRect>? = nil
  static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
    value = value ?? nextValue()
  }
}

/// Shared state for coordinating between CategoryPicker (in the form) and its dropdown overlay
/// (on the form).
@Observable @MainActor
final class CategoryPickerState {
  var isEditing = false
  var searchText = ""
  var highlightedIndex: Int?
  var categories: Categories = Categories(from: [])

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

  func open(categories: Categories) {
    self.categories = categories
    searchText = ""
    highlightedIndex = nil
    isEditing = true
  }

  func close() {
    isEditing = false
    searchText = ""
    highlightedIndex = nil
  }

  func acceptHighlighted(at index: Int) -> UUID? {
    if index == 0 {
      return nil
    } else {
      let entryIndex = index - 1
      guard entryIndex >= 0 && entryIndex < visibleEntries.count else { return nil }
      return visibleEntries[entryIndex].category.id
    }
  }
}

/// A category selection field with autocomplete search and browse-all support.
///
/// Uses the same `AutocompleteField` pattern as the payee field. Place inside a
/// Form Section. Add `.categoryPickerOverlay(state:selection:)` on the Form.
struct CategoryPicker: View {
  let categories: Categories
  @Binding var selection: UUID?
  @Bindable var state: CategoryPickerState

  private var selectedLabel: String {
    if let id = selection, let cat = categories.by(id: id) {
      return categories.path(for: cat)
    }
    return "None"
  }

  /// The placeholder shows "Category" when no selection, or "Category — Selected:Path" when one is set.
  private var placeholder: String {
    if selection != nil {
      return "Category — \(selectedLabel)"
    }
    return "Category"
  }

  init(
    categories: Categories,
    selection: Binding<UUID?>,
    state: CategoryPickerState
  ) {
    self.categories = categories
    self._selection = selection
    self.state = state
  }

  @FocusState private var isFieldFocused: Bool

  var body: some View {
    AutocompleteField(
      placeholder: placeholder,
      text: $state.searchText,
      highlightedIndex: $state.highlightedIndex,
      suggestionCount: state.isEditing ? state.totalRowCount : 0,
      onTextChange: { _ in
        if !state.isEditing {
          state.open(categories: categories)
        }
      },
      onAcceptHighlighted: {
        guard let index = state.highlightedIndex else { return }
        selection = state.acceptHighlighted(at: index)
        state.close()
      }
    )
    .focused($isFieldFocused)
    .accessibilityIdentifier("categoryPicker.searchField")
    .onChange(of: isFieldFocused) { _, focused in
      if focused && !state.isEditing {
        state.open(categories: categories)
      } else if !focused && state.isEditing {
        if let index = state.highlightedIndex {
          selection = state.acceptHighlighted(at: index)
        }
        state.close()
      }
    }
    .onChange(of: state.isEditing) { _, editing in
      if !editing && isFieldFocused {
        isFieldFocused = false
      }
    }
    .accessibilityRepresentation {
      Picker("Category", selection: $selection) {
        Text("None").tag(UUID?.none)
        ForEach(categories.flattenedByPath(), id: \.category.id) { entry in
          Text(entry.path).tag(UUID?.some(entry.category.id))
        }
      }
    }
  }
}

// MARK: - Form Overlay Modifier

/// Adds a category picker dropdown overlay to a Form.
struct CategoryPickerOverlayModifier: ViewModifier {
  @Bindable var state: CategoryPickerState
  @Binding var selection: UUID?

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
              onSelectNone: {
                selection = nil
                state.close()
              },
              onSelect: { entry in
                selection = entry.category.id
                state.close()
              }
            )
            .frame(width: rect.width)
            .offset(x: rect.minX, y: rect.maxY + 4)
            #if os(macOS)
              .onExitCommand { state.close() }
            #endif
          }
        }
      }
  }
}

extension View {
  func categoryPickerOverlay(state: CategoryPickerState, selection: Binding<UUID?>) -> some View {
    modifier(CategoryPickerOverlayModifier(state: state, selection: selection))
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
    .accessibilityIdentifier("categoryPicker.option.none")
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
    .accessibilityIdentifier("categoryPicker.option.\(entry.category.id)")
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

// MARK: - Previews

private let previewCategories: Categories = {
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

#Preview("Closed") {
  @Previewable @State var selection: UUID? = nil
  @Previewable @State var pickerState = CategoryPickerState()

  Form {
    Section {
      CategoryPicker(categories: previewCategories, selection: $selection, state: pickerState)
    }
  }
  .formStyle(.grouped)
  .categoryPickerOverlay(state: pickerState, selection: $selection)
  .frame(width: 400, height: 500)
}

#Preview("Open - browsing") {
  @Previewable @State var selection: UUID? = nil
  @Previewable @State var pickerState: CategoryPickerState = {
    let s = CategoryPickerState()
    s.open(categories: previewCategories)
    return s
  }()

  Form {
    Section {
      CategoryPicker(categories: previewCategories, selection: $selection, state: pickerState)
    }
  }
  .formStyle(.grouped)
  .categoryPickerOverlay(state: pickerState, selection: $selection)
  .frame(width: 400, height: 500)
}
