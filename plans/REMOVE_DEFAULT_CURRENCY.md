# Plan: Remove defaultCurrency from production code

## Context
Currency is now a per-profile property (`Profile.currency`), but the codebase still uses `Currency.defaultCurrency` (hardcoded AUD) throughout backends, DTOs, and views. The profile currency setting is effectively ignored at runtime. We need to thread the profile's currency through the backend layer, and have views derive currency from loaded domain objects — not a global constant.

**Key design principle (from user):** The backend is the authority on currency. Profile currency flows into the backend; the backend stamps it on all `MonetaryAmount` values it returns. Nothing outside the backend needs the profile currency directly — views read currency from the domain objects the backend provides. This designs for future per-account/per-transaction currencies.

## Step 1: Thread currency through Remote Backend

**`Backends/Remote/RemoteBackend.swift`** — Add `currency: Currency` init param. Pass to each repository.

**Each Remote Repository** — Accept `currency: Currency` in init, use when constructing MonetaryAmounts:
- `RemoteAccountRepository.swift` — pass to `AccountDTO.toDomain(currency:)`
- `RemoteTransactionRepository.swift` — use for `priorBalance`, pass to `TransactionDTO.toDomain(currency:)`
- `RemoteEarmarkRepository.swift` — use for budget items, pass to `EarmarkDTO.toDomain(currency:)`
- `RemoteAnalysisRepository.swift` — use for category balances, pass to DTOs
- `RemoteInvestmentRepository.swift` — pass to `InvestmentValueDTO.toDomain(currency:)` and `AccountDailyBalanceDTO.toDomain(currency:)`

**Each DTO** — Change `toDomain()` → `toDomain(currency: Currency)`:
- `AccountDTO`, `AccountDailyBalanceDTO`, `DailyBalanceDTO`, `EarmarkDTO`
- `TransactionDTO`, `InvestmentValueDTO`, `MonthlyIncomeExpenseDTO`, `ExpenseBreakdownDTO`

**`App/ProfileSession.swift`** — Pass `profile.currency` to `RemoteBackend`.

## Step 2: Thread currency through InMemory Backend

**`Backends/InMemory/InMemoryBackend.swift`** — Add `currency: Currency` init param (default `.AUD`). Pass to `InMemoryEarmarkRepository`.

**`Backends/InMemory/InMemoryEarmarkRepository.swift`** — Accept `currency: Currency`, use in `setBudget()`.

**`Backends/InMemory/InMemoryTransactionRepository.swift`** — Accept `currency: Currency`, use for `priorBalance` reduce seed.

## Step 3: Replace `MonetaryAmount.zero` with `zero(currency:)`

**`Domain/Models/MonetaryAmount.swift`** — Change `static let zero` to `static func zero(currency: Currency) -> MonetaryAmount`.

Update call sites:
- `Domain/Models/BudgetLineItem.swift:55` — `goal > .zero` → `goal.isPositive` (already a property); reduce seed uses `goal!.currency`
- `Features/Navigation/SidebarView.swift:214` — derive currency from the earmarks/accounts being reduced
- `Features/Analysis/Views/ExpenseBreakdownCard.swift:109,128` — derive from the items being reduced
- `Features/Analysis/Views/IncomeExpenseTableCard.swift:146` — derive from the data being reduced
- `Backends/InMemory/InMemoryTransactionRepository.swift:65` — use stored currency

## Step 4: Update views — derive currency from domain objects

Views that **display** loaded data already have MonetaryAmounts with currency — just replace `Currency.defaultCurrency` with the amount's `.currency`.

Views that **create** data (forms) derive currency from their context:

| View | Currency source |
|------|----------------|
| `CreateAccountView` | Add `currency: Currency` param; parent passes from loaded accounts |
| `TransactionFormView` | Look up selected account: `accounts[accountId]?.balance.currency` (account is always required) |
| `TransactionDetailView` | Use `transaction.amount.currency` |
| `EditBudgetAmountSheet` | Use `lineItem.budgeted.currency` |
| `AddBudgetLineItemSheet` | Use `earmark.balance.currency` |
| `SidebarView` (create earmark) | Use `accountStore.currentTotal.currency` |
| `EarmarksView` (create/edit earmark) | Use earmark/account currency from stores |
| `EarmarkDetailView` (edit) | Use `earmark.balance.currency` |
| `AddInvestmentValueView` | Use existing investment value's currency or account balance currency |
| `InvestmentValuesView` | Use value's `.currency` |
| `InvestmentChartView` | Use value's `.currency` from chart data |
| `CategoriesOverTimeCard` | Use entry's `.currency` |
| `NetWorthGraphCard` | Use data point's `.currency` |
| `AnalysisView` | Only preview — use `.AUD` |

**Preview-only usages**: Replace `Currency.defaultCurrency` with `.AUD` directly (no runtime impact).

Files with preview-only usage: `AccountRowView`, `TransactionFilterView`, `TransactionRowView`, `TransactionListView`, `UpcomingTransactionsCard`, `ExpenseBreakdownCard` previews, `IncomeExpenseTableCard` previews, `NetWorthGraphCard` previews, `EarmarkRowView`, `UpcomingView`, `AllTransactionsView`, `AnalysisView`.

## Step 5: Fix hardcoded currency strings

- `PayeeAutocompleteField.swift:160` — hardcoded "AUD" in preview → `.AUD.code`

## Step 6: Move defaultCurrency to test-only code

- **`Domain/Models/Currency.swift`** — Remove `public static let defaultCurrency`
- **New `MoolahTests/Support/TestCurrency.swift`** — `extension Currency { static let defaultTestCurrency: Currency = .AUD }`
- Update all test files: `Currency.defaultCurrency` → `Currency.defaultTestCurrency`

## Step 7: Update CLAUDE.md

Remove the `Constants.defaultCurrency` reference from the Currency bullet point. Update to explain currency flows from profile → backend → domain objects.

## Verification

1. `just build-mac` — no compile errors
2. `just test` — all tests pass
3. `mcp__xcode__XcodeListNavigatorIssues` — no warnings
4. `grep -r "defaultCurrency" --include="*.swift"` in non-test code → zero results
5. `grep -r '"AUD"\|"USD"' --include="*.swift"` in non-test/non-domain code → zero results
