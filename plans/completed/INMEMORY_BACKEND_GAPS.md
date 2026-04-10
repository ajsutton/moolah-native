# InMemory Backend Gap Analysis

> Generated 2026-04-10. moolah-server is the source of truth.
> **Status: All actionable gaps fixed. All contract tests passing.**

The InMemory backend serves two roles: (1) test double for store/feature tests, and (2) preview backend. Some differences from the server are intentional simplifications that make testing easier. Others create gaps where tests pass but real behavior would differ.

## Intentional Simplifications (Keep)

These differences make test setup simpler without masking real bugs, because tests set up both sides of the equation consistently.

### A. Stored Balances on Accounts and Earmarks

**Server/CloudKit**: Balance, saved, spent are always computed from transactions.

**InMemory**: Balance is stored directly on the Account/Earmark object and not recomputed.

**Why this is fine**: Store tests (e.g. `AccountStoreTests`) seed accounts with exact balances and then test that store logic (deltas, totals, available funds) works correctly. They don't go through the "create account + create opening balance transaction" flow — they test the store layer in isolation. If a test creates `Account(balance: 100000)` and then calls `store.applyTransactionDelta`, the test is verifying the store's delta logic, not the repository's balance computation. The analysis repository tests use `InMemoryBackend()` which creates transactions through the repository and computes balances from them — those tests exercise the real computation path.

**Risk**: A bug where `AccountStore.load()` shows a stale balance that doesn't match transactions would not be caught by store tests. But this is a display concern, not a data integrity concern — the server always recomputes.

### B. No Opening Balance Transaction on Account Creation

**Server/CloudKit**: Creating an account with a non-zero balance also creates an `openingBalance` transaction.

**InMemory**: Stores the balance directly on the account. No transaction is created.

**Why this is fine**: This is a consequence of (A). Tests that need transactions (analysis tests, transaction store tests) create them explicitly. Tests that only need an account with a known balance (account store tests) seed the balance directly. Requiring InMemory to create opening balance transactions would force every account-only test to also set up a transaction repository, adding complexity for no testing benefit.

### C. No Foreign Key Validation on Transactions

**Server**: Validates that `accountId`, `toAccountId`, and `earmark` reference existing entities. Rejects `toAccountId` when type is not transfer. Rejects `recurEvery` without `recurPeriod`.

**InMemory**: Only validates transfer-specific rules (requires `toAccountId`, rejects same-account).

**Why this is fine**: The app UI prevents creating transactions with invalid references — account/earmark pickers only show existing entities. These validations are server-side safety nets, not business logic the client relies on. Adding them to InMemory would force every transaction test to also create matching accounts/earmarks, significantly increasing test boilerplate without testing anything meaningful about the app's behavior.

**Risk**: If a code path ever constructs a transaction with an invalid accountId and sends it to the server, InMemory tests would not catch the error. But this would be caught by the Remote backend's integration with the server.

### D. `scheduled` Filter Default Behavior

**Server**: When no `scheduled` parameter is provided, defaults to `false` (only non-scheduled transactions).

**InMemory**: When `filter.scheduled` is nil, returns all transactions (both scheduled and non-scheduled).

**Why this is fine**: The app always passes an explicit `scheduled` value. The "fetch everything" behavior is useful for analysis code. Documented rather than changed.

## Fixed Gaps

### 1. Category Delete — Child Reparenting (was HIGH)

**Fix applied**: `InMemoryCategoryRepository.delete` now always sets child `parentId = nil`, matching the server.

### 2. Category Delete — Budget Cascade (was MEDIUM)

**Fix applied**: `InMemoryCategoryRepository.delete` now cascades to budget items via `earmarkRepository.replaceCategoryInBudgets()`.

### 3. Expense Breakdown — Uncategorized Transactions (was MEDIUM)

**Decision**: Keep including uncategorized expenses in the breakdown. Including all earmarked transactions provides a more accurate status. Both InMemory and CloudKit now include nil-category expenses. Contract test added: `expenseBreakdownIncludesUncategorized`.

### 4. Account Sort Order (was LOW)

**Fix applied**: `InMemoryAccountRepository.fetchAll` now sorts with investment accounts last, then by position, then by name — matching the server. However, this is not a practical gap since the UI always applies its own sort order.

### 5. Daily Balances — investmentValue & bestFit (was LOW)

**Fix applied**: `InMemoryAnalysisRepository.fetchDailyBalances` now computes `investmentValue` from `InMemoryInvestmentRepository` and `bestFit` via linear regression. Contract tests added.

## Contract Test Coverage

All previously missing contract tests have been filled:

- **`fetchPayeeSuggestions`**: 4 tests (prefix matching, case insensitivity, empty prefix, frequency sorting)
- **Transaction `scheduled` filter**: Covered
- **Transaction `earmarkId` filter**: Covered
- **Transaction `accountId` filter**: Covered (including transfers)
- **`fetchCategoryBalances`**: 6+ tests (flat mapping, excludes scheduled, filters by type, date range, accountId, empty result)
- **Category delete budget cascade**: Covered
- **Daily balances investmentValue**: Covered
- **Daily balances bestFit**: Covered (linear data + single point edge case)
- **Expense breakdown uncategorized**: Covered
