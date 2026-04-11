# Known Bugs

## iCloud backend: category balance calculation returns negated values

**Component:** `CloudKitAnalysisRepository.fetchCategoryBalances`
**Severity:** Medium
**Found:** 2026-04-11 (during data migration testing)

The `fetchCategoryBalances` method in the CloudKit backend returns values with inverted signs compared to the remote backend. For example, expenses that should be negative are returned as positive (or vice versa). This affects the "Expenses by Category" analysis view when using an iCloud profile.
