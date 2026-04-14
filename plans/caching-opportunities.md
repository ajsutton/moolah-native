# Caching Opportunities

Identified during performance optimization work. These are places where caching could help but would increase memory usage. Investigate individually when the non-caching optimizations are complete.

## High Impact

### Category tree cache
**Where:** `CategoryStore.reloadFromSync()`, `CategoryRepository.fetchAll()`
**What:** The flattened category tree with computed paths is rebuilt on every load. Could cache the `Categories` wrapper and invalidate only on category mutations or sync.
**Memory cost:** Small (158 categories at 1x).

### Analysis data per time range
**Where:** `AnalysisStore.loadAll()`, `CloudKitAnalysisRepository`
**What:** Analysis fetches ALL transactions and recomputes everything on every call. Could cache the computed `AnalysisData` keyed by (historyMonths, forecastMonths) and invalidate when transactions change.
**Memory cost:** Medium. Daily balances array could be large for "All" history.
**Note:** AnalysisStore already has a filter-match check that skips reload if params unchanged. This would extend that to survive across navigations.

### Account balance granular invalidation
**Where:** `ProfileSyncEngine.invalidateCachedBalances()`
**What:** Currently invalidates ALL account balances when any transaction syncs. Could track which accountIds are affected and only invalidate those.
**Memory cost:** Negligible (set of UUIDs).
**Note:** This overlaps with optimization 1.3 in the perf design. The caching angle is: could we also incrementally update balances from sync data rather than invalidating?

## Medium Impact

### Payee frequency map
**Where:** `CloudKitTransactionRepository.fetchPayeeSuggestions()`
**What:** Currently loads all transactions with payees on every keystroke. A precomputed payee→count map would make suggestions instant.
**Memory cost:** Small-medium (one entry per unique payee string).
**Invalidation:** On transaction create/update/delete.

### Transaction page cache
**Where:** `TransactionStore.load(filter:)`, `TransactionStore.loadMore()`
**What:** Cache recently loaded pages keyed by (filter, page). Invalidate on any transaction mutation.
**Memory cost:** Medium (50 TransactionWithBalance per page, could hold several pages).

### Financial month boundary table
**Where:** `CloudKitAnalysisRepository.financialMonth()`
**What:** Precompute month start/end dates for the relevant range. Avoid per-transaction Calendar calls.
**Memory cost:** Negligible (one Date pair per month, ~60 entries for 5 years).

## Lower Impact

### Investment values per account
**Where:** `CloudKitAnalysisRepository.fetchAllInvestmentValues()`
**What:** Cache aggregated daily values per investment account. Invalidate on investment value mutations.
**Memory cost:** Medium (2711 entries at 1x).

### Domain object pool for Currency
**Where:** `TransactionRecord.toDomain()`, `Currency.from()`
**What:** Cache Currency instances by code string to avoid repeated lookups.
**Memory cost:** Negligible (one instance per currency code).
**Note:** May already be optimized if Currency is an enum.
