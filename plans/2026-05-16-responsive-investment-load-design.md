# Responsive Investment Load + Sorted-Array Price Caches — Design

**Date:** 2026-05-16
**Status:** Approved (pending spec review)
**Scope:** Approach 2 — decouple the historic-graph build from the investment
account screen so it stays responsive, *plus* fix the quadratic price/rate
fallback lookup that makes the build slow. Day-by-day chart granularity is
retained (no coarsening).

## Problem

Navigating to an investment account with a long trade history (reproduced on
the "Shares" account in the "Large Test Profile") freezes the screen for
several seconds.

### Root cause (profiled)

Stack sampling during the navigation showed:

```
InvestmentAccountView.body closure #3            (InvestmentAccountView.swift:212)
 → maybeAutoWidenRange()                          (InvestmentAccountView+Loading.swift:59)
  → InvestmentStore.positionsViewInput(range:.all)
   → PositionsHistoryBuilder.build(…)             (PositionsHistoryBuilder.swift:93)
    → emitDailyPoints(for: day, …)                (per calendar day, line 171)
     → convertValue → FullConversionService.convert
      → … → StockPriceService.price(ticker:on:)   (StockPriceService.swift:73)
       → StockPriceService.fallbackPrice(…)        (StockPriceService.swift:198)
        → Sequence.sorted()                        ← 2701 / 2884 samples
```

Two compounding defects:

1. **The whole screen is gated on the slow build.** `InvestmentAccountView.body`
   renders a full-screen `ProgressView` while `!initialLoadComplete`
   (`InvestmentAccountView.swift:180`). `initialLoadComplete` only flips `true`
   *after* `reloadPositions()` **and** `maybeAutoWidenRange()` finish
   (lines 209–217), and that chain runs the full-history (`.all`) series build.
   The transaction list is independent of `positionsInput` (its own
   `transactionStore`) but never gets to render because the entire body is
   behind the gate.

2. **The build does an O(n log n) sort on every price/rate lookup.**
   `PositionsHistoryBuilder` walks **every calendar day** from the range start
   to today and converts every held instrument on each day. Markets are closed
   on weekends/holidays (~2/7 of calendar days), so for every non-trading day
   `StockPriceService.price(ticker:on:)` falls through to `fallbackPrice`
   (line 73 → 198), which re-sorts the *entire* price-history key set on every
   single call:

   ```swift
   private func fallbackPrice(ticker: String, dateString: String) -> Decimal? {
     guard let cache = caches[ticker] else { return nil }
     let sortedDates = cache.prices.keys.sorted().reversed()   // O(n log n) per call
     for cachedDate in sortedDates where cachedDate <= dateString { return cache.prices[cachedDate] }
     return nil
   }
   ```

   Over a multi-year `.all` range this is roughly
   `O(instruments × days × days log days)` — the multi-second hang. The
   currency-conversion fan-out and the day-keyed rate cache in
   `FullConversionService` are merely the *driver* that calls this ~10,000
   times; the quadratic blow-up is the per-call re-sort.

The same antipattern exists verbatim in all three price/rate caches:

| Cache model            | Service method                          |
|------------------------|------------------------------------------|
| `StockPriceCache.prices`     | `StockPriceService.fallbackPrice` (~:198)  |
| `ExchangeRateCache.rates`    | `ExchangeRateService.fallbackRate` (~:231) |
| `CryptoPriceCache.prices`    | `CryptoPriceService.fallbackPrice` (~:348) |

A stock→AUD conversion hits both the stock cache and the FX (listing-currency
→ host) cache; crypto accounts hit the crypto cache identically. All three are
fixed together (the "fix all instances" rule).

## Goals

- The investment account screen is interactive immediately: transactions list
  and positions table render without waiting for the historic graph.
- The chart area shows a loading indicator until its series is built, then
  the chart appears (no progressive fill-in — confirmed UX choice).
- The historic-series build itself is fast: price/rate fallback lookups become
  O(log n) instead of O(n log n) per call.
- Lower steady-state memory than today's dictionary caches, important on
  mobile where many instruments × long histories may be cached at once.
- Day-by-day chart point granularity is **retained** (no coarsening — out of
  scope for Approach 2).

## Non-goals

- Coarsening chart resolution / down-sampling long ranges (Approach 1 only).
- Restructuring `FullConversionService`'s day-keyed rate cache or introducing a
  batched factor-series API (the fallback fix removes the dominant cost without
  it).
- Persisting / showing a last-known series on revisit (rejected — "spinner
  until complete" UX).
- Changing the on-disk database schema or adding a migration.

## Design

### 1. Two-phase load (responsiveness)

Split `InvestmentStore`'s monolithic `positionsViewInput(title:range:)` into
two store calls:

- **`loadPositionsInput(account:profileCurrency:) async throws -> PositionsViewInput`**
  — the fast part: `loadAllData` + `fetchAllTransactions` + `costBasisSnapshot`
  + `applyingCostBasis` + `hasAnyHistoricalActivity`. Returns a
  `PositionsViewInput` with `historicalValue: nil` and `historyLoading: true`.
  The fetched transactions are cached on the store (new `loadedTransactions:
  [Transaction]`, keyed implicitly by `loadedAccountId`) so phase 2 does not
  re-fetch.

- **`historicalSeries(range:) async -> HistoricalValueSeries?`**
  — the slow part: runs `PositionsHistoryBuilder.build` against the cached
  `loadedTransactions` / `loadedHostCurrency`. Returns the series; the caller
  merges it into the existing `positionsInput` (producing a copy with
  `historicalValue` set and `historyLoading: false`).

`positionsViewInput(title:range:)` is retained as a thin composition of the two
(load then build then merge) so existing callers/tests keep working.

`InvestmentAccountView` changes:

- `.task(id: LoadKey)`: run phase 1, set `initialLoadComplete = true`
  immediately (screen interactive), then continue in the same task to run
  phase 2 for the current `positionsRange`, merge the series into
  `positionsInput`, then run the auto-widen check.
- `.task(id: positionsRange)`: rebuilds **only** phase 2 (positions and cost
  basis are range-independent), merging the new series in.
- `maybeAutoWidenRange()`: moves into phase 2. It now operates on the
  phase-2 series result — if the account has historical activity but the
  built series for the active range is empty (last trade pre-dates the
  range), rebuild phase 2 with `.all` and set `positionsRange = .all`. It no
  longer runs before `initialLoadComplete`, so it cannot block first paint.

The transaction list (`makeAccountTransactionList()`, driven by
`transactionStore`) is already independent of `positionsInput`; once the
full-screen gate flips after phase 1 it renders and is interactive while
phase 2 is still running.

### 2. Chart loading contract

Add one field to `PositionsViewInput`:

```swift
let historyLoading: Bool   // default false in the designated init
```

`PositionsView` (`Shared/Views/Positions/PositionsView.swift:35`): when
`input.historyLoading` is `true`, render a chart-height container with a
centered `ProgressView` in place of the chart; otherwise the existing
`if input.showsChart { PositionsChart(...) }` logic is unchanged. The
placeholder occupies the same vertical space the chart would, so the layout
does not jump when the series lands. No other view changes.

`historyLoading` does not affect any existing computed property
(`showsChart`, `hasHistoricalSeries`, etc.); those continue to key off
`historicalValue`. Non-investment callers and previews leave it `false` via
the default.

### 3. Sorted-array price/rate caches (all three services)

Replace the date-keyed dictionaries with date-sorted contiguous arrays. This
removes the per-call sort, makes lookups O(log n), and uses strictly less RAM
than `Dictionary` (no hash-bucket over-allocation, no duplicate key storage,
no separate index).

Date representation: **`Int32` in `yyyymmdd` form** (e.g. `2024-01-15` →
`20240115`). `yyyymmdd` integer ordering equals chronological ordering, so
binary search is correct. Integer comparison is faster than the current
string comparison.

In-memory model changes (the `Codable` domain models):

```swift
struct DatedPrice: Codable, Sendable, Equatable {
  let date: Int32          // yyyymmdd
  let price: Decimal
}

struct DatedQuotes: Codable, Sendable, Equatable {
  let date: Int32          // yyyymmdd
  var quotes: [String: Decimal]   // quote code -> rate (small, stays a dict)
}

struct StockPriceCache  { … var prices: [DatedPrice]  … }   // sorted asc by .date
struct CryptoPriceCache { … var prices: [DatedPrice]  … }   // sorted asc by .date
struct ExchangeRateCache{ … var rates:  [DatedQuotes] … }   // sorted asc by .date
```

- `earliestDate` / `latestDate` **remain `String`** fields on each cache.
  They are only 2 per cache, are persisted as meta columns, and are compared
  as ISO strings throughout the fetch-gap logic
  (`StockPriceService` lines ~98/107/168, `ExchangeRateService` ~118/173,
  crypto equivalent). Keeping them avoids rewriting that broad logic and
  bounds the blast radius. (They could later be derived from
  `first`/`last`; out of scope here.)

- Shared helpers (one implementation, reused by all three services):
  - `exactIndex(_ date: Int32) -> Int?` — binary search for an exact entry.
  - `floorIndex(_ date: Int32) -> Int?` — binary search for the newest entry
    with `entry.date <= date` (replaces the `fallback*` linear-after-sort).
  - `merge(_ incoming:)` — sorted-merge of a fetched, date-contiguous chunk;
    later values overwrite earlier ones for the same date (preserving the
    current `existing.prices[dateKey] != price` overwrite semantics).

- Each service's `lookup*`, `fallback*`, `prices(…in:)` / `rates(…in:)`
  range builders, `*Merge`, and hydrate paths are rewritten against the
  array + helpers. Behavior is preserved exactly:
  - exact-date hit → same value as `prices[dateString]` today;
  - non-trading / gap date → same prior-trading-day value the
    sort-then-scan produced;
  - pre-history date → `nil` as today.

- **On-disk schema is unchanged.** The persistence/record-mapping layer
  (`*+Persistence.swift`, GRDB records) converts between the stored ISO date
  string (or existing column type) and the in-memory `Int32` at hydrate and
  write. Loading with `ORDER BY date` yields the sorted array directly,
  removing any hydrate-time sort as a side benefit. No `DatabaseMigrator`
  change.

This change touches GRDB record mapping → the implementation plan routes the
relevant steps through the `database-code-review` agent (and
`database-schema-review` if any record/PRAGMA file is touched, even though no
migration is added).

### 4. Error handling & cancellation

- **Phase 1 failure:** unchanged. `loadAllData` already swallows into
  `self.error`; `costBasisSnapshot` already degrades (omits instruments with
  failed classification). If phase 1 throws, the existing error surface shows.
- **Phase 2 failure:** the chart area shows the existing no-series state
  (`historyLoading` cleared, `historicalValue` nil); the rest of the screen
  stays usable; logged at `.error` (existing log call retained).
- **Cancellation:** navigating away or changing range mid-phase-2 throws
  `CancellationError`, which is ignored exactly as today. Because phase 1 has
  already returned, the screen was usable throughout. `PositionsHistoryBuilder`
  already checks `Task.isCancelled` per day and returns the partial series.

### 5. Testing

Per `guides/TEST_GUIDE.md` (Swift Testing; one-extension-per-protocol;
`TestBackend`, never mock the repository):

- **`InvestmentStore` split** (against `TestBackend`):
  - `loadPositionsInput` returns positions + cost basis with
    `historicalValue == nil` and `historyLoading == true`, and does **not**
    invoke `PositionsHistoryBuilder` (assert via a seam, e.g. a build counter
    or by asserting no series side-effects).
  - `historicalSeries(range:)` reuses `loadedTransactions` — assert the
    transaction repository is **not** fetched a second time after phase 1
    (fetch-count assertion).
  - The composed `positionsViewInput` still returns the fully-populated input
    (regression cover for existing callers).
- **All three `fallback*`** (behavior-preserving, table-driven):
  exact-date, weekend/holiday gap, pre-history, and post-latest dates return
  the same value the old sort-then-scan returned, for stock, FX, and crypto.
- **Plan-pinning performance test:** a multi-year daily walk over a seeded
  cache performs no per-call sort and a bounded number of comparisons
  (inject a comparison/lookup counter into the cache helper; assert it scales
  ~`O(queries · log n)`, not `O(queries · n log n)`).
- **No new UI test required.** Existing `InvestmentAccountView` coverage
  exercises the load path. Optional, if cheap: a UI-test driver assertion
  that the transaction list is hittable before the chart appears (validates
  the responsiveness goal end-to-end). Treated as a stretch item, not a gate.

## Affected files (indicative, not exhaustive)

- `Domain/Models/StockPriceCache.swift`,
  `Domain/Models/CryptoPriceCache.swift`,
  `Domain/Models/ExchangeRateCache.swift` — model shape + `DatedPrice` /
  `DatedQuotes`.
- New: `Shared/SortedDateSeries.swift` — a small generic sorted-by-`Int32`-date
  collection (`exactIndex` / `floorIndex` / `merge`), reused by all three
  services. (Final name/location may be adjusted in the plan, but it is a
  single shared type, not duplicated per service.)
- `Shared/StockPriceService.swift`, `Shared/ExchangeRateService.swift`,
  `Shared/CryptoPriceService*.swift` — rewrite lookup/fallback/merge/range
  builders against the array.
- `Shared/StockPriceService` / `ExchangeRateService+Persistence.swift` /
  `CryptoPriceService+Persistence.swift` + GRDB records — String↔Int32
  mapping at the persistence boundary.
- `Domain/Models/PositionsViewInput.swift` — `historyLoading` field.
- `Shared/Views/Positions/PositionsView.swift` — chart-loading placeholder.
- `Features/Investments/InvestmentStore+PositionsInput.swift`,
  `InvestmentStore+Loading.swift` — two-phase API + `loadedTransactions`.
- `Features/Investments/Views/InvestmentAccountView.swift`,
  `InvestmentAccountView+Loading.swift` — task wiring, gate, auto-widen
  relocation.

## Risks & mitigations

- **Behavior drift in fallback semantics.** Mitigated by table-driven
  behavior-preserving tests written *before* the rewrite (TDD), covering the
  exact/gap/pre-history/post-latest cases for all three services.
- **Persistence mapping bug (String↔Int32).** Mitigated by round-trip
  persistence tests and routing through `database-code-review`.
- **Auto-widen regression** (now in phase 2): covered by store tests for the
  "last trade pre-dates default range → widens to `.all`" case.
- **Layout jump when the chart lands.** Mitigated by the fixed-height
  placeholder occupying the chart's space while `historyLoading`.

## Verification

After implementation, re-profile the original repro (Shares account, Large
Test Profile) via the `profile-performance` + `automate-app` skills and
confirm: (a) the transaction list is visible/interactive within a frame or
two of navigation; (b) the per-call `.sorted()` no longer dominates the
sample; (c) the `⚠️ PERF` / conversion log volume drops accordingly.
