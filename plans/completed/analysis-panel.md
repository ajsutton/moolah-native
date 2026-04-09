# Analysis Panel — Gap Analysis & Implementation Plan

## Context

The web app (`../moolah/src/components/analysis/`) has 5 analysis components: `Analysis.vue` (container), `NetWorthGraph.vue`, `ExpenseBreakdown.vue`, `IncomeAndExpenseTable.vue`, `CategoriesOverTime.vue`. The server exposes 4 endpoints at `/api/analysis/` — `dailyBalances`, `incomeAndExpense`, `expenseBreakdown`, `categoryBalances`.

The native app already has extensive analysis infrastructure: `AnalysisStore`, `AnalysisRepository` protocol, both backend implementations, DTOs, contract tests, and 4 of the 5 web views (`NetWorthGraphCard`, `ExpenseBreakdownCard`, `IncomeExpenseTableCard`, `UpcomingTransactionsCard`).

### Three gaps remain

1. **Analysis is not in the sidebar** — `SidebarSelection` enum has no `.analysis` case, and `ContentView` has no routing for it. The page exists but is unreachable.

2. **NetWorthGraphCard is missing 3 series** — Web shows 8 series (Current Funds, Available Funds, Invested Amount, Investment Value, Net Worth, Best Fit, Scheduled, Scheduled Available Funds). Native only shows Available Funds + Net Worth + Best Fit + Forecast. The `DailyBalance` model already has `balance`, `investments`, and `investmentValue` fields — they just need to be rendered.

3. **Categories Over Time chart is completely missing** — The web app has a full stacked area chart (`CategoriesOverTime.vue`) showing expense categories over time with percentage/actual toggle. No equivalent exists in native. The data is already available from `fetchExpenseBreakdown` — it just needs a new view and store computed properties to transform `[ExpenseBreakdown]` into chart-ready data.

## Plan

### Step 1: Sidebar navigation

Add analysis to the app's navigation so users can actually reach the page.

- **`Features/Navigation/SidebarView.swift`**: Add `.analysis` case to `SidebarSelection` enum, add NavigationLink with `chart.bar.xaxis` system image.
- **`App/ContentView.swift`**: Add `case .analysis` to the detail view switch, rendering `AnalysisView`.

### Step 2: Net Worth chart — add missing series

The `DailyBalance` model already has `balance`, `investments`, and `investmentValue` fields that are unused in the chart.

- **`Features/Analysis/Views/NetWorthGraphCard.swift`**: Add 3 series:
  - Current Funds (from `balance`)
  - Invested Amount (from `investments`)
  - Investment Value (from `investmentValue`)
- Add a series visibility toggle (similar to web's legend checkboxes).
- Update the legend to show all series.

### Step 3: Categories Over Time chart (new)

Port `CategoriesOverTime.vue` — a stacked area chart showing expense categories over time with percentage/actual toggle.

- **`Features/Analysis/AnalysisStore.swift`**: Add:
  - `categoriesOverTime` computed property — transforms `[ExpenseBreakdown]` into chart-ready grouped data (category × month × amount).
  - `showActualValues: Bool` toggle (percentage vs actual amounts).
- **`Features/Analysis/Views/CategoriesOverTimeCard.swift`** (new): Stacked `AreaMark` chart using Swift Charts. Include:
  - Stacked area marks colored by category
  - Toggle between percentage and actual values
  - Legend with category colors
  - `chartXSelection` for date inspection
- **`Features/Analysis/Views/AnalysisView.swift`**: Add `CategoriesOverTimeCard` to the view.

### Step 4 (optional): Per-card history pickers

The web app lets each card independently choose its history period.

- **`Features/Analysis/AnalysisStore.swift`**: Add `expenseBreakdownMonths` and `categoriesOverTimeMonths` properties.
- **`Features/Analysis/Views/ExpenseBreakdownCard.swift`**: Add per-card history Picker.

### Step 5: Tests

- **`MoolahTests/Features/AnalysisStoreTests.swift`** (new): Test `categoriesOverTime` grouping, percentage computation, edge cases (empty data, single category, all-zero months).

### Step 6: Polish

- Accessibility labels on all chart elements and toggles.
- Keyboard navigation for macOS.
- Dark mode verification with semantic colors.

## Files Modified (estimated)

| File | Change |
|------|--------|
| `Features/Navigation/SidebarView.swift` | Add `.analysis` to `SidebarSelection`, add NavigationLink |
| `App/ContentView.swift` | Add `case .analysis` to detail switch |
| `Features/Analysis/Views/NetWorthGraphCard.swift` | Add 3 series, series visibility toggle, update legend |
| `Features/Analysis/AnalysisStore.swift` | Add `categoriesOverTime` computed, `showActualValues`, per-card filters |
| `Features/Analysis/Views/CategoriesOverTimeCard.swift` | **New** — stacked area chart |
| `Features/Analysis/Views/AnalysisView.swift` | Add CategoriesOverTimeCard |
| `Features/Analysis/Views/ExpenseBreakdownCard.swift` | Per-card history Picker (optional) |
| `MoolahTests/Features/AnalysisStoreTests.swift` | **New** — store tests |

## Verification

1. `just build-mac` — compiles without warnings
2. `just test` — all existing + new tests pass
3. Manual: sidebar shows Analysis link, clicking it opens the analysis page
4. Manual: Net Worth chart shows all series with toggle controls
5. Manual: Categories Over Time chart renders stacked areas, percentage/actual toggle works
6. `mcp__xcode__XcodeListNavigatorIssues` with severity "warning" — no new warnings
