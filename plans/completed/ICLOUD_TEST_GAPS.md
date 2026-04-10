# iCloud Backend — Contract Test Gaps

**Date:** 2026-04-10
**Source:** Audit of moolah-server integration tests vs native contract tests

## Critical Gaps (affect correctness)

### 1. Financial Month Boundaries
- Custom `monthEnd` parameter affects which dates belong to which financial month
- Server tests verify boundary day handling (on exact day vs after day)
- Native tests don't test `monthEnd` grouping at all in expense breakdown or income/expense

### 2. Investment Transfer Accounting
- Bank-to-investment transfers should count as earmarkedIncome
- Investment-to-bank should count as earmarkedExpense
- Investment-to-investment transfers don't affect balance/investments
- Native has one basic test but not multi-leg scenarios

### 3. Transfer Validation Rules
- Missing toAccountId rejection
- Same-account transfer rejection (toAccountId = accountId)
- Proper balance updates for both source and destination
- Native has no transfer-specific validation tests

### 4. Category Deletion Cascade to Transactions
- Server nulls out categoryId in transactions when category is deleted
- Native tests category deletion but not transaction cascading

## Important Gaps

### 5. Pagination with Prior Balance
- Verify `priorBalance` is correctly computed across page boundaries
- Verify empty page behavior at various boundaries

### 6. Earmark Balance from Transactions
- Contract test should verify that earmark balance/saved/spent are correctly computed from transactions, not stored

### 7. Cross-Check Invariants
- Sum of account balances = daily balance + investments
- Sum of category balances matches total expense
- Consistent results across different `after` dates

### 8. Null AccountId Handling
- Earmarked income without accountId excluded from balance but included in earmarked
- Tests should cover this edge case

## Minor Gaps

### 9. Sort Order Guarantees
- Explicit sort order tests for transactions (date DESC), daily balances (date ASC), expense breakdown (month DESC)

### 10. Budget Upsert Semantics
- Setting budget twice should update, not create duplicate

### 11. Account Balance Requirement for Deletion
- Already tested for InMemory but should verify CloudKit enforces zero-balance check
