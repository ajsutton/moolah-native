# Investment View Overhaul

## Context

The native app's investment account view only shows a valuation list + single-line chart. The web app shows: summary panels (Current Value, Invested Amount, ROI), a multi-series chart (value, invested amount, profit/loss), a time period selector, AND the transaction list. The native app also discards the invested amount — `AccountDTO.toDomain()` merges `value` and `balance` into one field, losing the distinction.

## Plan

### Step 1: Preserve invested amount in Account model

The server already returns both `balance` (invested amount from transactions) and `value` (market valuation) for investment accounts. The DTO at `Backends/Remote/DTOs/AccountDTO.swift:14` currently discards one. Fix:

- **`Domain/Models/Account.swift`**: Add `investmentValue: MonetaryAmount?` property (nil for non-investment accounts). Keep `balance` as the transaction-based invested amount for all account types.
- **`Backends/Remote/DTOs/AccountDTO.swift`**: Map `value` → `investmentValue`, keep `balance` → `balance`.
- **`Backends/InMemory/InMemoryAccountRepository.swift`**: Support `investmentValue` in test data.
- **`Features/Accounts/AccountStore.swift`**: Update `investmentTotal` to use `investmentValue ?? balance` for investment accounts. Update `AccountRowView` to display `investmentValue` when available.
- **Update `Accounts.adjustingBalance()`** if needed.
- **Update tests** for AccountDTO mapping.

### Step 2: Add per-account daily balances

The server has `GET /api/accounts/{id}/balances?after=DATE` returning `[{date, balance}]`. This gives cumulative invested amount over time (needed for the chart's "Invested Amount" line and ROI calculation).

- **`Domain/Models/AccountDailyBalance.swift`** (new): Simple `struct AccountDailyBalance: Codable, Sendable, Identifiable { date: Date, balance: MonetaryAmount }` — distinct from the analysis `DailyBalance` which has many more fields.
- **`Domain/Repositories/InvestmentRepository.swift`**: Add `fetchDailyBalances(accountId: UUID) async throws -> [AccountDailyBalance]`.
- **`Backends/Remote/Repositories/RemoteInvestmentRepository.swift`**: Implement via `GET accounts/{accountId}/balances/`.
- **`Backends/InMemory/InMemoryInvestmentRepository.swift`**: Compute from stored transactions or seed test data.
- **Contract tests + remote fixture tests.**

### Step 3: Expand InvestmentStore

- **`Features/Investments/InvestmentStore.swift`**: Add:
  - `dailyBalances: [AccountDailyBalance]` — loaded alongside values
  - `selectedPeriod: TimePeriod` — enum with cases: `.months(1)`, `.months(3)`, `.months(6)`, `.months(9)`, `.years(1)`, `.years(2)`, `.years(3)`, `.years(4)`, `.years(5)`, `.all`
  - `loadDailyBalances(accountId:)` method
  - Computed: `filteredValues`, `filteredBalances` (filtered by selectedPeriod)
  - Computed: `chartDataPoints` — merged value + balance + profit/loss series for the chart
- **Tests for new store logic.**

### Step 4: Investment summary panels

- **`Features/Investments/Views/InvestmentSummaryView.swift`** (new): Three-panel HStack:
  - **Current Value** — from `account.investmentValue` with profit/loss % indicator
  - **Invested Amount** — from `account.balance`
  - **ROI** — profit/loss amount with annualized return % (port the binary search algorithm from `InvestmentValue.vue:168-235`)
- Reuse `LegendItem` pattern from `NetWorthGraphCard.swift:157`.

### Step 5: Multi-series investment chart with time period picker

- **`Features/Investments/Views/InvestmentChartView.swift`** (new): Swift Charts with 3 series:
  - Investment Value (blue line) — from investment values
  - Invested Amount (gray line) — from daily balances
  - Profit/Loss (orange area) — value minus balance
  - Step interpolation for balance, catmullRom for value
  - Legend below chart
  - Time period Picker in toolbar or above chart (matching web's dropdown)
  - `chartXSelection` for date inspection (follow NetWorthGraphCard pattern)
- Data merging logic: merge values and balances by date, forward-fill gaps (same algorithm as `InvestmentValueGraph.vue:61-141`).

### Step 6: Restructure investment account view

- **`App/ContentView.swift:36-39`**: Change investment account case to show a combined view instead of bare `InvestmentValuesView`.
- **`Features/Investments/Views/InvestmentAccountView.swift`** (new): Composes everything in a `ScrollView` or `VStack`:
  1. `InvestmentSummaryView` (panels)
  2. Time period picker
  3. `InvestmentChartView` (multi-series chart)
  4. `Divider`
  5. Embedded `TransactionListView` with account filter (same as non-investment accounts)
  6. Valuation management section (compact list/inline add for recording values — simplified from current `InvestmentValuesView`)
- Load investment values, daily balances, and transactions together on appear.

### Step 7: Clean up

- Remove or refactor `InvestmentValuesView` into the valuation management sub-section.
- Ensure the "Add Value" toolbar button is still accessible.
- Verify sidebar totals use `investmentValue` correctly.

## Files Modified (estimated)

| File | Change |
|------|--------|
| `Domain/Models/Account.swift` | Add `investmentValue` property |
| `Backends/Remote/DTOs/AccountDTO.swift` | Map `value` → `investmentValue` |
| `Backends/InMemory/InMemoryAccountRepository.swift` | Support `investmentValue` |
| `Features/Accounts/AccountStore.swift` | Use `investmentValue` for totals |
| `Features/Accounts/Views/AccountRowView.swift` | Display value for investments |
| `Domain/Models/AccountDailyBalance.swift` | **New** — simple date+balance model |
| `Domain/Repositories/InvestmentRepository.swift` | Add `fetchDailyBalances` |
| `Backends/Remote/Repositories/RemoteInvestmentRepository.swift` | Implement daily balances fetch |
| `Backends/InMemory/InMemoryInvestmentRepository.swift` | Implement daily balances |
| `Features/Investments/InvestmentStore.swift` | Daily balances, time period, computed chart data |
| `Features/Investments/Views/InvestmentSummaryView.swift` | **New** — summary panels |
| `Features/Investments/Views/InvestmentChartView.swift` | **New** — multi-series chart |
| `Features/Investments/Views/InvestmentAccountView.swift` | **New** — composed investment view |
| `App/ContentView.swift` | Route to `InvestmentAccountView` |
| `Features/Investments/Views/InvestmentValuesView.swift` | Refactor into sub-component |
| Various test files | New + updated tests |

## Verification

1. `just build-mac` — compiles without warnings
2. `just test` — all existing tests pass + new tests pass
3. Manual: select investment account → see summary panels, multi-series chart, time picker, transaction list, and valuation management
4. Manual: change time period → chart and data update correctly
5. Manual: add/remove valuations → summary panels update
6. `mcp__xcode__XcodeListNavigatorIssues` with severity "warning" — no new warnings
