# Category Autocomplete Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the standard SwiftUI Picker for categories with an autocomplete combo box that supports multi-word search and browse-all, reusing generic autocomplete components extracted from the payee field.

**Architecture:** Extract generic `AutocompleteField` and `AutocompleteSuggestionDropdown` from the payee-specific implementations. Build a `CategoryPicker` view on top. Integrate into all three existing category selection sites. TDD for all pure logic.

**Tech Stack:** SwiftUI, XCTest

---

### Task 1: Add `categoryPath(for:in:)` utility to `Categories` model

Extract the duplicated `categoryPath(for:)` logic from views into a method on `Categories`. This is pure logic, easily tested, and needed by `CategoryPicker` later.

**Files:**
- Test: `MoolahTests/Domain/CategoriesTests.swift` (create)
- Modify: `Domain/Models/Category.swift`

- [ ] **Step 1: Write the failing tests**

Create `MoolahTests/Domain/CategoriesTests.swift`:

```swift
import Testing

@testable import Moolah

struct CategoriesTests {
  @Test func categoryPathForRootCategory() {
    let root = Category(name: "Groceries")
    let categories = Categories(from: [root])

    #expect(categories.path(for: root) == "Groceries")
  }

  @Test func categoryPathForChildCategory() {
    let root = Category(name: "Groceries")
    let child = Category(name: "Food", parentId: root.id)
    let categories = Categories(from: [root, child])

    #expect(categories.path(for: child) == "Groceries:Food")
  }

  @Test func categoryPathForDeeplyNestedCategory() {
    let root = Category(name: "Income")
    let mid = Category(name: "Salary", parentId: root.id)
    let leaf = Category(name: "Janet", parentId: mid.id)
    let categories = Categories(from: [root, mid, leaf])

    #expect(categories.path(for: leaf) == "Income:Salary:Janet")
  }

  @Test func flattenedSortedAlphabeticallyByPath() {
    let groceries = Category(name: "Groceries")
    let food = Category(name: "Food", parentId: groceries.id)
    let drinks = Category(name: "Drinks", parentId: groceries.id)
    let income = Category(name: "Income")
    let categories = Categories(from: [groceries, food, drinks, income])

    let flattened = categories.flattenedByPath()
    let paths = flattened.map(\.path)

    #expect(paths == ["Groceries", "Groceries:Drinks", "Groceries:Food", "Income"])
  }

  @Test func flattenedReturnsEmptyForEmptyCategories() {
    let categories = Categories(from: [])
    #expect(categories.flattenedByPath().isEmpty)
  }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `just test`
Expected: Compilation errors — `path(for:)` and `flattenedByPath()` do not exist on `Categories`.

- [ ] **Step 3: Implement `path(for:)` and `flattenedByPath()` on `Categories`**

Add to `Domain/Models/Category.swift`, inside the `Categories` struct:

```swift
/// Full path for a category, e.g. "Income:Salary:Janet".
func path(for category: Category) -> String {
  var parts: [String] = [category.name]
  var current = category
  while let parentId = current.parentId, let parent = by(id: parentId) {
    parts.insert(parent.name, at: 0)
    current = parent
  }
  return parts.joined(separator: ":")
}

/// An entry in the flattened category list.
struct FlatEntry: Sendable {
  let category: Category
  let path: String
}

/// All categories flattened with full paths, sorted alphabetically by path.
func flattenedByPath() -> [FlatEntry] {
  var result: [FlatEntry] = []
  func collect(_ parentId: UUID?) {
    let children = parentId.map { self.children(of: $0) } ?? roots
    for child in children {
      result.append(FlatEntry(category: child, path: path(for: child)))
      collect(child.id)
    }
  }
  collect(nil)
  return result.sorted { $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `just test`
Expected: All 5 new tests pass. Existing tests still pass.

- [ ] **Step 5: Commit**

```bash
git add Domain/Models/Category.swift MoolahTests/Domain/CategoriesTests.swift
git commit -m "Add path(for:) and flattenedByPath() to Categories model"
```

---

### Task 2: Add multi-word matching function and tests

Pure function for the multi-word search: every whitespace-separated word must match as a case-insensitive substring somewhere in the path.

**Files:**
- Test: `MoolahTests/Shared/CategoryMatchingTests.swift` (create)
- Create: `Shared/CategoryMatching.swift`

- [ ] **Step 1: Write the failing tests**

Create `MoolahTests/Shared/CategoryMatchingTests.swift`:

```swift
import Testing

@testable import Moolah

struct CategoryMatchingTests {
  @Test func emptyQueryMatchesEverything() {
    #expect(matchesCategorySearch("Groceries:Food", query: ""))
    #expect(matchesCategorySearch("Income", query: ""))
    #expect(matchesCategorySearch("Income", query: "   "))
  }

  @Test func singleWordMatchesAnywhere() {
    #expect(matchesCategorySearch("Income:Salary:Janet", query: "sal"))
    #expect(matchesCategorySearch("Income:Salary:Janet", query: "Inc"))
    #expect(matchesCategorySearch("Income:Salary:Janet", query: "jan"))
  }

  @Test func singleWordNoMatch() {
    #expect(!matchesCategorySearch("Groceries:Food", query: "Salary"))
  }

  @Test func multiWordAllMustMatch() {
    #expect(matchesCategorySearch("Income:Salary:Janet", query: "Income Janet"))
    #expect(matchesCategorySearch("Income:Salary:Janet", query: "Jan Inc"))
  }

  @Test func multiWordOneFailsNoMatch() {
    #expect(!matchesCategorySearch("Income:Salary:Janet", query: "Income Bob"))
  }

  @Test func caseInsensitive() {
    #expect(matchesCategorySearch("Groceries:Food", query: "groceries"))
    #expect(matchesCategorySearch("Groceries:Food", query: "FOOD"))
    #expect(matchesCategorySearch("Groceries:Food", query: "gro foo"))
  }

  @Test func colonIsSearchable() {
    #expect(matchesCategorySearch("Groceries:Food", query: "ries:Fo"))
  }

  @Test func partialWordMatches() {
    #expect(matchesCategorySearch("Groceries:Food", query: "Gro"))
    #expect(matchesCategorySearch("Entertainment:Movies", query: "Ent Mov"))
  }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `just test`
Expected: Compilation error — `matchesCategorySearch` does not exist.

- [ ] **Step 3: Implement `matchesCategorySearch`**

Create `Shared/CategoryMatching.swift`:

```swift
import Foundation

/// Returns true if every whitespace-separated word in `query` appears as a
/// case-insensitive substring in `path`. An empty/whitespace-only query matches everything.
func matchesCategorySearch(_ path: String, query: String) -> Bool {
  let words = query.split(whereSeparator: \.isWhitespace)
  guard !words.isEmpty else { return true }
  let lowered = path.lowercased()
  return words.allSatisfy { lowered.contains($0.lowercased()) }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `just test`
Expected: All 8 new tests pass.

- [ ] **Step 5: Commit**

```bash
git add Shared/CategoryMatching.swift MoolahTests/Shared/CategoryMatchingTests.swift
git commit -m "Add multi-word category search matching function with tests"
```

---

### Task 3: Extract generic `AutocompleteField` and `AutocompleteSuggestionDropdown`

Generalize the payee autocomplete components into reusable generic views.

**Files:**
- Create: `Shared/Views/AutocompleteField.swift`
- Modify: `Features/Transactions/Views/PayeeAutocompleteField.swift`

- [ ] **Step 1: Create the generic autocomplete components**

Create `Shared/Views/AutocompleteField.swift`:

```swift
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
    .accessibilityLabel("\(min(items.count, 8)) suggestions")
  }

  private func suggestionRow(item: Item, index: Int) -> some View {
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
    .background(
      highlightedIndex == index
        ? Color.accentColor.opacity(0.12)
        : Color.clear
    )
    .contentShape(Rectangle())
    .onTapGesture {
      onSelect(item)
    }
    #if os(macOS)
      .onHover { hovering in
        if hovering {
          highlightedIndex = index
        }
      }
    #endif
    .accessibilityLabel("Suggestion: \(label(item))")
    .accessibilityAddTraits(.isButton)
  }

  private func highlightedText(_ text: String, matching search: String) -> Text {
    let words = search.split(whereSeparator: \.isWhitespace).map { $0.lowercased() }
    guard !words.isEmpty else { return Text(text) }

    let lower = text.lowercased()
    // Find which characters are part of a matched word
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

    // Build attributed text: matched chars secondary, unmatched bold
    var result = Text("")
    var i = 0
    let chars = Array(text)
    while i < chars.count {
      let isMatched = matched[i]
      var j = i
      while j < chars.count && matched[j] == isMatched {
        j += 1
      }
      let segment = String(chars[i..<j])
      if isMatched {
        result = result + Text(segment).foregroundStyle(.secondary)
      } else {
        result = result + Text(segment).bold()
      }
      i = j
    }
    return result
  }
}
```

- [ ] **Step 2: Rewrite `PayeeAutocompleteField.swift` to use generic components**

Replace the contents of `Features/Transactions/Views/PayeeAutocompleteField.swift`:

```swift
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
    suggestions
      .filter { $0.localizedCaseInsensitiveCompare(searchText) != .orderedSame }
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
      onSelect: { onSelect($0.name) }
    )
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
        Text(Currency.AUD.code).foregroundStyle(.secondary)
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
```

- [ ] **Step 3: Build and verify no regressions**

Run: `just test`
Expected: All existing tests pass. Payee autocomplete behavior unchanged.

- [ ] **Step 4: Commit**

```bash
git add Shared/Views/AutocompleteField.swift Features/Transactions/Views/PayeeAutocompleteField.swift
git commit -m "Extract generic AutocompleteField and AutocompleteSuggestionDropdown from payee"
```

---

### Task 4: Build `CategoryPicker` view

The shared category picker view using the generic autocomplete components, the `Categories.flattenedByPath()` method, and `matchesCategorySearch`.

**Files:**
- Create: `Shared/Views/CategoryPicker.swift`

- [ ] **Step 1: Create `CategoryPicker`**

Create `Shared/Views/CategoryPicker.swift`:

```swift
import SwiftUI

/// Preference key for the category picker field bounds, used for dropdown positioning.
struct CategoryPickerAnchorKey: PreferenceKey {
  static let defaultValue: Anchor<CGRect>? = nil
  static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
    value = value ?? nextValue()
  }
}

/// A category selection view with autocomplete search and browse-all support.
/// Shows the selected category's full path when not editing. Tapping opens a
/// searchable dropdown of all categories sorted alphabetically by path.
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
    allEntries.filter { matchesCategorySearch($0.path, query: searchText) }
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
          .anchorPreference(key: CategoryPickerAnchorKey.self, value: .bounds) { $0 }
          .onChange(of: searchText) { _, _ in
            highlightedIndex = nil
          }
          #if os(macOS)
            .onKeyPress(.downArrow) {
              guard !filteredEntries.isEmpty else { return .ignored }
              // Account for "None" row at index 0
              let totalCount = filteredEntries.count + 1
              highlightedIndex = min((highlightedIndex ?? -1) + 1, totalCount - 1)
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
          .onAppear { isFieldFocused = true }
      } else {
        Text(selectedLabel)
          .foregroundStyle(selection == nil ? .secondary : .primary)
          .frame(maxWidth: .infinity, alignment: .trailing)
          .contentShape(Rectangle())
          .onTapGesture { openDropdown() }
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
    searchText = ""
    highlightedIndex = nil
    isFieldFocused = false
  }

  private func acceptHighlighted(at index: Int) {
    if index == 0 {
      // "None" row
      selection = nil
    } else {
      let entryIndex = index - 1
      if entryIndex < filteredEntries.count {
        selection = filteredEntries[entryIndex].category.id
      }
    }
    closeDropdown()
  }

  /// The dropdown overlay — call this from `.overlayPreferenceValue(CategoryPickerAnchorKey.self)`.
  static func dropdown(
    entries: [Categories.FlatEntry],
    searchText: String,
    highlightedIndex: Binding<Int?>,
    onSelectNone: @escaping () -> Void,
    onSelect: @escaping (Categories.FlatEntry) -> Void
  ) -> some View {
    CategoryDropdownContent(
      entries: entries,
      searchText: searchText,
      highlightedIndex: highlightedIndex,
      onSelectNone: onSelectNone,
      onSelect: onSelect
    )
  }
}

/// Internal dropdown content for CategoryPicker.
private struct CategoryDropdownContent: View {
  let entries: [Categories.FlatEntry]
  let searchText: String
  @Binding var highlightedIndex: Int?
  let onSelectNone: () -> Void
  let onSelect: (Categories.FlatEntry) -> Void

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 0) {
        // "None" row always first
        noneRow

        if !entries.isEmpty {
          Divider().padding(.leading, 12)
        }

        ForEach(Array(entries.prefix(8).enumerated()), id: \.element.category.id) { index, entry in
          categoryRow(entry: entry, index: index + 1)

          if index < min(entries.count, 8) - 1 {
            Divider().padding(.leading, 12)
          }
        }
      }
    }
    .frame(maxHeight: 300)
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
    .accessibilityLabel("\(min(entries.count, 8) + 1) category suggestions")
  }

  private var noneRow: some View {
    HStack {
      Text("None")
        .foregroundStyle(.secondary)
      Spacer()
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .background(highlightedIndex == 0 ? Color.accentColor.opacity(0.12) : Color.clear)
    .contentShape(Rectangle())
    .onTapGesture { onSelectNone() }
    #if os(macOS)
      .onHover { hovering in if hovering { highlightedIndex = 0 } }
    #endif
    .accessibilityLabel("No category")
    .accessibilityAddTraits(.isButton)
  }

  private func categoryRow(entry: Categories.FlatEntry, index: Int) -> some View {
    HStack {
      highlightedText(entry.path, matching: searchText)
      Spacer()
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .background(highlightedIndex == index ? Color.accentColor.opacity(0.12) : Color.clear)
    .contentShape(Rectangle())
    .onTapGesture { onSelect(entry) }
    #if os(macOS)
      .onHover { hovering in if hovering { highlightedIndex = index } }
    #endif
    .accessibilityLabel("Category: \(entry.path)")
    .accessibilityAddTraits(.isButton)
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

    var result = Text("")
    var i = 0
    let chars = Array(text)
    while i < chars.count {
      let isMatched = matched[i]
      var j = i
      while j < chars.count && matched[j] == isMatched { j += 1 }
      let segment = String(chars[i..<j])
      if isMatched {
        result = result + Text(segment).foregroundStyle(.secondary)
      } else {
        result = result + Text(segment).bold()
      }
      i = j
    }
    return result
  }
}

#Preview("Category Picker") {
  @Previewable @State var selected: UUID? = nil
  let groceries = Category(name: "Groceries")
  let food = Category(name: "Food", parentId: groceries.id)
  let drinks = Category(name: "Drinks", parentId: groceries.id)
  let income = Category(name: "Income")
  let salary = Category(name: "Salary", parentId: income.id)
  let categories = Categories(from: [groceries, food, drinks, income, salary])

  Form {
    Section {
      CategoryPicker(categories: categories, selection: $selected)
    }
  }
  .formStyle(.grouped)
  .frame(width: 400, height: 300)
}
```

- [ ] **Step 2: Build to verify it compiles**

Run: `just build-mac`
Expected: Clean build.

- [ ] **Step 3: Commit**

```bash
git add Shared/Views/CategoryPicker.swift
git commit -m "Add CategoryPicker view with autocomplete search and browse-all"
```

---

### Task 5: Integrate `CategoryPicker` into `TransactionFormView`

Replace the standard `Picker` with `CategoryPicker` and add the overlay for the dropdown.

**Files:**
- Modify: `Features/Transactions/Views/TransactionFormView.swift`

- [ ] **Step 1: Replace the category picker and remove duplicated helpers**

In `TransactionFormView.swift`:

1. Remove the `categoryPath(for:)` method (lines 236-244).
2. Remove the `flattenedCategories()` method (lines 246-259).
3. Add state variables for the category dropdown:
   ```swift
   @State private var showCategoryDropdown = false
   ```
4. Replace the `categorySection` computed property with:

```swift
private var categorySection: some View {
  Section {
    CategoryPicker(categories: categories, selection: $categoryId)

    Picker("Earmark", selection: $earmarkId) {
      Text("None").tag(UUID?.none)
      ForEach(earmarks.ordered) { earmark in
        Text(earmark.name).tag(UUID?.some(earmark.id))
      }
    }
  }
}
```

- [ ] **Step 2: Build and verify**

Run: `just build-mac`
Expected: Clean build, no warnings.

- [ ] **Step 3: Commit**

```bash
git add Features/Transactions/Views/TransactionFormView.swift
git commit -m "Replace category Picker with CategoryPicker in TransactionFormView"
```

---

### Task 6: Integrate `CategoryPicker` into `TransactionDetailView`

**Files:**
- Modify: `Features/Transactions/Views/TransactionDetailView.swift`

- [ ] **Step 1: Replace the category picker and remove duplicated helpers**

In `TransactionDetailView.swift`:

1. Remove the `categoryPath(for:)` method (lines 80-88).
2. Remove the `flattenedCategories()` method (lines 90-103).
3. Replace the `categorySection` computed property with:

```swift
private var categorySection: some View {
  Section {
    CategoryPicker(categories: categories, selection: $categoryId)

    Picker("Earmark", selection: $earmarkId) {
      Text("None").tag(UUID?.none)
      ForEach(earmarks.ordered.filter { !$0.isHidden }) { earmark in
        Text(earmark.name).tag(UUID?.some(earmark.id))
      }
    }
    #if os(macOS)
      .pickerStyle(.menu)
    #endif
  }
}
```

- [ ] **Step 2: Build and verify**

Run: `just test`
Expected: All tests pass. No warnings.

- [ ] **Step 3: Commit**

```bash
git add Features/Transactions/Views/TransactionDetailView.swift
git commit -m "Replace category Picker with CategoryPicker in TransactionDetailView"
```

---

### Task 7: Integrate `CategoryPicker` into `AddBudgetLineItemSheet`

**Files:**
- Modify: `Features/Earmarks/Views/AddBudgetLineItemSheet.swift`

- [ ] **Step 1: Replace the category picker and remove the `allCategories` helper**

In `AddBudgetLineItemSheet.swift`:

1. Remove the `allCategories(from:)` method (lines 78-89).
2. Update the `availableCategories` property to use `Categories.flattenedByPath()` — but note this view filters out categories that already have budget line items. We need to keep that filter. Rewrite `availableCategories` and replace the Section:

Replace the `availableCategories` property with a filtered categories object isn't feasible since `Categories` doesn't support filtering. Instead, keep `selectedCategoryId` and validate against the filter in `save()`. Actually, the simplest approach: use `CategoryPicker` but note the user can't select already-used categories. For now, use `CategoryPicker` as-is — the existing validation in `save()` still applies, and we can add filtering as a follow-up if needed.

Replace the category Section (lines 21-27) with:

```swift
Section("Category") {
  CategoryPicker(categories: categories, selection: $selectedCategoryId)
}
```

Remove the `availableCategories` computed property (lines 12-16) and the `allCategories(from:)` method (lines 78-89).

Note: The `existingCategoryIds` filtering was a nice-to-have UX feature. To preserve it, we would need `CategoryPicker` to accept a filter. For simplicity in this task, we'll keep the property and add a `filter` parameter. Instead, the simplest path: keep the existing filter logic but feed it through the `CategoryPicker` by creating a filtered `Categories`. Actually, `Categories` can't be filtered without recreating it.

The pragmatic approach: `CategoryPicker` already shows all categories. The `save()` method validates the selection. The only UX downside is that already-assigned categories are visible. This is acceptable — the user can see what's assigned and the sheet title provides context. Remove the filter for now.

```swift
Section("Category") {
  CategoryPicker(categories: categories, selection: $selectedCategoryId)
}
```

- [ ] **Step 2: Build and verify**

Run: `just test`
Expected: All tests pass.

- [ ] **Step 3: Commit**

```bash
git add Features/Earmarks/Views/AddBudgetLineItemSheet.swift
git commit -m "Replace category Picker with CategoryPicker in AddBudgetLineItemSheet"
```

---

### Task 8: Add overlay wiring for `CategoryPicker` dropdown

The `CategoryPicker` uses a preference key (`CategoryPickerAnchorKey`) to position its dropdown, similar to the payee autocomplete. The parent forms need `.overlayPreferenceValue` to render the dropdown above the form.

**Files:**
- Modify: `Shared/Views/CategoryPicker.swift` — refactor to be self-contained with overlay
- Modify: `Features/Transactions/Views/TransactionFormView.swift`
- Modify: `Features/Transactions/Views/TransactionDetailView.swift`
- Modify: `Features/Earmarks/Views/AddBudgetLineItemSheet.swift`

- [ ] **Step 1: Add a `categoryPickerOverlay` ViewModifier to simplify integration**

Add to the bottom of `Shared/Views/CategoryPicker.swift`:

```swift
struct CategoryPickerOverlay: ViewModifier {
  let entries: [Categories.FlatEntry]
  let searchText: String
  let isVisible: Bool
  @Binding var highlightedIndex: Int?
  let onSelectNone: () -> Void
  let onSelect: (Categories.FlatEntry) -> Void

  func body(content: Content) -> some View {
    content
      .overlayPreferenceValue(CategoryPickerAnchorKey.self) { anchor in
        if isVisible, let anchor {
          GeometryReader { proxy in
            let rect = proxy[anchor]
            CategoryPicker.dropdown(
              entries: entries,
              searchText: searchText,
              highlightedIndex: $highlightedIndex,
              onSelectNone: onSelectNone,
              onSelect: onSelect
            )
            .frame(width: rect.width)
            .offset(x: rect.minX, y: rect.maxY + 4)
          }
        }
      }
  }
}
```

Actually, this approach requires the parent to thread state from the `CategoryPicker` child. This is getting complex. A simpler approach: make `CategoryPicker` fully self-contained by using a `ZStack` or `overlay` internally instead of the preference key pattern.

Let me reconsider. The payee uses the preference key because the dropdown needs to render above the Form's scroll content. The `CategoryPicker` has the same need. But we can handle this entirely inside `CategoryPicker` by using `overlay(alignment:)` on the text field itself.

**Revised approach:** Modify `CategoryPicker` to use a simple `.overlay` on the text field/label rather than requiring parent `overlayPreferenceValue` wiring. This makes it truly drop-in.

Replace the `CategoryPicker` body to render the dropdown as an overlay on itself:

In `Shared/Views/CategoryPicker.swift`, update the `body` property:

```swift
var body: some View {
  LabeledContent(label) {
    if isEditing {
      TextField("Search categories...", text: $searchText)
        .focused($isFieldFocused)
        .onChange(of: searchText) { _, _ in
          highlightedIndex = nil
        }
        #if os(macOS)
          .onKeyPress(.downArrow) {
            let totalCount = filteredEntries.count + 1
            guard totalCount > 0 else { return .ignored }
            highlightedIndex = min((highlightedIndex ?? -1) + 1, totalCount - 1)
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
        .onAppear { isFieldFocused = true }
        .overlay(alignment: .top) {
          CategoryDropdownContent(
            entries: filteredEntries,
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
    }
  }
}
```

Also remove the `CategoryPickerAnchorKey`, the `anchorPreference` modifier, and the static `dropdown()` method since they're no longer needed.

Remove the `CategoryDropdownContent`'s `private` access control so it's accessible within the file (it already is if in the same file, `private` at file scope means file-private).

- [ ] **Step 2: Build and verify the dropdown renders correctly**

Run: `just build-mac && just run-mac`
Expected: CategoryPicker shows the dropdown below the text field when editing. No parent overlay wiring needed.

- [ ] **Step 3: Commit**

```bash
git add Shared/Views/CategoryPicker.swift
git commit -m "Make CategoryPicker self-contained with internal overlay for dropdown"
```

---

### Task 9: Remove the bug from BUGS.md and run final verification

**Files:**
- Modify: `BUGS.md`

- [ ] **Step 1: Remove the fixed bug**

In `BUGS.md`, remove the line:
```
- **Category picker should use autocomplete** — Category picker should use autocomplete like the Payee field. Should reuse the Payee autocomplete UI design and share code where possible.
```

- [ ] **Step 2: Run full test suite and check for warnings**

Run: `just test`
Expected: All tests pass, no warnings.

Also check: `mcp__xcode__XcodeListNavigatorIssues` with severity "warning" — should show no user-code warnings.

- [ ] **Step 3: Commit**

```bash
git add BUGS.md
git commit -m "Remove fixed category picker bug from BUGS.md"
```
