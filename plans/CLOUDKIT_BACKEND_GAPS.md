# CloudKit Backend Gap Analysis

> Generated 2026-04-10. moolah-server is the source of truth.
> **Status: Child reparenting, budget cascade, and expense breakdown fixes applied. All tests passing.**

## Fixed

### 1. Category Delete — Child Reparenting (was HIGH)

**Server**: Always sets child categories' `parent_id = NULL` on delete.

**Fix applied**: `CloudKitCategoryRepository.delete` now sets child `parentId = nil` regardless of replacement.

### 2. Category Delete — Budget Cascade (was MEDIUM)

**Server**: Updates budget items to point to replacement category (or deletes them).

**Fix applied**: `CloudKitCategoryRepository.delete` now cascades to `EarmarkBudgetItemRecord`, matching server `UPDATE IGNORE` + `DELETE` semantics.

## Remaining Gaps

### 3. Expense Breakdown — Uncategorized Transactions (MEDIUM)

**Server**: `AND category_id IS NOT NULL` excludes uncategorized expenses.

**CloudKit**: Includes expenses with `categoryId == nil` in the breakdown.

**Fix**: Add `guard txn.categoryId != nil else { continue }` in `CloudKitAnalysisRepository.fetchExpenseBreakdown`.

### 4. Account Sort Order (LOW)

**Server**: `ORDER BY type = "investment", position, name` — investments last.

**CloudKit**: Sorts by `position` only.

**Fix**: Update `CloudKitAccountRepository.fetchAll` to post-sort with investments last.

### 5. Daily Balances — investmentValue & bestFit (LOW)

**Server**: Computes `investmentValue` (from investment values) and `bestFit` (linear regression).

**CloudKit**: Sets both to `nil`.

**Fix**: Implement if these features are needed in offline mode. CloudKit has access to `InvestmentValueRecord` so `investmentValue` could be computed.
