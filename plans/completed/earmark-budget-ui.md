# Earmark Budget Allocation UI — Implementation Plan

## 1. Overview

Add a budget allocation section to `EarmarkDetailView` that shows spending vs. budget per category, allows inline editing of budget amounts, and supports adding new line items. This mirrors the web app's `SpendingBreakdown.vue` component.

## 2. UI Design

### 2.1 Layout within EarmarkDetailView

Insert a new **"Budget"** section via a segmented picker at the top to switch between "Transactions" and "Budget" tabs, keeping the overview panel always visible.

```
┌──────────────────────────────────────────────────┐
│  [Overview Panel: Balance | Saved | Spent]       │
│  [Savings Goal Progress]                         │
├──────────────────────────────────────────────────┤
│  [Transactions]  [Budget]    ← segmented picker  │
├──────────────────────────────────────────────────┤
│  Budget Tab:                                     │
│  ┌──────────────────────────────────────────┐    │
│  │ Category          Actual    Budget  Rem. │    │
│  │ ─────────────────────────────────────────│    │
│  │ Flights          -$500     $800    $300  │    │
│  │ Accommodation    -$200     $600    $400  │    │
│  │ Food & Drink     -$150     $300    $150  │    │
│  │ ─────────────────────────────────────────│    │
│  │ Total            -$850    $1,700   $850  │    │
│  │                                          │    │
│  │ Unallocated              $300     $300   │    │
│  └──────────────────────────────────────────┘    │
│  [+ Add Line Item]                               │
└──────────────────────────────────────────────────┘
```

### 2.2 Budget Row Design

Each row displays:
- **Category name** (left-aligned, `.font(.body)`)
- **Actual** spending amount (right-aligned, `MonetaryAmountView`, red for expenses)
- **Budget** amount (right-aligned, tappable to edit, `.monospacedDigit()`)
- **Remaining** = budget + actual (right-aligned, green if positive, red if over budget)

For v1, show a flat list of budgeted categories. Defer hierarchical grouping to a later iteration.

### 2.3 Edit Budget Amount

When the user taps a budget amount:
- **macOS**: Show a popover with a `TextField` (prefilled with current value) and a confirm button
- **iOS**: Show a sheet with a `TextField` and save/cancel toolbar buttons

Use `MonetaryAmount.parseCents(from:)` for parsing.

### 2.4 Add Line Item

Toolbar button ("+" or "Add Line Item") presents a sheet with:
- Category picker (excluding categories already in the budget)
- Amount text field
- Save/Cancel

### 2.5 Empty State

When no budget items exist:
```swift
ContentUnavailableView(
  "No Budget",
  systemImage: "bookmark",
  description: Text("Tap + to allocate budget to categories")
)
```

### 2.6 Unallocated Row

If the earmark has a `savingsGoal` and `totalBudget < savingsGoal`, show an "Unallocated" row at the bottom with the difference.

---

## 3. Data Flow

### 3.1 Two Data Sources

1. **Budget items** (`[EarmarkBudgetItem]`) — from `EarmarkRepository.fetchBudget(earmarkId:)`
2. **Category expense balances** (`[UUID: Int]`) — from analysis repository filtered by earmark

These are merged into a unified view model per row.

### 3.2 View Model Type

```swift
struct BudgetLineItem: Identifiable {
  let id: UUID              // category ID
  let categoryName: String
  let actual: MonetaryAmount
  let budgeted: MonetaryAmount
  var remaining: MonetaryAmount { budgeted + actual }
}
```

### 3.3 Architecture Decision

Keep budget CRUD methods in `EarmarkStore` (it already has the repository). The budget section view fetches category balances from the analysis repository via `@Environment(BackendProvider.self)` and merges them with the store's budget items. The merging logic goes in a pure function (model extension or utility) that is independently testable.

---

## 4. Files to Create/Modify

### New Files
1. `MoolahTests/Features/EarmarkBudgetTests.swift` — Store tests for budget operations
2. `Features/Earmarks/Views/EarmarkBudgetSectionView.swift` — The budget tab/section view
3. `Features/Earmarks/Views/EditBudgetAmountSheet.swift` — Sheet/popover for editing a budget amount
4. `Features/Earmarks/Views/AddBudgetLineItemSheet.swift` — Sheet for adding a new category to the budget

### Modified Files
5. `Features/Earmarks/EarmarkStore.swift` — Add budget state and methods
6. `Features/Earmarks/Views/EarmarkDetailView.swift` — Add segmented picker and budget section

---

## 5. Tests to Write (TDD Order)

### 5.1 EarmarkStore Budget Tests

1. **`testLoadBudgetPopulatesBudgetItems`** — Load budget items, verify they appear in `store.budgetItems`
2. **`testLoadBudgetSetsIsLoading`** — Verify loading state toggles
3. **`testLoadBudgetHandlesError`** — Verify error is captured when repository throws
4. **`testUpdateBudgetItemModifiesExistingItem`** — Update amount for a category, verify local and repository state
5. **`testUpdateBudgetItemRollsBackOnError`** — If repository throws, optimistic update is reverted
6. **`testAddBudgetItemAppendsToList`** — Add a new category/amount, verify it appears
7. **`testAddBudgetItemCallsRepositoryWithFullList`** — Verify repository receives the complete updated list (PUT takes full `[EarmarkBudgetItem]`)
8. **`testRemoveBudgetItemRemovesFromList`** — Remove a category, verify it's gone
9. **`testLoadBudgetClearsPreviousItems`** — Loading for a new earmark replaces old items

### 5.2 Budget Line Item Merge Logic Tests

Test the pure merge function:

1. **`testMergeCombinesBudgetAndActuals`** — Categories in both lists get merged values
2. **`testMergeIncludesBudgetOnlyCategories`** — Budget but no spending → zero actual
3. **`testMergeIncludesActualOnlyCategories`** — Spending but no budget → zero budget
4. **`testMergeCalculatesRemainingCorrectly`** — remaining = budget + actual
5. **`testMergeSortsByCategoryName`** — Output sorted alphabetically
6. **`testUnallocatedBudgetCalculation`** — When savingsGoal exists, unallocated = goal - totalBudget

---

## 6. Step-by-Step Implementation Order

### Step 1: Add budget state and methods to EarmarkStore (TDD)

Write tests first. Then add to `EarmarkStore`:
- `private(set) var budgetItems: [EarmarkBudgetItem] = []`
- `private(set) var isBudgetLoading = false`
- `private(set) var budgetError: Error?`
- `func loadBudget(earmarkId: UUID) async`
- `func updateBudgetItem(earmarkId: UUID, categoryId: UUID, amount: MonetaryAmount) async`
- `func removeBudgetItem(earmarkId: UUID, categoryId: UUID) async`

Note: The API uses PUT with the full list, so all mutations send the complete `[EarmarkBudgetItem]` array.

### Step 2: Add merge utility function (TDD)

Create a static function:
```swift
static func buildLineItems(
  budgetItems: [EarmarkBudgetItem],
  categoryBalances: [UUID: Int],
  categories: Categories
) -> [BudgetLineItem]
```

### Step 3: Create EarmarkBudgetSectionView

- Takes `earmark: Earmark`, `categories: Categories`
- Accesses `@Environment(EarmarkStore.self)` for budget items
- Accesses `@Environment(BackendProvider.self)` for analysis repository
- On appear, loads budget items and category balances
- Merges them using the utility function
- Renders a `List` with budget rows

Column alignment: all monetary columns use `.frame(width: 90, alignment: .trailing)`.

### Step 4: Create EditBudgetAmountSheet

Small sheet/popover with currency prefix, TextField, Save/Cancel. Use `.popover` on macOS, `.sheet` on iOS.

### Step 5: Create AddBudgetLineItemSheet

Sheet with category Picker (excluding already-budgeted categories) and amount TextField.

### Step 6: Integrate into EarmarkDetailView

1. Add `@State private var selectedTab: DetailTab = .transactions`
2. Add segmented `Picker` below overview panel
3. Conditionally show `TransactionListView` or `EarmarkBudgetSectionView`
4. Add toolbar "+" button when on budget tab

### Step 7: Wire up inline editing

Make budget amount cells tappable. Use `@Environment(\.horizontalSizeClass)` to decide popover vs sheet.

---

## 7. Edge Cases

| Edge Case | Handling |
|---|---|
| Empty budget | `ContentUnavailableView` with prompt to add first item |
| Spending but no budget for category | Show with $0 budget, negative remaining in red |
| Budget but no spending | Show $0 actual, full budget as remaining (green) |
| Category deleted from system | Guard with "Unknown" name |
| Unallocated budget | Only show when `savingsGoal` set and `totalBudget < savingsGoal` |
| Budget exceeds savings goal | Show unallocated as negative (over-allocated), red |
| Concurrent edits | Optimistic update with rollback on failure |
| Zero-amount budget items | Allow (user may want to track without a limit) |
| Loading state | Show `ProgressView` while loading |
| Network error | Show error state with retry button |
| Duplicate category | Prevent via "Add" sheet excluding existing category IDs |

---

## 8. Accessibility

- All monetary values use `MonetaryAmountView` (already has `.accessibilityValue()`)
- Budget rows: `.accessibilityElement(children: .combine)` with combined label like "Flights: spent $500, budget $800, remaining $300"
- "Add Line Item" button: `.accessibilityLabel("Add budget line item")`
- Edit popover/sheet: proper focus management
- Table headers: `.accessibilityAddTraits(.isHeader)`

---

## 9. Future Enhancements (Out of Scope)

- Hierarchical category display with indentation and subtotals
- Pie chart visualization
- Drag-to-reorder budget items
- Swipe-to-delete budget items (iOS)
- Budget vs. actual progress bars per category

---

**Estimate:** 6-8 hours
