# Category full-path display — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show `Categories.path(for:)` (e.g. `Income:Salary:Adrian`) instead of leaf `category.name` everywhere outside the category-management screens.

**Architecture:** `Categories.path(for:)` already exists in `Domain/Models/Category.swift`. The work is (a) one structural rename — `BudgetLineItem.categoryName: String` → `categoryPath: String` — plus its four consumers, and (b) mechanical call-site swaps in ~8 view files. `CategoriesView`, `CategoryTreeView`, and `CategoryDetailView` are out of scope; they display hierarchy structurally and keep leaf names.

**Tech Stack:** Swift 6, SwiftUI, Swift Testing (`#expect`). Build via `just build-mac`, test via `just test-mac` (macOS-only suite is sufficient for this UI + domain change; full `just test` runs at the end).

**Spec:** `plans/2026-04-24-category-full-path-design.md`.

---

## Task 1: Rename `BudgetLineItem.categoryName` → `categoryPath`, populate via full path (TDD)

**Files:**
- Modify: `Domain/Models/BudgetLineItem.swift` (field rename + populate with `categories.path(for:)`)
- Modify: `MoolahTests/Features/BudgetLineItemMergeTests.swift` (rename field reads; add nested-path test)
- Modify: `Features/Earmarks/Views/EarmarkBudgetSectionView.swift:75, 161, 177, 185` (consumer reads)
- Modify: `Features/Earmarks/Views/EditBudgetAmountSheet.swift:28` (consumer read)

- [ ] **Step 1: Add failing test for nested-path population**

Append to `MoolahTests/Features/BudgetLineItemMergeTests.swift`, inside the `@Suite("BudgetLineItem Merge") struct BudgetLineItemMergeTests`:

```swift
@Test
func testLineItemUsesFullCategoryPath() {
  let parentId = UUID()
  let childId = UUID()
  let categories = Categories(from: [
    Category(id: parentId, name: "Income"),
    Category(id: childId, name: "Salary", parentId: parentId),
  ])
  let budgetItems = [
    EarmarkBudgetItem(
      categoryId: childId,
      amount: InstrumentAmount(
        quantity: Decimal(10000) / 100, instrument: Instrument.defaultTestInstrument))
  ]

  let result = BudgetLineItem.buildLineItems(
    budgetItems: budgetItems,
    categoryBalances: [:],
    categories: categories,
    earmarkInstrument: .defaultTestInstrument
  )

  #expect(result.first?.categoryPath == "Income:Salary")
}
```

- [ ] **Step 2: Rename existing test assertions from `categoryName` → `categoryPath`**

In `MoolahTests/Features/BudgetLineItemMergeTests.swift`, replace every read of `.categoryName` on a `BudgetLineItem` with `.categoryPath`. These are on the following test methods:

- `testMergeCombinesBudgetAndActuals` — `result.first?.categoryName == "Flights"` → `result.first?.categoryPath == "Flights"` (single root category; path equals leaf).
- `testMergeSortsByCategoryName` — `result.map(\.categoryName) == ["Alpha", "Middle", "Zebra"]` → `result.map(\.categoryPath) == ["Alpha", "Middle", "Zebra"]`. Also rename the method to `testMergeSortsByCategoryPath` for accuracy.
- `testUnknownCategoryNameForDeletedCategory` — `result.first?.categoryName == "Unknown"` → `result.first?.categoryPath == "Unknown"`.

- [ ] **Step 3: Run tests to confirm they fail**

Run: `just test-mac BudgetLineItemMergeTests 2>&1 | tee .agent-tmp/test-bli.txt`

Expected: compile error — `BudgetLineItem` has no member `categoryPath`.

- [ ] **Step 4: Rename field and use `categories.path(for:)` in builder**

Edit `Domain/Models/BudgetLineItem.swift`:

1. Line 5: rename `let categoryName: String` → `let categoryPath: String`.
2. Lines 30 and 44: the current lookup is
   ```swift
   let name = categories.by(id: item.categoryId)?.name ?? "Unknown"
   ```
   (line 44 uses `categoryId` instead of `item.categoryId`). Replace both with the path equivalent:
   ```swift
   let path = categories.by(id: item.categoryId).map { categories.path(for: $0) } ?? "Unknown"
   ```
   and for the second site:
   ```swift
   let path = categories.by(id: categoryId).map { categories.path(for: $0) } ?? "Unknown"
   ```
3. Lines 36 and 48: change init arg label from `categoryName: name` to `categoryPath: path`.
4. Line 54: change the sort key from `$0.categoryName < $1.categoryName` to `$0.categoryPath < $1.categoryPath`.

- [ ] **Step 5: Update consumers**

Edit `Features/Earmarks/Views/EarmarkBudgetSectionView.swift`:
- Line 75: `Text("Remove \(item.categoryName) from the budget?")` → `Text("Remove \(item.categoryPath) from the budget?")`
- Line 161: `Text(lineItem.categoryName)` → `Text(lineItem.categoryPath)`
- Line 177: `.accessibilityLabel("Edit budget for \(lineItem.categoryName)")` → `.accessibilityLabel("Edit budget for \(lineItem.categoryPath)")`
- Line 185: `"\(lineItem.categoryName): spent ..."` → `"\(lineItem.categoryPath): spent ..."`

Edit `Features/Earmarks/Views/EditBudgetAmountSheet.swift`:
- Line 28: `Section("Budget for \(lineItem.categoryName)")` → `Section("Budget for \(lineItem.categoryPath)")`

- [ ] **Step 6: Run tests and build to confirm green**

Run:
```bash
just test-mac BudgetLineItemMergeTests 2>&1 | tee .agent-tmp/test-bli.txt
just build-mac 2>&1 | tee .agent-tmp/build-mac.txt
```

Expected: all `BudgetLineItemMergeTests` pass; `just build-mac` succeeds with no warnings.

- [ ] **Step 7: Clean up temp files**

```bash
rm -f .agent-tmp/test-bli.txt .agent-tmp/build-mac.txt
```

---

## Task 2: View-only path swaps in transaction + reports + filter + import views

**Files:**
- Modify: `Features/Transactions/Views/TransactionRowView.swift:131`
- Modify: `Features/Transactions/Views/UpcomingTransactionRow.swift:64, 119`
- Modify: `Features/Transactions/Views/TransactionFilterView.swift:158`
- Modify: `Features/Reports/Views/ReportsView.swift:104`
- Modify: `Features/Reports/Views/CategoryBalanceTable.swift:40`
- Modify: `Features/Import/Views/RuleEditorActionRow.swift:36`

Each change is a single-line substitution. No new logic.

- [ ] **Step 1: `TransactionRowView.swift:131`**

Current:
```swift
return uniqueIds.compactMap { categories.by(id: $0)?.name }
```
Replace with:
```swift
return uniqueIds.compactMap { id in categories.by(id: id).map { categories.path(for: $0) } }
```

- [ ] **Step 2: `UpcomingTransactionRow.swift:64`**

Current:
```swift
Text(category.name).font(.caption).foregroundStyle(.secondary)
```
Replace with:
```swift
Text(categories.path(for: category)).font(.caption).foregroundStyle(.secondary)
```

- [ ] **Step 3: `UpcomingTransactionRow.swift:119`**

Current (inside the accessibility `categoryNames` computed property):
```swift
.compactMap { categories.by(id: $0)?.name }
```
Replace with:
```swift
.compactMap { id in categories.by(id: id).map { categories.path(for: $0) } }
```

- [ ] **Step 4: `TransactionFilterView.swift:158`**

The view has `let categories: Categories` (line 8) and iterates `allCategories: [Category]` — the `Categories` lookup is in scope as `categories`. Replace the label on line 158:
- From `category.name,`
- To `categories.path(for: category),`

- [ ] **Step 5: `ReportsView.swift:104`**

Current:
```swift
let categoryName = categories.by(id: drillDown.categoryId)?.name ?? "Category"
```
Replace with:
```swift
let categoryName = categories.by(id: drillDown.categoryId).map { categories.path(for: $0) } ?? "Category"
```

The local identifier `categoryName` stays as-is to minimise the diff; it now holds a path.

- [ ] **Step 6: `CategoryBalanceTable.swift:40`**

Current:
```swift
name: categories.by(id: categoryId)?.name ?? "Unknown",
```
Replace with:
```swift
name: categories.by(id: categoryId).map { categories.path(for: $0) } ?? "Unknown",
```

- [ ] **Step 7: `RuleEditorActionRow.swift:36`**

The view has `let categories: Categories` (line 10) and iterates `flatCategories: [Category]` derived from it. Replace line 36:
- From `Text(category.name).tag(category.id)`
- To `Text(categories.path(for: category)).tag(category.id)`

- [ ] **Step 8: Build**

Run: `just build-mac 2>&1 | tee .agent-tmp/build-mac.txt`

Expected: success, no warnings. Any "ambiguous reference" or "value of type `Category` has no member `path`" is a typo — the code should always be `categories.path(for: category)`, never `category.path(...)`.

- [ ] **Step 9: Clean up**

```bash
rm -f .agent-tmp/build-mac.txt
```

---

## Task 3: Rename chart helpers `categoryName(for:)` → `categoryLabel(for:)` and use paths

**Files:**
- Modify: `Features/Analysis/Views/CategoriesOverTimeCard.swift:56, 77, 119, 130, 136` (helper definition + 4 call sites)
- Modify: `Features/Analysis/Views/ExpenseBreakdownCard.swift:45, 70, 82, 108` (helper definition + 3 call sites)

- [ ] **Step 1: `CategoriesOverTimeCard.swift` helper definition (line 136)**

The current helper (near line 136) looks like:
```swift
private func categoryName(for id: UUID?) -> String {
  guard let id, let category = categories.by(id: id) else { return "Uncategorized" }
  return category.name
}
```

Replace with (renaming, and using the path):
```swift
private func categoryLabel(for id: UUID?) -> String {
  guard let id, let category = categories.by(id: id) else { return "Uncategorized" }
  return categories.path(for: category)
}
```

Preserve the existing fallback string verbatim — whether it's `"Uncategorized"`, `"Unknown"`, or something else, copy it. Read the two lines around line 136 before editing.

- [ ] **Step 2: Update all four `categoryName(for:)` call sites in `CategoriesOverTimeCard.swift`**

Lines 56, 77, 119, 130 — replace `categoryName(for:` with `categoryLabel(for:`. (A file-wide find/replace on this file is safe because no other symbol named `categoryName` exists in it.)

- [ ] **Step 3: `ExpenseBreakdownCard.swift` helper definition (line 108)**

Same treatment as Step 1: rename `categoryName(for:)` → `categoryLabel(for:)` and change the final `return category.name` to `return categories.path(for: category)`. Preserve the existing fallback string.

- [ ] **Step 4: Update all three `categoryName(for:)` call sites in `ExpenseBreakdownCard.swift`**

Lines 45, 70, 82 — replace `categoryName(for:` with `categoryLabel(for:`.

- [ ] **Step 5: Build**

Run: `just build-mac 2>&1 | tee .agent-tmp/build-mac.txt`

Expected: success, no warnings. A "`categoryName` is not defined" error means one of the call-site replacements was missed — grep the two files for `categoryName(for:` and update any remaining hit.

- [ ] **Step 6: Clean up**

```bash
rm -f .agent-tmp/build-mac.txt
```

---

## Task 4: Format, full test, commit, push, open PR, add to merge queue

- [ ] **Step 1: Format**

Run: `just format`

No assertion beyond "exits 0". If `just format-check` afterwards still fails, investigate the specific violation — do NOT edit `.swiftlint-baseline.yml`.

- [ ] **Step 2: Full test suite**

Run: `just test 2>&1 | tee .agent-tmp/test-full.txt`

Expected: all suites green on both iOS simulator and macOS. Scan with `grep -iE 'failed|error:' .agent-tmp/test-full.txt` — any hit must be investigated, not ignored. Do NOT proceed to commit until the suite is green.

- [ ] **Step 3: Commit**

```bash
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/category-full-path add -A
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/category-full-path commit -m "$(cat <<'EOF'
feat(categories): show full category path everywhere outside the category-management screens

Leaf-only category labels (e.g. "Adrian") are ambiguous when the same leaf appears under multiple parents. Every display surface outside the category-management screens now uses `Categories.path(for:)` (e.g. "Income:Salary:Adrian").

- Rename `BudgetLineItem.categoryName` → `categoryPath`; populate via `categories.path(for:)`.
- Swap `category.name` for `categories.path(for:)` in TransactionRowView, UpcomingTransactionRow, TransactionFilterView, ReportsView, CategoryBalanceTable, RuleEditorActionRow.
- Rename chart helpers `categoryName(for:)` → `categoryLabel(for:)` in CategoriesOverTimeCard and ExpenseBreakdownCard; they now return the path.
- `CategoriesView`, `CategoryTreeView`, and the parent field in `CategoryDetailView` are unchanged — those screens already convey hierarchy structurally.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

- [ ] **Step 4: Push branch**

```bash
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/category-full-path push -u origin feat/category-full-path
```

- [ ] **Step 5: Open PR**

```bash
gh pr create --title "feat(categories): show full category path everywhere outside the category-management screens" --body "$(cat <<'EOF'
## Summary
- Leaf-only category labels like "Adrian" are ambiguous when the same leaf appears under multiple parents. Every display surface outside the category-management screens now shows the full colon-separated path (e.g. `Income:Salary:Adrian`) via the existing `Categories.path(for:)` helper.
- Structural rename: `BudgetLineItem.categoryName` → `categoryPath`, populated at build time via `categories.path(for:)`. Four consumers updated.
- Thin-view substitutions in `TransactionRowView`, `UpcomingTransactionRow`, `TransactionFilterView`, `ReportsView`, `CategoryBalanceTable`, `RuleEditorActionRow`.
- Chart helpers renamed: `categoryName(for:)` → `categoryLabel(for:)` in `CategoriesOverTimeCard` and `ExpenseBreakdownCard` so the changed meaning is visible at call sites.
- Out of scope: `CategoriesView`, `CategoryTreeView`, and the parent field in `CategoryDetailView` keep leaf names — those screens convey hierarchy structurally.

## Test plan
- [x] New unit test: `BudgetLineItemMergeTests.testLineItemUsesFullCategoryPath` verifies a nested category produces `categoryPath == "Income:Salary"`.
- [x] Existing `BudgetLineItemMergeTests` updated to read `categoryPath` instead of `categoryName`.
- [x] `just test` green (macOS + iOS).
- [x] `just format-check` green.
- [ ] Manual spot-check post-merge: transaction list, upcoming transactions, reports drill-down, transaction filter, import-rule picker, earmark budget section, expense-breakdown chart legend.

Spec: `plans/2026-04-24-category-full-path-design.md`.
Plan: `plans/2026-04-24-category-full-path-implementation.md`.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

Capture the PR number from the URL gh returns.

- [ ] **Step 6: Add to merge queue**

Invoke the `merge-queue` skill with the captured PR number. Do NOT merge manually.

- [ ] **Step 7: Clean up**

```bash
rm -f .agent-tmp/test-full.txt
```
