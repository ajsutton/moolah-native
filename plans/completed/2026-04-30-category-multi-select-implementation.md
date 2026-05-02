# Category multi-select picker — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the inline-toggle Categories section in `TransactionFilterView` with a dedicated multi-select picker (popover on macOS, NavigationLink push on iOS) that scales to any number of categories.

**Architecture:** Two pure helpers on `Categories` (`descendants(of:)`, `selectionSummary(for:)`) keep mutation/formatting logic testable outside the view. The picker view (`CategoryMultiSelectPicker`) renders a searchable list of categories from `Categories.flattenedByPath()`, indented by colon-count when idle and flat with full paths when filtering. Parent rows expose a `.contextMenu` with subtree select/deselect; the primary toggle still mutates a single id at a time. The filter sheet's existing `selectedCategoryIds` state and Apply/Cancel/Clear-All toolbar are unchanged.

**Tech Stack:** SwiftUI (iOS 26+, macOS 26+), Swift Testing for unit tests, no new dependencies.

**Spec:** `plans/2026-04-30-category-multi-select-design.md` (committed in this branch).

**Working directory:** This plan is to be executed inside the worktree at `.worktrees/category-multi-select/` on branch `design/category-multi-select`. All `git`, `just`, and file paths are relative to that worktree root.

---

## File map

- **Modify** `Domain/Models/Category.swift` — add two methods on `Categories`: `descendants(of:)`, `selectionSummary(for:)`.
- **Modify** `MoolahTests/Domain/CategoriesTests.swift` — add tests for both helpers.
- **Create** `Features/Transactions/Views/CategoryMultiSelectPicker.swift` — the searchable, hierarchical multi-select picker view, including its `#Preview`.
- **Modify** `Features/Transactions/Views/TransactionFilterView.swift` — replace the inline toggle list with a single trigger row hosting the picker (popover on macOS, `NavigationLink` on iOS); remove the now-unused `allCategories` computed property.

No `project.yml` edits required — `Features/` and `MoolahTests/` are already auto-globbed, and `just test` / `just build-mac` regenerate the Xcode project automatically.

---

## Task 1: Add `Categories.descendants(of:)` (TDD)

**Files:**
- Modify: `MoolahTests/Domain/CategoriesTests.swift`
- Modify: `Domain/Models/Category.swift`

- [ ] **Step 1.1: Write the failing tests**

Append to `MoolahTests/Domain/CategoriesTests.swift` (inside `struct CategoriesTests { … }`, before the closing brace):

```swift
@Test
func descendantsOfLeafCategoryIsEmpty() {
  let leaf = Category(name: "Groceries")
  let categories = Categories(from: [leaf])

  #expect(categories.descendants(of: leaf.id).isEmpty)
}

@Test
func descendantsOfParentReturnsDirectChildren() {
  let groceries = Category(name: "Groceries")
  let costco = Category(name: "Costco", parentId: groceries.id)
  let farmers = Category(name: "Farmers Market", parentId: groceries.id)
  let categories = Categories(from: [groceries, costco, farmers])

  let names = Set(categories.descendants(of: groceries.id).map(\.name))

  #expect(names == ["Costco", "Farmers Market"])
}

@Test
func descendantsOfDeepParentReturnsAllLevels() {
  let income = Category(name: "Income")
  let salary = Category(name: "Salary", parentId: income.id)
  let janet = Category(name: "Janet", parentId: salary.id)
  let adrian = Category(name: "Adrian", parentId: salary.id)
  let categories = Categories(from: [income, salary, janet, adrian])

  let names = Set(categories.descendants(of: income.id).map(\.name))

  #expect(names == ["Salary", "Janet", "Adrian"])
}

@Test
func descendantsExcludesSelfAndUnrelatedSubtrees() {
  let groceries = Category(name: "Groceries")
  let costco = Category(name: "Costco", parentId: groceries.id)
  let transport = Category(name: "Transport")
  let fuel = Category(name: "Fuel", parentId: transport.id)
  let categories = Categories(from: [groceries, costco, transport, fuel])

  let descendants = categories.descendants(of: groceries.id)
  let ids = Set(descendants.map(\.id))

  #expect(ids == [costco.id])
  #expect(!ids.contains(groceries.id))
  #expect(!ids.contains(transport.id))
  #expect(!ids.contains(fuel.id))
}
```

- [ ] **Step 1.2: Run the tests and confirm they fail**

```bash
mkdir -p .agent-tmp
just test-mac CategoriesTests 2>&1 | tee .agent-tmp/cat-tests.txt
grep -i 'failed\|error:' .agent-tmp/cat-tests.txt
```

Expected: build error — "value of type 'Categories' has no member 'descendants'".

- [ ] **Step 1.3: Implement `descendants(of:)`**

Append inside the `Categories` struct in `Domain/Models/Category.swift`, immediately before the `FlatEntry` declaration:

```swift
/// All descendants of a given category, depth-first; excludes the category itself.
func descendants(of parentId: UUID) -> [Category] {
  var result: [Category] = []
  for child in children(of: parentId) {
    result.append(child)
    result.append(contentsOf: descendants(of: child.id))
  }
  return result
}
```

- [ ] **Step 1.4: Re-run tests and confirm they pass**

```bash
just test-mac CategoriesTests 2>&1 | tee .agent-tmp/cat-tests.txt
grep -i 'failed\|error:' .agent-tmp/cat-tests.txt
```

Expected: no output from grep (zero failures, zero errors).

- [ ] **Step 1.5: Commit**

```bash
git -C . add Domain/Models/Category.swift MoolahTests/Domain/CategoriesTests.swift
git -C . commit -m "feat(categories): add descendants(of:) helper"
```

---

## Task 2: Add `Categories.selectionSummary(for:)` (TDD)

**Files:**
- Modify: `MoolahTests/Domain/CategoriesTests.swift`
- Modify: `Domain/Models/Category.swift`

- [ ] **Step 2.1: Write the failing tests**

Append to `MoolahTests/Domain/CategoriesTests.swift` (inside `struct CategoriesTests { … }`):

```swift
@Test
func selectionSummaryEmptyReturnsAll() {
  let categories = Categories(from: [Category(name: "Groceries")])

  #expect(categories.selectionSummary(for: []) == "All")
}

@Test
func selectionSummarySingleSelectionReturnsFullPath() {
  let income = Category(name: "Income")
  let salary = Category(name: "Salary", parentId: income.id)
  let categories = Categories(from: [income, salary])

  #expect(categories.selectionSummary(for: [salary.id]) == "Income:Salary")
}

@Test
func selectionSummaryMultipleSelectionReturnsCount() {
  let g = Category(name: "Groceries")
  let t = Category(name: "Transport")
  let i = Category(name: "Income")
  let categories = Categories(from: [g, t, i])

  #expect(categories.selectionSummary(for: [g.id, t.id]) == "2 selected")
  #expect(categories.selectionSummary(for: [g.id, t.id, i.id]) == "3 selected")
}

@Test
func selectionSummaryIgnoresOrphanedIds() {
  let g = Category(name: "Groceries")
  let categories = Categories(from: [g])
  let orphan = UUID()

  // One real id + one orphan → still "single" semantics, returns the real path.
  #expect(categories.selectionSummary(for: [g.id, orphan]) == "Groceries")
  // Two orphans → "All" because no present ids remain.
  #expect(categories.selectionSummary(for: [orphan, UUID()]) == "All")
}
```

- [ ] **Step 2.2: Run the tests and confirm they fail**

```bash
just test-mac CategoriesTests 2>&1 | tee .agent-tmp/cat-tests.txt
grep -i 'failed\|error:' .agent-tmp/cat-tests.txt
```

Expected: build error — "value of type 'Categories' has no member 'selectionSummary'".

- [ ] **Step 2.3: Implement `selectionSummary(for:)`**

Append inside the `Categories` struct in `Domain/Models/Category.swift`, immediately after the `descendants(of:)` method:

```swift
/// Human-readable summary of a multi-category selection. Returns
/// `"All"` when nothing is selected (or every selected id is orphaned),
/// the full path when exactly one selected id is still present, and
/// `"\(N) selected"` when two or more selected ids are still present.
func selectionSummary(for selectedIds: Set<UUID>) -> String {
  let presentIds = selectedIds.filter { byId[$0] != nil }
  switch presentIds.count {
  case 0:
    return "All"
  case 1:
    let id = presentIds.first!  // safe: count == 1
    return path(for: byId[id]!)
  default:
    return "\(presentIds.count) selected"
  }
}
```

(The two `!` are gated by the `count` check above; this matches the project's existing optional-handling style for guarded lookups in `path(for:)`.)

- [ ] **Step 2.4: Re-run tests and confirm they pass**

```bash
just test-mac CategoriesTests 2>&1 | tee .agent-tmp/cat-tests.txt
grep -i 'failed\|error:' .agent-tmp/cat-tests.txt
```

Expected: no output from grep.

- [ ] **Step 2.5: Commit**

```bash
git -C . add Domain/Models/Category.swift MoolahTests/Domain/CategoriesTests.swift
git -C . commit -m "feat(categories): add selectionSummary(for:) helper"
```

---

## Task 3: Build `CategoryMultiSelectPicker` view (no context menu yet)

**Files:**
- Create: `Features/Transactions/Views/CategoryMultiSelectPicker.swift`

- [ ] **Step 3.1: Create the picker view**

Create `Features/Transactions/Views/CategoryMultiSelectPicker.swift` with:

```swift
import SwiftUI

/// Searchable, hierarchical multi-select picker for categories.
/// Hosted as a popover on macOS and pushed via `NavigationLink` on iOS.
struct CategoryMultiSelectPicker: View {
  let categories: Categories
  @Binding var selectedIds: Set<UUID>

  @State private var searchText: String = ""

  var body: some View {
    VStack(spacing: 0) {
      header
      list
    }
    .searchable(text: $searchText, prompt: "Search categories")
    #if os(iOS)
      .navigationTitle("Categories")
      .navigationBarTitleDisplayMode(.inline)
    #endif
  }

  private var header: some View {
    HStack {
      Spacer()
      Button("Clear") { selectedIds.removeAll() }
        .disabled(selectedIds.isEmpty)
    }
    .padding(.horizontal)
    .padding(.vertical, 8)
  }

  private var list: some View {
    List {
      if categories.roots.isEmpty {
        Text("No categories available").foregroundStyle(.secondary)
      } else if visibleEntries.isEmpty {
        Text("No matches").foregroundStyle(.secondary)
      } else {
        ForEach(visibleEntries, id: \.category.id) { entry in
          row(for: entry)
        }
      }
    }
  }

  private var visibleEntries: [Categories.FlatEntry] {
    let all = categories.flattenedByPath()
    guard !searchText.isEmpty else { return all }
    return all.filter { $0.path.localizedCaseInsensitiveContains(searchText) }
  }

  private func indentLevel(for entry: Categories.FlatEntry) -> Int {
    searchText.isEmpty ? entry.path.split(separator: ":").count - 1 : 0
  }

  @ViewBuilder
  private func row(for entry: Categories.FlatEntry) -> some View {
    let label = searchText.isEmpty ? entry.category.name : entry.path
    Toggle(
      isOn: Binding(
        get: { selectedIds.contains(entry.category.id) },
        set: { isOn in
          if isOn {
            selectedIds.insert(entry.category.id)
          } else {
            selectedIds.remove(entry.category.id)
          }
        }
      )
    ) {
      Text(label)
        .lineLimit(1)
        .truncationMode(.middle)
        .padding(.leading, CGFloat(indentLevel(for: entry) * 16))
    }
  }
}

#Preview {
  let groceries = Category(name: "Groceries")
  let costco = Category(name: "Costco", parentId: groceries.id)
  let farmers = Category(name: "Farmers Market", parentId: groceries.id)
  let transport = Category(name: "Transport")
  let fuel = Category(name: "Fuel", parentId: transport.id)

  let categories = Categories(from: [
    groceries, costco, farmers, transport, fuel,
  ])

  @Previewable @State var selected: Set<UUID> = [costco.id]

  return CategoryMultiSelectPicker(
    categories: categories,
    selectedIds: $selected
  )
  .frame(width: 320, height: 420)
}
```

- [ ] **Step 3.2: Build and verify the preview renders**

```bash
just build-mac 2>&1 | tee .agent-tmp/build.txt
grep -i 'error:\|warning:' .agent-tmp/build.txt | grep -v "Preview"
```

Expected: no output (zero non-`#Preview` warnings, zero errors). If warnings appear in user code, fix them per CLAUDE.md "Common Warning Fixes" before continuing.

- [ ] **Step 3.3: Manual visual check via Xcode preview**

Open `CategoryMultiSelectPicker.swift` in Xcode and confirm the preview canvas renders: a list of `Groceries → Costco → Farmers Market → Transport → Fuel` with `Costco` toggled on, indented children, a working "Clear" button, and a search field that filters as you type.

(The user iterates on UI via `#Preview` per their workflow, not by relaunching the app.)

- [ ] **Step 3.4: Commit**

```bash
git -C . add Features/Transactions/Views/CategoryMultiSelectPicker.swift
git -C . commit -m "feat(transactions): add CategoryMultiSelectPicker view"
```

---

## Task 4: Wire the picker into `TransactionFilterView`

**Files:**
- Modify: `Features/Transactions/Views/TransactionFilterView.swift`

- [ ] **Step 4.1: Add picker presentation state and remove `allCategories`**

In `TransactionFilterView.swift`, add a new `@State` declaration alongside the existing ones (right after `@State private var payeeText: String = ""`):

```swift
@State private var showCategoryPicker = false
```

Then **remove** the `allCategories` computed property (currently lines 44–51):

```swift
// DELETE THIS BLOCK:
private var allCategories: [Category] {
  var result: [Category] = []
  for root in categories.roots {
    result.append(root)
    result.append(contentsOf: categories.children(of: root.id))
  }
  return result
}
```

- [ ] **Step 4.2: Replace `categoriesSection` with the trigger row**

Replace the existing `categoriesSection` (currently lines 151–171) with:

```swift
private var categoriesSection: some View {
  Section("Categories") {
    if categories.roots.isEmpty {
      Text("No categories available").foregroundStyle(.secondary)
    } else {
      categoryPickerRow
    }
  }
}

@ViewBuilder
private var categoryPickerRow: some View {
  let summary = categories.selectionSummary(for: selectedCategoryIds)
  #if os(macOS)
    Button {
      showCategoryPicker = true
    } label: {
      LabeledContent("Categories", value: summary)
    }
    .buttonStyle(.plain)
    .popover(isPresented: $showCategoryPicker, arrowEdge: .trailing) {
      CategoryMultiSelectPicker(
        categories: categories,
        selectedIds: $selectedCategoryIds
      )
      .frame(width: 320, height: 420)
    }
  #else
    NavigationLink {
      CategoryMultiSelectPicker(
        categories: categories,
        selectedIds: $selectedCategoryIds
      )
    } label: {
      LabeledContent("Categories", value: summary)
    }
  #endif
}
```

- [ ] **Step 4.3: Build and check warnings**

```bash
just build-mac 2>&1 | tee .agent-tmp/build.txt
grep -i 'error:\|warning:' .agent-tmp/build.txt | grep -v "Preview"
```

Expected: no output. Fix any warnings before continuing.

- [ ] **Step 4.4: Manual verification on macOS**

```bash
just run-mac
```

In the app:
- Open the transaction list, click the Filter toolbar button. Sheet opens at its previous size; toolbar buttons (Cancel / Apply / Clear All) are visible.
- The Categories section shows a single row with the summary ("All" with no selection).
- Click the row → popover opens anchored to the row.
- Toggle 2+ categories → close popover → row reads "N selected".
- Toggle exactly one → row reads the full path of that category.
- Type in the popover search field → list filters and shows full paths.
- Click "Clear" in the popover header → all selections cleared, summary reverts to "All".
- Click Apply → filter applies, sheet closes.

If anything is off, stop and fix before proceeding.

- [ ] **Step 4.5: Commit**

```bash
git -C . add Features/Transactions/Views/TransactionFilterView.swift
git -C . commit -m "feat(transactions): host CategoryMultiSelectPicker in filter sheet"
```

---

## Task 5: Add subtree shortcut via `.contextMenu` on parent rows

**Files:**
- Modify: `Features/Transactions/Views/CategoryMultiSelectPicker.swift`

- [ ] **Step 5.1: Add the context menu to parent rows**

In `CategoryMultiSelectPicker.swift`, replace the `row(for:)` method with:

```swift
@ViewBuilder
private func row(for entry: Categories.FlatEntry) -> some View {
  let label = searchText.isEmpty ? entry.category.name : entry.path
  let isParent = !categories.children(of: entry.category.id).isEmpty
  Toggle(
    isOn: Binding(
      get: { selectedIds.contains(entry.category.id) },
      set: { isOn in
        if isOn {
          selectedIds.insert(entry.category.id)
        } else {
          selectedIds.remove(entry.category.id)
        }
      }
    )
  ) {
    Text(label)
      .lineLimit(1)
      .truncationMode(.middle)
      .padding(.leading, CGFloat(indentLevel(for: entry) * 16))
  }
  .contextMenu {
    if isParent {
      Button("Select all in \(entry.category.name)") {
        selectSubtree(of: entry.category)
      }
      Button("Deselect all in \(entry.category.name)") {
        deselectSubtree(of: entry.category)
      }
    }
  }
}

private func selectSubtree(of category: Category) {
  selectedIds.insert(category.id)
  selectedIds.formUnion(categories.descendants(of: category.id).map(\.id))
}

private func deselectSubtree(of category: Category) {
  selectedIds.remove(category.id)
  selectedIds.subtract(categories.descendants(of: category.id).map(\.id))
}
```

The `.contextMenu` is attached unconditionally so SwiftUI can register the gesture, but its body only renders the buttons when `isParent` is true. For leaf rows the menu is empty and SwiftUI does not present it.

- [ ] **Step 5.2: Build and check warnings**

```bash
just build-mac 2>&1 | tee .agent-tmp/build.txt
grep -i 'error:\|warning:' .agent-tmp/build.txt | grep -v "Preview"
```

Expected: no output.

- [ ] **Step 5.3: Manual verification on macOS**

```bash
just run-mac
```

In the filter sheet's category popover:
- Right-click a parent row (e.g. `Groceries`) → menu shows `Select all in Groceries` and `Deselect all in Groceries`.
- Choose `Select all in Groceries` → parent and every descendant become selected; the Apply-row summary updates accordingly when you close the popover.
- Choose `Deselect all in Groceries` → parent and every descendant become deselected; unrelated selections (e.g. categories under `Transport`) are untouched.
- Right-click a leaf row (e.g. `Costco`) → no menu appears (or appears empty depending on SwiftUI behaviour) — primary toggle still works.

- [ ] **Step 5.4: Commit**

```bash
git -C . add Features/Transactions/Views/CategoryMultiSelectPicker.swift
git -C . commit -m "feat(transactions): add subtree context-menu to category picker"
```

---

## Task 6: Format, full test run, review agents

- [ ] **Step 6.1: Format**

```bash
just format
git -C . diff --stat
```

If the diff touches files outside this PR's scope, stop — that means a baseline drift exists pre-PR; revert those files and re-investigate. If the diff only touches files modified in Tasks 1–5, stage them.

- [ ] **Step 6.2: Format check**

```bash
just format-check
```

Expected: exit 0, no output. If it fails, fix the underlying code (do **not** modify `.swiftlint-baseline.yml` — see CLAUDE.md and the `fixing-format-check` skill).

- [ ] **Step 6.3: Run the full test suite**

```bash
just test 2>&1 | tee .agent-tmp/test-output.txt
grep -i 'failed\|error:' .agent-tmp/test-output.txt
```

Expected: no output from grep — both iOS and macOS targets green. If anything fails, fix before continuing.

- [ ] **Step 6.4: Run the `code-review` agent**

Invoke `@code-review` against the touched files (`Domain/Models/Category.swift`, `MoolahTests/Domain/CategoriesTests.swift`, `Features/Transactions/Views/CategoryMultiSelectPicker.swift`, `Features/Transactions/Views/TransactionFilterView.swift`). Apply every Critical / Important / Minor finding (per memory: don't dismiss findings, don't skip Minors). If a finding is genuinely out of scope, ask the user before deferring.

- [ ] **Step 6.5: Run the `ui-review` agent**

Invoke `@ui-review` against `CategoryMultiSelectPicker.swift` and the modified `TransactionFilterView.swift`. Apply findings.

- [ ] **Step 6.6: Re-run tests and format-check after review fixes**

```bash
just format-check && just test 2>&1 | tee .agent-tmp/test-output.txt
grep -i 'failed\|error:' .agent-tmp/test-output.txt
```

Expected: no output from grep, format-check exits 0.

- [ ] **Step 6.7: Commit any review fixes**

If the review agents prompted fixes, commit them with a message describing what was changed (e.g. `refactor(transactions): apply review feedback on category picker`).

- [ ] **Step 6.8: Clean up `.agent-tmp/`**

```bash
rm -f .agent-tmp/cat-tests.txt .agent-tmp/build.txt .agent-tmp/test-output.txt
```

---

## Task 7: Open PR and add to merge queue

- [ ] **Step 7.1: Push the branch (explicit src:dst form, no upstream tracking)**

The worktree was created with `--no-track`, so the branch is not tracking origin/main. Use the explicit `<src>:<dst>` form to avoid any accidental push into a parent branch (per CLAUDE.md "Stacked-PR worktrees" guidance):

```bash
git -C . push origin design/category-multi-select:design/category-multi-select
```

- [ ] **Step 7.2: Open the PR**

```bash
gh pr create \
  --base main \
  --head design/category-multi-select \
  --title "Multi-select picker for transaction filter categories" \
  --body "$(cat <<'EOF'
## Summary
- Replace the inline-toggle Categories section in `TransactionFilterView` with a single trigger row that hosts a dedicated multi-select picker (popover on macOS, NavigationLink push on iOS). With many categories the old section made the filter sheet taller than the screen and pushed the toolbar out of reach; the new picker scales to any number of categories.
- Add two pure helpers on `Categories` so the view stays thin: `descendants(of:)` for subtree traversal and `selectionSummary(for:)` for the trigger-row label. Both are unit-tested.
- Parent rows expose a `.contextMenu` with "Select all in …" / "Deselect all in …" — a discoverable subtree shortcut without per-row chrome. Selection semantics are unchanged: `selectedCategoryIds` stays a flat `Set<UUID>` and Apply still gates the filter.

Design spec: `plans/2026-04-30-category-multi-select-design.md`.

## Test plan
- [x] `just test` passes on iOS and macOS (new helper tests in `CategoriesTests`).
- [x] `just format-check` clean.
- [x] Manual macOS: filter sheet opens at its prior size with toolbar visible; popover anchors to the row; search filters with full-path labels; Clear button works; right-click a parent → "Select all in …" toggles parent + all descendants.
- [x] Manual iOS Simulator: `NavigationLink` push shows the picker full-height inside the sheet; long-press parent reveals the subtree menu.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

Capture the returned PR URL — it's needed for the merge-queue step.

- [ ] **Step 7.3: Add the PR to the merge queue**

Per memory ("every PR opened goes through the merge-queue skill, not manual merge"), invoke the `merge-queue` skill with the PR number from Step 7.2 and let it land the branch on `main`. Do not run `gh pr merge` manually.

- [ ] **Step 7.4: Report the PR URL to the user**

Print the PR URL as a markdown link (`https://github.com/ajsutton/moolah-native/pull/NNN`) so it's clickable.

---

## Notes for the executor

- **Worktree discipline.** All commands run from `.worktrees/category-multi-select/`. Use `git -C .` rather than `cd && git`. Never push to `origin/main` (branch-protected) or to any other branch's remote ref.
- **Test target.** New tests live in `MoolahTests/Domain/`, run via `just test-mac CategoriesTests` (iOS form: `just test-ios CategoriesTests`). The full suite is `just test`.
- **Swift Testing, not XCTest.** Tests use `@Test` and `#expect`, mirroring the existing `CategoriesTests` file.
- **Thin views.** Selection-mutation logic on `selectSubtree(of:)` / `deselectSubtree(of:)` is allowed in the view because it's a one-line orchestration of model helpers (`descendants(of:)` and `Set` operations). Anything more complex would move onto `Categories`.
- **Don't modify `.swiftlint-baseline.yml`.** If `just format-check` reports a violation, fix the underlying code (split, rename, reword) — see the `fixing-format-check` skill.
- **Iterate UI via `#Preview`, not by relaunching the app.** The visual checks in Tasks 3–5 use Xcode's preview canvas (with `mcp__xcode__RenderPreview` when verifying remotely). Manual app launches are reserved for end-to-end flow checks in Steps 4.4 and 5.3.

## Self-review (executed against this plan)

**Spec coverage.** Each spec section maps to a task: trigger row + summary → Task 4 + helper from Task 2; picker view (search, hierarchy, Clear) → Task 3; subtree context menu → Task 5; descendants helper → Task 1; tests → Tasks 1, 2 + Task 6 full-suite run; rollout (single PR) → Task 7. ✅

**Placeholder scan.** Every step has concrete code, exact file paths, exact commands, and expected output. No "TBD" / "similar to" / "implement appropriately" remain. ✅

**Type consistency.** `descendants(of:)` returns `[Category]` consistently in helper code, tests, and call sites in Task 5. `selectionSummary(for:)` takes `Set<UUID>` and returns `String` in helper code, tests, and view call site. `selectedCategoryIds` is the binding name throughout (matches existing `TransactionFilterView` state). `CategoryMultiSelectPicker` props (`categories`, `selectedIds`) match across the picker file, the `#Preview`, and the two host call sites. ✅
