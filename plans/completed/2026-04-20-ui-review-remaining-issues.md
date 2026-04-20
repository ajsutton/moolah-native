# UI Review — Remaining Issues

Issues identified by a full-codebase UI review that have not yet been addressed.

Status legend:
- **[FIXED]** — resolved in this branch or earlier
- **[VALID]** — still present, fix needed
- **[N/A]** — no longer applicable on re-inspection
- **[WONTFIX]** — intentional design decision; do not "fix"

## Problems

### 20. CategoryDetailView missing replacement picker — [FIXED]
**File:** `Features/Categories/Views/CategoryDetailView.swift`
Replaced the `confirmationDialog` with a dedicated `DeleteCategorySheet` that contains a real `Picker` for the replacement category (or "None (unassign)"). Tapping "Delete Category" now always routes through the sheet; the selected replacement ID is passed to `onDelete`.

## Suggestions

### S2. TransactionRowView metadata font — [WONTFIX]
**File:** `Features/Transactions/Views/TransactionRowView.swift`
Metadata row uses `.caption` deliberately — the smaller font is the intended look. Do not change to `.subheadline`.

### S3. ExpenseBreakdownCard breadcrumb color — [FIXED]
**File:** `Features/Analysis/Views/ExpenseBreakdownCard.swift`
Breadcrumb now uses `.foregroundStyle(.tint)` instead of hardcoded `.blue`.

### S4. NetWorthGraphCard Y-axis units — [FIXED]
**File:** `Features/Analysis/Views/NetWorthGraphCard.swift`
Added the instrument code (e.g. "AUD") next to the "Net Worth" title as a `.subheadline` `.secondary` label, with an accessibility label "Values in AUD". The Y-axis itself keeps the compact unsymbolled format so labels stay narrow.

### S8. TransactionListView punctuation inconsistency — [FIXED]
**File:** `Features/Transactions/Views/TransactionListView.swift`
Verified the current empty states in TransactionListView end with a period, matching the dominant convention across `ContentUnavailableView` callers.

### S11. EarmarksView duplicate row layout — [N/A]
**File:** `Features/Earmarks/Views/EarmarksView.swift`
`EarmarkRowView` wraps `SidebarRowView` and renders only name + balance (for sidebar use). The inline row in `EarmarksView.listView` is richer — it additionally shows saved and spent labels with up/down icons. Intentionally different layouts, not duplicated code.

### S12. TransactionDetailView missing preview state — [FIXED]
**File:** `Features/Transactions/Views/TransactionDetailView.swift`
Added a `#Preview("Scheduled (Recurring)")` that sets `showRecurrence: true` and includes a monthly recurring transaction so the recurrence UI branches render in Xcode Previews.

### S13. RecordTradeView non-interactive instrument picker — [WONTFIX]
**File:** `Features/Investments/Views/RecordTradeView.swift`
Functionality is being removed by another agent; no fix required here.

### S14. TokenSwapView non-interactive instrument field — [N/A]
**File:** `Features/Transactions/TokenSwapView.swift`
`TokenSwapView` has no call sites in the codebase — it is orphaned stub code. Fixing the placeholder picker has no user-visible impact. Delete or revive alongside the Phase 4/5 crypto work; not treated as a standalone UI bug.

### S15. WelcomeView button style on macOS — [FIXED]
**File:** `Features/Auth/WelcomeView.swift`
"Sign in with Google" now uses `.bordered` on macOS and `.borderedProminent` on iOS via `#if os(macOS)`.

### S16. EarmarkBudgetSectionView fixed column widths — [FIXED]
**File:** `Features/Earmarks/Views/EarmarkBudgetSectionView.swift`
Replaced the hardcoded `minWidth: 70, idealWidth: 90` on header/data/total/unallocated rows with `@ScaledMetric`-driven widths so columns grow with Dynamic Type.

### S17. ProfileSetupView animation accessibility — [FIXED]
**File:** `Features/Profiles/Views/ProfileSetupView.swift`
Added `@Environment(\.accessibilityReduceMotion)` and wrapped both `withAnimation { ... }` calls so they become `withAnimation(reduceMotion ? nil : .default)`. When Reduce Motion is enabled, the state transitions happen instantly.
