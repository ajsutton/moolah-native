# UI Review — Remaining Issues

Issues identified by a full-codebase UI review that have not yet been addressed.

## Problems

### 20. CategoryDetailView missing replacement picker
**File:** `Features/Categories/Views/CategoryDetailView.swift:60-82`
"Delete and Reassign" button is offered but `selectedReplacementId` is never set by any UI element — the replacement category picker is missing. Tapping "Delete and Reassign" calls `onDelete(category.id, nil)`.

### 21. SidebarView iOS "+" buttons missing accessibility labels
**File:** `Features/Navigation/SidebarView.swift:54-64, 83-94`
The icon-only "+" buttons in the Current Accounts and Earmarks section headers on iOS have no `.accessibilityLabel`. VoiceOver can't describe what the buttons do.

### 22. ExpandableChart dismiss button placement
**File:** `Shared/ExpandableChart.swift:33`
The full-screen chart "Done" dismiss button uses `.confirmationAction` placement — should be `.cancellationAction` since it dismisses rather than confirms.

### 23. UserMenuView hardcoded platform colors
**File:** `Features/Auth/UserMenuView.swift:117-119`
Uses `Color(nsColor: .quaternaryLabelColor)` / `Color(uiColor: .quaternaryLabel)` — should use a cross-platform semantic equivalent.

## Suggestions

### S1. TransactionRowView alignment
**File:** `Features/Transactions/Views/TransactionRowView.swift:18`
`HStack` uses default `.center` alignment instead of `.firstTextBaseline` per style guide.

### S2. TransactionRowView metadata font
**File:** `Features/Transactions/Views/TransactionRowView.swift:28-47`
Metadata row uses `.caption` instead of `.subheadline` per style guide.

### S3. ExpenseBreakdownCard breadcrumb color
**File:** `Features/Analysis/Views/ExpenseBreakdownCard.swift:96`
"All Categories" breadcrumb uses hardcoded `.blue` instead of `.tint`.

### S4. NetWorthGraphCard Y-axis units
**File:** `Features/Analysis/Views/NetWorthGraphCard.swift`
Chart Y-axis labels have no currency unit indicator.

### S5. CategoryBalanceTable row accessibility
**File:** `Features/Reports/Views/CategoryBalanceTable.swift:96-103`
NavigationLink row has no combined accessibility label for category + amount.

### S6. EarmarkDetailView summary accessibility
**File:** `Features/Earmarks/Views/EarmarkDetailView.swift:129`
Summary items ("Balance", "Saved", "Spent") lack `.accessibilityElement(children: .combine)` — label and amount read as separate elements.

### S7. InvestmentAccountView time period picker accessibility
**File:** `Features/Investments/Views/InvestmentAccountView.swift:193-217`
Time period picker buttons lack `.accessibilityValue("Selected")`.

### S8. TransactionListView punctuation inconsistency
**File:** `Features/Transactions/Views/TransactionListView.swift:282`
Empty state description punctuation style differs from other views.

### S9. InvestmentChartView legend labels
**File:** `Features/Investments/Views/InvestmentChartView.swift:170`
Legend accessibility labels say "X series" — "series" is unnecessarily technical.

### S10. CryptoSettingsView provider badge accessibility
**File:** `Features/Settings/CryptoSettingsView.swift:103-116`
Provider badges ("CG", "CC", "BN") lack accessibility labels for full names (CoinGecko, CryptoCompare, Binance).

### S11. EarmarksView duplicate row layout
**File:** `Features/Earmarks/Views/EarmarksView.swift:108-133`
Inline earmark row duplicates layout instead of reusing `EarmarkRowView`.

### S12. TransactionDetailView missing preview state
**File:** `Features/Transactions/Views/TransactionDetailView.swift`
No `#Preview` for `showRecurrence: true` state.

### S13. RecordTradeView non-interactive instrument picker
**File:** `Features/Investments/Views/RecordTradeView.swift:133-146`
Instrument picker looks tappable but does nothing (known Phase 5 gap).

### S14. TokenSwapView non-interactive instrument field
**File:** `Features/Transactions/TokenSwapView.swift:131-144`
Same non-interactive instrument field issue as S13.

### S15. WelcomeView button style on macOS
**File:** `Features/Auth/WelcomeView.swift`
"Sign in with Google" uses `.borderedProminent` on macOS — should be `.bordered`.

### S16. EarmarkBudgetSectionView fixed column widths
**File:** `Features/Earmarks/Views/EarmarkBudgetSectionView.swift:139-152`
Fixed `idealWidth: 90` on column headers breaks Dynamic Type.

### S17. ProfileSetupView animation accessibility
**File:** `Features/Profiles/Views/ProfileSetupView.swift:37`
Animation doesn't check `accessibilityReduceMotion`.
