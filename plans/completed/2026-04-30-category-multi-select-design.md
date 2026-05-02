# Category multi-select for transaction filter — design

## Goal

Replace the inline-toggle Categories section in `TransactionFilterView` with a dedicated multi-select picker that scales to any number of categories. The current section renders one `Toggle` per category in the same `Form` as five other sections; with a real-world category list it grows past full-screen height, pushes toolbar buttons (Cancel / Apply / Clear All) out of view, and the dialog never reaches a usable size.

## Non-goals

- **No filter-semantics change.** Selection stays a flat `Set<UUID>`. Selecting a parent matches only transactions tagged with that parent — descendants are not implicitly included. The semantics question is real but separable; this design fixes the layout problem first.
- **No data-model change.** `Category`, `Categories`, `TransactionFilter`, and `Categories.path(for:)` are unchanged.
- **No change to other category pickers.** The single-category autocomplete used in `AddBudgetLineItemSheet` and `RuleEditorActionRow` keeps its current shape; this picker is for multi-select only.
- **No keyboard-shortcut design.** Tab/arrow navigation works for free via SwiftUI focus; we don't add custom shortcuts.

## User flow

1. User opens the transaction filter sheet.
2. The Categories section shows a single row: `Categories  [summary]  ›`.
3. User taps the row.
   - **macOS:** a popover anchors to the row.
   - **iOS:** the picker pushes onto the existing `NavigationStack` inside the sheet.
4. The picker shows the category hierarchy with checkboxes. The user toggles individual categories or right-clicks / long-presses a parent to reveal "Select all in <Parent>" / "Deselect all in <Parent>".
5. User dismisses the popover (click-away on macOS, back button on iOS).
6. The trigger row's summary updates to reflect the new selection.

The filter sheet's existing **Apply** / **Cancel** / **Clear All** buttons are unchanged. As toggles flip the picker mutates the sheet-local `selectedCategoryIds` state (same as today's inline toggles); the underlying filter only changes when the user presses **Apply**. This is identical to current behaviour — there is no new "buffered vs live" semantic.

## Components

### 1. Trigger row in `TransactionFilterView`

The Categories section becomes:

```
Section("Categories") {
  Button { showCategoryPicker = true } label: {
    LabeledContent("Categories", value: categorySelectionSummary)
  }
  .buttonStyle(.plain)
  .popover(isPresented: $showCategoryPicker, …) {  // macOS
    CategoryMultiSelectPicker(…)
  }
}
```

On iOS, the same row is wrapped in a `NavigationLink` instead of a popover binding (single `#if os(iOS)` split — the picker view itself is the same).

The selection summary string:
- empty set → `"All"`
- exactly 1 → `categories.path(for: theOne)`
- 2+ → `"\(N) selected"`

### 2. `CategoryMultiSelectPicker`

A new view at `Features/Transactions/Views/CategoryMultiSelectPicker.swift`. Props:

- `categories: Categories`
- `selectedIds: Binding<Set<UUID>>`

Layout, top to bottom:
- Title bar with `Clear` button (disabled when `selectedIds.isEmpty`).
- `.searchable` text field.
- A `List` of category rows.

**Row rendering:**
- No active search → walk the hierarchy: each root row, followed by its children indented one level. Same flattening pass as the current `allCategories` computed property, but the row indents children so the tree shape is visible.
- Active search → flat list of matches against `categories.path(for:)` (substring, case-insensitive). Each row shows the full path so users don't lose context. No indentation in this mode.

**Per-row controls:**
- A `Toggle` (checkbox style on macOS, switch on iOS — SwiftUI's defaults already do this) bound to `selectedIds.contains(id)`.
- For parent rows only, a `.contextMenu` with two items:
  - `Select all in <Parent>` — inserts the parent's id and every descendant id into `selectedIds`.
  - `Deselect all in <Parent>` — removes the parent's id and every descendant id.

The descendant collection lives in a new helper on `Categories`:

```swift
extension Categories {
  func descendants(of id: UUID) -> [Category]   // depth-first, excludes self
}
```

It walks `children(of:)` recursively. Today's hierarchy is one level deep, but the helper is written for arbitrary depth so it doesn't break if/when nesting deepens. The picker calls `selectedIds.formUnion([id] + descendants(of: id).map(\.id))` for "Select all" and the symmetric `subtract` for "Deselect all". Putting these on `Categories` keeps the view thin (per CLAUDE.md's thin-view rule) and makes them unit-testable without rendering UI.

A second helper produces the trigger-row summary, also on `Categories`:

```swift
extension Categories {
  func selectionSummary(for selected: Set<UUID>) -> String
}
```

It returns `"All"` for empty, the full path for exactly one **still-present** id, and `"\(N) selected"` for two or more present ids (orphaned ids are excluded from the count — see Risks).

### 3. Sizing

- macOS popover: explicit `.frame(width: 320, height: 420)` on the picker so the popover has a stable size. The `List` scrolls internally.
- iOS pushed view: no frame override — fills the sheet.

## Wiring back to `TransactionFilterView`

`TransactionFilterView` already owns `@State private var selectedCategoryIds: Set<UUID>`. The picker writes to a `Binding` of that state. The existing `applyFilter()` reads it unchanged. Removing the inline toggle list also removes `allCategories` (it moves into the picker).

## Testing

- **`CategoriesMultiSelectTests` (new, Swift Testing, in `MoolahTests/Domain/`).** Pure unit tests against the new `Categories` extension helpers — no view rendering. Drives the helpers with a small in-memory `Categories` value:
  - `descendants(of:)` returns every descendant in a deeper-than-one-level tree, excludes self, and returns `[]` for a leaf.
  - "Select all" path (caller-side): `formUnion([id] + descendants(of: id).map(\.id))` adds parent + all descendants and leaves unrelated selections alone.
  - "Deselect all" path: `subtract([id] + descendants(of: id).map(\.id))` is the exact inverse.
  - `selectionSummary(for:)`: empty → `"All"`, 1 present id → full path, 2+ present ids → `"N selected"`, orphaned ids excluded from count.
- **No new tests for search filtering.** Substring match against `categories.path(for:)` is a one-liner using existing API; test coverage on the helper exists already.
- **Existing tests stay green.** `TransactionFilterTests` and `TransactionRepositoryFilterTests` are unaffected — semantics don't change.
- **Manual verification on macOS:**
  - Filter sheet opens at its previous size with a real category list (currently broken).
  - Trigger row's summary text updates as toggles flip.
  - Popover sizes correctly, search filters as typed, right-click on a parent reveals the context menu, "Select all in <Parent>" toggles the whole subtree.
  - Cancel / Apply / Clear All toolbar buttons remain visible and reachable.
- **Manual verification on iOS Simulator:** push/pop, long-press context menu, sheet-internal navigation back-button.

## Risks and edge cases

- **Empty categories.** The picker shows the existing "No categories available" placeholder — same string the inline section already used.
- **Search clearing selection state.** Toggles in the filtered list operate on the same `selectedIds` set, so dropping out of search doesn't lose selection. Verified by the helper test that selection mutations don't depend on which view is rendered.
- **Long category paths.** `Truncated mode` (`.lineLimit(1)` + `.truncationMode(.middle)`) on the row label and on the trigger-row summary. The summary already handles 2+ via a count, so the truncation only matters for the single-selection case.
- **Popover dismissal on outside click.** SwiftUI handles this; selection is already committed live, so no special "are you sure" handling is needed.
- **Stale selection.** If a category is deleted after selection (rare), the id stays in `selectedIds` but no row renders for it. The existing filter already tolerates orphaned ids; the trigger summary just counts the still-present ids — see Implementation Note below.
- **Discoverability of the context menu.** Acknowledged trade-off; rejected the visible-affordance alternatives (per-row "select subtree" buttons, `DisclosureGroup` parent rows) because both clutter every parent row for an action most users invoke rarely. Right-click / long-press is the standard secondary-action gesture on both platforms.

**Implementation note.** The summary string counts ids that are present in `categories.byId` (i.e., still exist). Orphaned ids in `selectedIds` are excluded from the count; the filter still applies them, but the user-visible "N selected" matches what's actually pickable. This is a one-line filter and gets a unit test.

## Rollout

Single PR. No migration, no feature flag — pure UI restructure on top of unchanged state. The inline-toggle code path is removed, not deprecated; there's no backwards-compatibility surface to preserve.

## Out of scope (future work)

- **Subtree-as-semantics.** Making "select Groceries" implicitly match "Groceries → Costco" too is a `TransactionFilter` change, not a UI change. Worth doing, but separately, with its own test impact on `TransactionRepositoryFilterTests`.
- **Other filter sheets.** If/when reports or analysis grow a multi-category filter, they reuse `CategoryMultiSelectPicker`. Not built speculatively; refactor when the second consumer arrives.
