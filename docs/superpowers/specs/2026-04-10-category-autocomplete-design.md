# Category Autocomplete & Shared Picker Design

## Problem

The category picker uses a standard SwiftUI `Picker` with a flat list of all categories shown as full paths (e.g., "Groceries:Food"). There is no search or autocomplete. The payee field has a custom autocomplete dropdown, but none of that code is reusable. The `flattenedCategories()` and `categoryPath()` helpers are duplicated across TransactionFormView, TransactionDetailView, and AddBudgetLineItemSheet.

## Goals

1. Extract a generic autocomplete combo box from the payee-specific implementation.
2. Create a shared `CategoryPicker` view used everywhere categories are selected.
3. Integrate autocomplete into the category picker with multi-word matching.
4. Use TDD throughout.

## Design

### Generic Autocomplete Components

**File: `Shared/Views/AutocompleteField.swift`**

Three components extracted and generalized from `PayeeAutocompleteField.swift`:

- **`AutocompleteFieldAnchorKey`** — Preference key reporting field bounds for dropdown positioning. Renamed from `PayeeFieldAnchorKey`.

- **`AutocompleteField`** — Generic text field. Parameters: `placeholder: String`, `text: Binding<String>`, `highlightedIndex: Binding<Int?>`, `suggestionCount: Int`, `onTextChange: (String) -> Void`, `onAcceptHighlighted: () -> Void`, `onFocus: (() -> Void)?`. Reports anchor via preference key. Keyboard navigation on macOS (down/up arrows, return, escape).

- **`AutocompleteSuggestionDropdown`** — Generic dropdown overlay. Parameters: `items: [Item]`, `searchText: String`, `label: (Item) -> String`, `icon: ((Item) -> Image)?`, `highlightedIndex: Binding<Int?>`, `onSelect: (Item) -> Void`. Handles floating overlay styling (material background, rounded corners, shadow, border), hover/tap selection, highlighted row state, accessibility labels. Text highlighting generalizes to bold all portions that don't match any search word (matched portions shown secondary). Limited to 8 visible items.

### Payee Autocomplete Migration

**File: `Features/Transactions/Views/PayeeAutocompleteField.swift`**

Rewritten to wrap the generic components:

- `PayeeAutocompleteField` becomes a thin wrapper around `AutocompleteField` with `placeholder: "Payee"`.
- `PayeeSuggestionDropdown` becomes a thin wrapper around `AutocompleteSuggestionDropdown` with `String` items, the existing prefix-match filtering, and a magnifying glass icon.
- `PayeeFieldAnchorKey` replaced by `AutocompleteFieldAnchorKey`. A typealias preserves source compatibility for existing overlay code.

### Shared CategoryPicker

**File: `Shared/Views/CategoryPicker.swift`**

A self-contained view for category selection with autocomplete.

**Parameters:**
- `categories: Categories` — the full category tree
- `selection: Binding<UUID?>` — selected category ID (nil = "None")
- `label: String` — form label (default: "Category")

**Internal state:**
- `searchText: String` — current text field contents
- `isEditing: Bool` — whether the field is focused/active
- `highlightedIndex: Int?` — keyboard navigation state

**Behavior:**
- **Display mode** (not editing): Shows the selected category's full path as static text, or "None" if nil. Tapping enters edit mode.
- **Edit/browse mode** (editing, empty search text): Shows all categories sorted alphabetically by full path.
- **Search mode** (editing, non-empty search text): Filters using multi-word matching.
- Selecting a category sets the binding and exits edit mode.
- "None" option always available at the top of the list.

**Category path computation:**
- `flattenedCategories()` logic moves here as a computed property or method on the view.
- `categoryPath(for:in:)` extracted as a shared utility (static method or free function) since it's pure logic.
- Returns entries sorted alphabetically by full path.

### Multi-Word Matching

**Extracted as a testable pure function**, either a static method on `CategoryPicker` or a standalone function:

```swift
func matchesSearch(_ path: String, query: String) -> Bool
```

- Split `query` by whitespace into words.
- Each word must appear as a case-insensitive substring somewhere in `path`.
- Empty query matches everything (browse mode).
- Order of words doesn't matter: "Jan Inc" and "Inc Jan" both match "Income:Salary:Janet".

### Integration Points

Three views updated to use `CategoryPicker`:

1. **`TransactionFormView.swift`** — Replace the `Picker("Category", selection: $categoryId)` block (lines ~261-268 and ~330-340) with `CategoryPicker(categories: categories, selection: $categoryId)`. Remove `flattenedCategories()` and `categoryPath()` private methods.

2. **`TransactionDetailView.swift`** — Replace the `Picker("Category", selection: $categoryId)` block (lines ~274-295) with `CategoryPicker`. Remove `flattenedCategories()` and `categoryPath()` private methods.

3. **`AddBudgetLineItemSheet.swift`** — Replace the category picker (lines ~21-27) with `CategoryPicker`. Remove `allCategories()` helper.

### Text Highlighting in Dropdown

For category suggestions, the dropdown highlights matched portions differently from payee (which only highlights prefix):

- Split search text into words.
- For each word, find its range in the display label (case-insensitive).
- Matched ranges shown in `.secondary` style; unmatched portions shown in `.bold`.
- If search is empty (browse mode), all text shown in normal weight.

### Testing

**TDD approach — tests written before implementation.**

**`MoolahTests/Shared/CategoryMatchingTests.swift`:**
- Single word matches anywhere in path
- Multi-word: all words must match (AND logic)
- Word order doesn't matter
- Case insensitive
- Empty query matches all categories
- No match returns empty
- Partial word matches (e.g., "Gro" matches "Groceries:Food")
- Colon in path is part of the searchable text

**Existing payee tests** must continue passing after the refactor to generic components.

### Files Changed

| Action | File | Description |
|--------|------|-------------|
| New | `Shared/Views/AutocompleteField.swift` | Generic autocomplete field, dropdown, anchor key |
| New | `Shared/Views/CategoryPicker.swift` | Shared category picker with autocomplete |
| New | `MoolahTests/Shared/CategoryMatchingTests.swift` | Multi-word matching tests |
| Edit | `Features/Transactions/Views/PayeeAutocompleteField.swift` | Rewrite to wrap generic components |
| Edit | `Features/Transactions/Views/TransactionFormView.swift` | Replace Picker with CategoryPicker |
| Edit | `Features/Transactions/Views/TransactionDetailView.swift` | Replace Picker with CategoryPicker |
| Edit | `Features/Earmarks/Views/AddBudgetLineItemSheet.swift` | Replace Picker with CategoryPicker |
| Edit | `project.yml` | Add new files to targets |
| Edit | `BUGS.md` | Remove fixed bug |
