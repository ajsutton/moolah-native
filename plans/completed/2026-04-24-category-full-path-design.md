# Category full-path display — design

## Goal

Every category label rendered outside the category-management screens displays the full colon-separated path from `Categories.path(for:)` (e.g. `Income:Salary:Adrian`) instead of only the leaf `category.name` (e.g. `Adrian`). A leaf name in isolation is ambiguous — the same leaf (`Adrian`) can appear under several parents — so transaction rows, reports, filters, and pickers need the full path for users to identify categories at a glance.

## Non-goals

- **No data-model change.** `Category.name` keeps its current semantics (leaf only). `Categories.path(for:)` already exists and is the single source of truth for the displayed path.
- **No change to search or match semantics.** `matchesCategorySearch(_:query:)` already matches against full paths.
- **No change inside the category-management surfaces.** `CategoriesView`, `CategoryTreeView`, and the "Parent" field in `CategoryDetailView` continue to show leaf names because those screens convey hierarchy structurally (indentation, grouping) and a repeated full path would add noise.

## Separator convention

Colon (`:`) — already used by `Categories.path(for:)` and by existing test fixtures (`Income:Salary:Janet`, `Groceries:Food`). No alternative separators appear in the codebase.

## Change list

### Already correct — no change

- `TransactionDetailView` (draft uses `categories.path(for:)`, search matches full path).
- `CategoryAutocompleteField` (suggestion row renders `suggestion.path`).
- `AddBudgetLineItemSheet` (picker text uses `categories.path(for:)`).

### View-only swap: `category.name` → `categories.path(for: category)`

- `Features/Transactions/TransactionRowView.swift` — metadata row.
- `Features/Transactions/UpcomingTransactionRow.swift` — scheduled transaction row (two sites).
- `Features/Reports/ReportsView.swift` — drill-down title.
- `Features/Reports/CategoryBalanceTable.swift` — report table rows.
- `Features/ImportRules/RuleEditorActionRow.swift` — category picker.
- `Features/Transactions/TransactionFilterView.swift` — filter toggle labels.

### Chart helper rename

`CategoriesOverTimeCard.categoryName(for:)` and `ExpenseBreakdownCard.categoryName(for:)` currently do a `.name` lookup. Replace with `categories.path(for:)` and rename the helpers to `categoryLabel(for:)` so the changed meaning is visible at call sites. These remain view-local one-liners — they are lookup helpers, not business logic, so extraction isn't warranted.

### Structural change: `BudgetLineItem.categoryName` → `categoryPath`

`BudgetLineItem` currently stores the leaf `categoryName: String`, populated at build time. Four consumers read it (`EarmarkBudgetSectionView` in four places, `EditBudgetAmountSheet:28`). The field is written once and read from multiple views, so computing the path once at build time is cheaper than on every row render.

- Rename the field to `categoryPath` across `BudgetLineItem.swift` and its consumers.
- Populate it with `categories.path(for:)` in both construction sites inside `BudgetLineItem.swift`.

## Testing

- **Unit test** — `BudgetLineItemTests` (new or extended): assert that for a nested category `Income/Salary/Adrian`, the generated line item has `categoryPath == "Income:Salary:Adrian"`, and for a root category the path equals the leaf name. This is the only piece of new logic outside view code.
- **Compile check + manual spot-check** — every other change is a one-line substitution inside a thin view. `just build-mac` catches typos; manual verification of transaction list, reports drill-down, transaction filter, and the import-rule picker confirms the change is visible.
- **Existing test impact** — `CategoryMatchingTests` already uses full-path strings; UI tests that assert on leaf-only labels (if any) will be updated only if they break.

## Risks and edge cases

- **Root category**: `Categories.path(for:)` returns the leaf name when there's no parent. Behaviour unchanged for flat categories.
- **Orphaned `categoryId`** (category deleted but still referenced): `categories.by(id:)` returns nil. Existing optional-chaining at all call sites handles this — unchanged.
- **Narrow columns / chart legends**: long paths may truncate via existing `.lineLimit` modifiers. Acceptable — partial truncation still conveys more context than the leaf alone.
- **Performance**: `categories.path(for:)` walks the parent chain per call. Category depth is small in practice; no memoisation needed. For `BudgetLineItem` (built once, read many times) the path is computed at build time, not per row.

## Rollout

Single PR. No migration, no feature flag — this is a display-layer change with no persisted state.
