# InMemory Backend Gap Analysis

> Generated 2026-04-10. moolah-server is the source of truth.
> **Status: All InMemory fixes applied and tests passing.** CloudKit gaps remain (see CLOUDKIT_BACKEND_GAPS.md).

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

## Gaps That Mask Real Bugs (Fix)

These differences mean tests can pass while the real behavior would be incorrect.

### 1. Category Delete — Child Reparenting (HIGH)

**Server**: Always sets child categories' `parent_id = NULL`. The `replacementId` parameter only applies to transactions and budget items.

**InMemory**: Sets child categories' `parentId` to `replacementId`.

**Impact**: A test that deletes a parent category with a replacement and then checks children will see them reparented under the replacement — but the server would orphan them. Any UI code that assumes children follow the replacement would break in production. The contract test `testDeletesCategoryAndUpdatesChildren` verifies the wrong behavior.

**Fix**: Change `InMemoryCategoryRepository.delete` to always set child `parentId = nil`, matching the server.

### 2. Category Delete — Budget Cascade Missing (MEDIUM)

**Server**: On category delete, updates budget items to point to the replacement category (or deletes them via `UPDATE IGNORE` + `DELETE`).

**InMemory**: Does not touch budget items at all.

**Impact**: After deleting a category, `fetchBudget` in InMemory still returns items referencing the deleted category. The server would have updated or removed them. Any store code that relies on budget cleanup happening at the repository level would behave differently in production.

**Fix**: Add budget cascade to `InMemoryCategoryRepository.delete`. Requires access to the earmark repository's budget storage (similar to how it already has access to the transaction repository).

### 3. Expense Breakdown — Uncategorized Transactions (MEDIUM)

**Server SQL**: `AND category_id IS NOT NULL` — excludes uncategorized expenses from the breakdown.

**InMemory**: Includes expenses with `categoryId == nil`. They appear as entries with a nil category key in the results.

**Impact**: Expense breakdown UI or store logic tested against InMemory would see uncategorized expenses, but they would be absent in production. Could mask bugs where uncategorized expenses are incorrectly displayed or aggregated.

**Fix**: Add `guard txn.categoryId != nil else { continue }` in `InMemoryAnalysisRepository.fetchExpenseBreakdown`, before the amount check.

### 4. Account Sort Order (LOW)

**Server**: `ORDER BY type = "investment", position, name` — investment accounts always sort after current accounts.

**InMemory**: Sorts by `position` only.

**Impact**: If an investment account has position 0 and a bank account has position 1, InMemory shows the investment first while the server would show the bank first. Could mask UI ordering bugs in account lists.

**Fix**: Update `InMemoryAccountRepository.fetchAll` sort to: `sorted { a, b in if a.type.isCurrent != b.type.isCurrent { return a.type.isCurrent }; return a.position < b.position }` (or similar logic placing investments last).

### 5. `scheduled` Filter Default Behavior (LOW)

**Server**: When no `scheduled` parameter is provided, defaults to `false` (only non-scheduled transactions).

**InMemory**: When `filter.scheduled` is nil, returns all transactions (both scheduled and non-scheduled).

**Impact**: Calling `fetch(filter: TransactionFilter(), ...)` returns different results. However, the app always passes an explicit `scheduled` value, so this is unlikely to cause issues in practice.

**Fix**: Could change InMemory to default nil to false to match server, but this would break the useful behavior of "fetch everything" which analysis code relies on. Better to leave as-is and document.

## Missing Contract Tests

These gaps exist regardless of InMemory vs server differences — they're tests that should exist but don't.

1. **`fetchPayeeSuggestions`** — No tests. Should verify: prefix matching, frequency-based sorting, empty prefix returns empty, case insensitivity.

2. **Transaction `scheduled` filter** — No tests for `scheduled: true` or `scheduled: false`.

3. **Transaction `earmarkId` filter** — No tests.

4. **Transaction `accountId` filter** — No tests. Should verify it matches both `accountId` and `toAccountId`.

5. **`fetchCategoryBalances`** — No analysis contract tests for this method at all.

6. **Category delete budget cascade** — No tests verify budget items are updated.

## Priority Summary

| # | Issue | Type | Priority |
|---|-------|------|----------|
| 1 | Category delete child reparenting | Bug | High |
| 2 | Category delete budget cascade | Missing | Medium |
| 3 | Expense breakdown nil categories | Bug | Medium |
| 4 | Account sort order | Bug | Low |
| 5 | Missing contract tests | Coverage | Medium |
