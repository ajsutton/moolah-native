# CloudKit Backend Gap Analysis

> Generated 2026-04-10. moolah-server is the source of truth.
> **Status: All gaps resolved. All tests passing.**

## Fixed

### 1. Category Delete — Child Reparenting (was HIGH)

**Server**: Always sets child categories' `parent_id = NULL` on delete.

**Fix applied**: `CloudKitCategoryRepository.delete` now sets child `parentId = nil` regardless of replacement.

### 2. Category Delete — Budget Cascade (was MEDIUM)

**Server**: Updates budget items to point to replacement category (or deletes them).

**Fix applied**: `CloudKitCategoryRepository.delete` now cascades to `EarmarkBudgetItemRecord`, matching server `UPDATE IGNORE` + `DELETE` semantics.

### 3. Expense Breakdown — Uncategorized Transactions (was MEDIUM)

**Server**: `AND category_id IS NOT NULL` excludes uncategorized expenses from the breakdown.

**Decision**: Keep including uncategorized expenses in both CloudKit and InMemory backends. Including all earmarked transactions provides a more accurate status. The UI already handles nil categoryId display.

### 4. Account Sort Order (was LOW)

**Server**: `ORDER BY type = "investment", position, name` — investments last.

**Decision**: Not a real gap. The UI always applies its own sort order (e.g., `TransactionDetailView.sortedAccounts` groups current before investment, `SidebarView` separates into sections). Repository sort order is not relied upon for display.

### 5. Daily Balances — investmentValue & bestFit (was LOW)

**Server**: Computes `investmentValue` (from investment_value table) and `bestFit` (linear regression on availableFunds).

**Fix applied**: Both CloudKit and InMemory analysis repositories now:
- Compute `investmentValue` by fetching investment values from `InvestmentValueRecord` (CloudKit) or `InMemoryInvestmentRepository` and tracking the most recent value per account for each date.
- Compute `bestFit` using linear regression (least squares) on `(dayOffset, availableFunds)` data points.
- Update `netWorth` to use `investmentValue` when available instead of contributed `investments` amount.

Contract tests added: `dailyBalancesInvestmentValue`, `dailyBalancesBestFit`, `dailyBalancesBestFitSinglePoint`.
