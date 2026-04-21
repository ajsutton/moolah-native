# UI Review Findings — Comprehensive Audit

**Date:** 2026-04-09
**Status:** In Progress
**Scope:** All view files in Features/, Shared/, App/ against UI_GUIDE.md and Apple HIG

---

## Critical Issues (1)

### 1. Hardcoded Colors in Expense Breakdown Legend
- **File:** `Features/Analysis/Views/ExpenseBreakdownCard.swift` (color generation from UUID hash)
- **Issue:** Colors generated using `Color(red:, green:, blue:)` from UUID hash — violates semantic color system
- **STYLE_GUIDE violation:** Section 10: "Hardcoded colors"
- **Fix:** Use a fixed palette of system-compatible colors

---

## Important Issues (13)

### 2. Missing .monospacedDigit() on Dates
- **File:** `Features/Analysis/Views/UpcomingTransactionsCard.swift` — date text missing `.monospacedDigit()`
- **STYLE_GUIDE violation:** Section 3: "Always use `.monospacedDigit()` for amounts, balances, and dates"

### 3. Small Touch Target on Pay Buttons
- **File:** `Features/Transactions/Views/UpcomingView.swift` — Pay button uses `.controlSize(.small)`
- **File:** `Features/Analysis/Views/UpcomingTransactionsCard.swift` — same issue
- **STYLE_GUIDE violation:** Section 10: "Touch targets smaller than 44x44pt (iOS)"
- **Fix:** Use `.controlSize(.regular)` on iOS

### 4. Inconsistent Date Formatting
- `UpcomingView.swift`: `style: .date`
- `TransactionRowView.swift`: `format: .dateTime.day().month(.abbreviated).year()`
- `InvestmentValueRow.swift`: `format: .dateTime.day().month().year()`
- `UpcomingTransactionsCard.swift`: `format: .dateTime.month().day()`
- **Fix:** Standardize to `.dateTime.day().month(.abbreviated).year()` or `.dateTime.day().month(.abbreviated)` for compact

### 5. Hardcoded .white Foreground in UserMenuView
- **File:** `Features/Auth/UserMenuView.swift` — `.foregroundColor(.white)` on avatar icon
- **STYLE_GUIDE violation:** Section 4: "Use system colors exclusively"
- **Fix:** Use `.foregroundStyle(.white)` (acceptable on colored background) or make adaptive

### 6. Missing Accessibility Labels on Icons
- **File:** `Features/Earmarks/Views/EarmarksView.swift` — arrow.up/arrow.down icons lack accessibility labels
- **File:** `Features/Transactions/Views/TransactionRowView.swift` — icon-only labels
- **STYLE_GUIDE violation:** Section 8 & 10

### 7. Missing Accessibility on Analysis Card Amounts
- **File:** `Features/Analysis/Views/UpcomingTransactionsCard.swift` — amounts displayed via `formatNoSymbol` without accessibility value

### 8. Divider with Fixed Frame Height
- **File:** `Features/Earmarks/Views/EarmarkDetailView.swift` — `Divider().frame(height: 32)` 
- **Fix:** Use padding-based spacing

### 9. Chart Color Not Following Semantic Rules  
- **File:** `Features/Analysis/Views/IncomeExpenseTableCard.swift` — uses `.blue` for savings column
- **Fix:** Use `.secondary` or `.primary` for neutral data

### 10. Fixed Circle Dimensions in Legend
- **File:** `Features/Analysis/Views/ExpenseBreakdownCard.swift` — `Circle().frame(width: 10, height: 10)` doesn't scale
- **Fix:** Use `@ScaledMetric` or slightly larger fixed size

### 11. Fixed TextEditor Height
- **File:** `Features/Transactions/Views/TransactionDetailView.swift` — `.frame(height: 60)` fixed
- **Fix:** Use `.frame(minHeight: 60, maxHeight: 120)`

### 12. UpcomingTransactionsCard Empty State Uses Plain Text
- **File:** `Features/Analysis/Views/UpcomingTransactionsCard.swift` — uses plain Text instead of ContentUnavailableView
- **Fix:** Replace with styled empty state

### 13. Duplicate Recurrence Description Logic
- **Files:** `UpcomingView.swift` and `UpcomingTransactionsCard.swift` both have recurrence description logic
- **Fix:** Extract to shared utility

### 14. Missing Loading State Accessibility on InvestmentValuesView
- **File:** `Features/Investments/Views/InvestmentValuesView.swift` — ProgressView not labeled
- **Fix:** Add `.accessibilityLabel("Loading more values")`

---

## Minor Issues (6)

### 15. Detail Panel Width Not Centralized
- Multiple files hardcode `.frame(width: 350)` — could use shared constant

### 16. Inconsistent Button Label Patterns
- Some buttons use `Label` with icons, others use `Text` only

### 17. Missing Keyboard Shortcut on Filter Clear
- `TransactionFilterView.swift` — "Clear All" lacks keyboard shortcut

### 18. Inconsistent List Styles Across Cards
- Analysis cards use `.plain` vs `.inset` inconsistently

### 19. Padding Not Tested at Accessibility Sizes
- `TransactionRowView.swift` adjusts for platform but not accessibility size

### 20. Missing Refresh Loading Indicator in Categories
- `CategoriesView.swift` has `.refreshable` but no explicit loading state indicator

---

## Resolution Status

| # | Severity | Status | Fix |
|---|----------|--------|-----|
| 1 | Critical | Fixed | Replaced RGB hash colors with fixed system color palette |
| 2 | Important | Fixed | Already had .monospacedDigit() - verified |
| 3 | Important | Fixed | Pay button uses .controlSize(.regular) on iOS |
| 4 | Important | Fixed | Standardized to .dateTime.day().month(.abbreviated).year() |
| 5 | Important | Fixed | Updated .foregroundColor(.white) to .foregroundStyle(.white) |
| 6 | Important | N/A | Earmark rows use .accessibilityElement(children: .combine) with full label |
| 7 | Important | Fixed | Amount now uses currency format instead of formatNoSymbol |
| 8 | Important | Fixed | Changed .frame(height: 32) to .frame(maxHeight: 32) |
| 9 | Important | Fixed | Changed .blue to .secondary for neutral savings column |
| 10 | Important | Fixed | Increased legend circle from 10pt to 12pt |
| 11 | Important | Fixed | Changed .frame(height: 60) to .frame(minHeight: 60, maxHeight: 120) |
| 12 | Important | Fixed | Replaced plain Text with ContentUnavailableView |
| 13 | Important | Fixed | Extracted RecurPeriod.recurrenceDescription(every:) shared utility |
| 14 | Important | Fixed | Added .accessibilityLabel("Loading more values") to ProgressView |
| 15 | Minor | Fixed | Added UIConstants.detailPanelWidth, replaced all hardcoded 350pt |
| 16 | Minor | N/A | Button pattern is correct: toolbar = Label+icon, form submit = Text only (Apple HIG) |
| 17 | Minor | Fixed | Added Cmd+Delete shortcut to Clear All filter button (macOS) |
| 18 | Minor | Fixed | UpcomingTransactionsCard uses .inset on macOS, .plain on iOS |
| 19 | Minor | Fixed | TransactionRowView padding uses @ScaledMetric for Dynamic Type |
| 20 | Minor | Fixed | Added toolbar ProgressView during category refresh |
