# Trades-Mode Historical Net-Worth Contribution — Design

**Date:** 2026-05-04
**Status:** Draft — round 2 (post-review revisions)
**Tracking issue:** [#738](https://github.com/ajsutton/moolah-native/issues/738)
**Predecessor:**
[`plans/completed/2026-05-04-per-account-valuation-mode-design.md`](completed/2026-05-04-per-account-valuation-mode-design.md)
(Pre-Existing Limitation: Historical Chart, plus §5e).

## Scope

Make trades-mode investment accounts contribute correctly to the historical
net-worth chart by adding a per-day "valued positions over time" fold. For
each trades-mode investment account, compute the held positions
(per-instrument quantities) cumulative through each historical day with
activity, valuate each instrument quantity in the profile instrument using
the historical price for that day (per
`guides/INSTRUMENT_CONVERSION_GUIDE.md` Rule 5), and add the result into the
day's `DailyBalance.investmentValue` and `netWorth`.

In the same change, tighten the existing snapshot fold
(`applyInvestmentValues`) to comply with Rule 11: a per-day conversion
failure removes that day from `dailyBalances` (matches `walkDays`'s
existing per-day error contract) instead of silently leaving a partial
total in place. Drop the vestigial `?` on `sumInvestmentValues`'s
return type (it never returns `nil` on success) at the same time so
the predecessor and the new helper share a clean signature. Both folds
end up with the same Rule 11 behaviour after this PR.

The current value (today's number) is already correct for trades-mode
accounts via `PositionsValuator`; only the *historical series* is broken.

## Motivation

PR series #731–#736 introduced the per-account `ValuationMode` toggle
(`recordedValue` / `calculatedFromTrades`). PR #735 wired the daily-balance
fold to filter `fetchInvestmentAccountIds` by mode so trades-mode accounts
no longer leak stale snapshots into the historical chart. This left a
documented hole: there is no equivalent fold for *trade-derived position
market values over time*. A trades-mode account with no snapshots and only
trades silently contributes zero (or only the cash transfer leg of each
trade) to the historical net-worth chart. The chart is therefore
inaccurate for any user who:

- imports trades from CSV into a fresh investment account, then flips it to
  trades mode, **or**
- creates a new investment account (which now defaults to
  `.calculatedFromTrades` after PR #736).

Issue #738 calls this out as the natural next step now that the toggle
itself is shipped and stable.

A first-round review surfaced a Critical Rule 11 finding: the new fold's
proposed "log + skip override" failure contract would have replicated the
existing `applyInvestmentValues` deviation, leaving partial totals in
`investmentValue` / `netWorth` when a day's conversion fails. The revised
design fixes Rule 11 in **both** folds in this PR — see §6 and §10.

## Goals

- For every trades-mode investment account, the historical net-worth chart
  reflects the value of its held positions on every historical day with
  activity, using historical prices for that day.
- Snapshot-mode accounts continue to contribute via `applyInvestmentValues`.
- Mixed-mode profiles (some accounts in each mode) sum both contributions
  cleanly into a single `investmentValue` per day.
- Per-day Rule 11 contract for **both** folds: log + drop the day from
  `dailyBalances` on conversion failure (matches `walkDays`'s existing
  contract). `CancellationError` rethrows immediately.
- All historical conversions go through `InstrumentConversionService` on
  the day's `Date` (Rule 5 / Rule 8 fast path / Rule 10 same-startOfDay
  normalization).
- SQL plan-pinning maintained — the new SELECT mirrors the existing
  snapshot-mode predicate and uses the same `account_by_type` index.

## Non-Goals

- **No change to the forecast tail.** Forecast days continue to use the
  `generateForecast` extrapolation. Trades-mode accounts do not contribute
  to forecast days under this change. (Trade transactions are not
  recurring, so the forecast pipeline never sees them; today's positions
  carry forward to the forecast tail only via the existing position-book
  state, which the forecast already handles for non-investment accounts.)
- **No new conversion service.** The fold uses the existing
  `InstrumentConversionService` — same path that
  `PositionsHistoryBuilder` and `PositionsValuator` already use.
- **No change to `PositionsValuator`** (current-value path).
- **No change to per-account chart on `InvestmentAccountView`**
  (`PositionsHistoryBuilder` already covers it).
- **No new `Position`-history schema or persisted series.** The series is
  computed Swift-side per request from the existing `transaction_leg`
  rows (same source of truth as `walkDays` itself), so there is no new
  persisted state, no new sync surface, and no new migration.
- **No on-screen "this day's contribution unavailable" affordance.** The
  chart already gaps days dropped by `walkDays` on conversion failure;
  this PR makes the snapshot and trades folds consistent with that
  behaviour. A surfaced retry-now affordance is a separate UI concern.

## Design

### 1. New SQL fetch — trades-mode investment account ids

Add a sibling of `fetchInvestmentAccountIds` in the same file
(`Backends/GRDB/Repositories/GRDBAnalysisRepository+DailyBalancesInvestmentValues.swift`):

```swift
static func fetchTradesModeInvestmentAccountIds(
  database: Database
) throws -> Set<UUID> {
  let rows = try Row.fetchAll(
    database,
    sql: """
      SELECT id FROM account
      WHERE type = 'investment' AND valuation_mode = 'calculatedFromTrades'
      """)
  // ... same decode as fetchInvestmentAccountIds ...
}
```

Plain string-literal SQL — kept as a separate function (rather than a
parameterised predicate) for `guides/DATABASE_CODE_GUIDE.md` §4. The query
shape is identical to the existing snapshot-mode predicate and resolves
through the same `account_by_type` index — the only difference is the
`valuation_mode` literal. See §8 for the plan-pinning test.

### 2. Aggregation type carries pre-filtered trades-mode rows

Extend `DailyBalancesAggregation` (`+DailyBalances.swift`) with **two**
new fields, mirroring the way `applyInvestmentValues` consumes
`investmentValues: [InvestmentValueSnapshot]` (a purpose-built bundle,
not the raw row arrays):

```swift
struct DailyBalancesAggregation: Sendable {
  // existing fields ...
  let investmentAccountIds: Set<UUID>            // recorded-value (existing)
  let tradesModeInvestmentAccountIds: Set<UUID>  // new
  /// Pre-cutoff `transaction_leg` SUM rows filtered to trades-mode
  /// investment accounts only. Pre-fold seed for the new fold's
  /// cumulative position dict.
  let priorTradesModeAccountRows: [DailyBalanceAccountRow]  // new
  /// Post-cutoff `transaction_leg` SUM rows filtered to trades-mode
  /// investment accounts only.
  let tradesModeAccountRows: [DailyBalanceAccountRow]       // new
  // ...
}
```

Pre-filtering inside `readDailyBalancesAggregation` (the synchronous
helper that runs inside the existing single `database.read` snapshot, so
all classifications observe one MVCC state — no need for a separate
`database.read`) keeps `applyTradesModePositionValuations` focused on
the cumulative-position fold and avoids duplicating the row-type filter
across both `walkDays` and the new fold. The cost is one in-memory
filter pass per aggregation read; row counts are bounded by the existing
SUM aggregation (one row per `(day, account, instrument, type)`),
typically O(thousands) for an active profile.

`investmentAccountIds` keeps its current meaning (recorded-value only) —
exactly as PR #735 designed — and continues to drive `accountsFromTransfers`
membership in the seed and walk steps. The new account-id set has a
single consumer: the new fold's empty-check.

### 3. Assembly context exposes the trades-mode set

Extend `DailyBalancesAssemblyContext` (`+DailyBalances.swift`) with the
trades-mode set so the new fold can take it from a stable context object
rather than a free parameter — matches the existing pattern of carrying
`investmentAccountIds`, `instrumentMap`, `profileInstrument`,
`conversionService` in one struct:

```swift
struct DailyBalancesAssemblyContext: Sendable {
  let investmentAccountIds: Set<UUID>            // recorded-value (existing)
  let tradesModeInvestmentAccountIds: Set<UUID>  // new
  let instrumentMap: [String: Instrument]
  let profileInstrument: Instrument
  let conversionService: any InstrumentConversionService
}
```

The construction site in `assembleDailyBalances` is updated to pass the
new field through:

```swift
let context = DailyBalancesAssemblyContext(
  investmentAccountIds: aggregation.investmentAccountIds,
  tradesModeInvestmentAccountIds: aggregation.tradesModeInvestmentAccountIds,
  instrumentMap: aggregation.instrumentMap,
  profileInstrument: profileInstrument,
  conversionService: conversionService)
```

`seedPriorBook`, `walkDays`, and `applyDailyDeltas` continue to read only
`investmentAccountIds` (recorded-value) for `accountsFromTransfers`
membership — none of those helpers need to know about the trades-mode
set, because trades-mode accounts contribute via the new fold instead.

### 4. New fold — `applyTradesModePositionValuations`

Lives next to `applyInvestmentValues` in
`+DailyBalancesInvestmentValues.swift` so the two folds share a file.
The function is `static` and carries no actor annotation — it is
called from the existing `@concurrent` `assembleDailyBalances` and
inherits the off-main context, matching `applyInvestmentValues`. Public
entry point:

```swift
/// Per-day position-valuation fold for trades-mode investment accounts.
/// Sister of `applyInvestmentValues` — same per-day error contract:
/// `CancellationError` rethrows immediately; any other thrown error
/// drops the day from `dailyBalances` and logs through
/// `handleInvestmentValueFailure`.
///
/// `priorRows` and `postRows` carry only rows whose `accountId`
/// belongs to a trades-mode investment account — pre-filtered in
/// `readDailyBalancesAggregation` so this fold neither re-checks
/// membership nor walks rows for accounts it doesn't own.
static func applyTradesModePositionValuations(
  priorRows: [DailyBalanceAccountRow],
  postRows: [DailyBalanceAccountRow],
  to dailyBalances: inout [Date: DailyBalance],
  context: DailyBalancesAssemblyContext,
  handlers: DailyBalancesHandlers
) async throws
```

Algorithm — designed as a **cursor walk** mirroring
`applyInvestmentValues` / `advanceInvestmentCursor` so cumulative
position state is updated for every day with trades-mode activity,
even days that are absent from `dailyBalances` (e.g. dropped by an
earlier fold's per-day failure). Walking only `dailyBalances.keys`
would silently miss those days' trades and corrupt carry-forward
positions on every following day.

1. **Early return** if `context.tradesModeInvestmentAccountIds.isEmpty`
   or `dailyBalances.isEmpty` (matches `applyInvestmentValues`'s guard
   shape).
2. **Pre-fold priors** into a per-account, per-instrument cumulative
   dict `var positions: [UUID: [Instrument: Decimal]] = [:]`.
   `Instrument` conforms to `Hashable`
   (`Domain/Models/Instrument.swift:4`); the shape mirrors
   `PositionBook.accounts`. For each prior row:
   1. Resolve the instrument via
      `resolveInstrument(row.instrumentId, in: context.instrumentMap)`
      (the existing helper at the bottom of `+DailyBalances.swift` —
      same call as `applyDailyDeltas`).
   2. Decode the raw `Int64` `qty` via
      `InstrumentAmount(storageValue: row.qty, instrument: instrument).quantity` —
      same pattern as `applyDailyDeltas` so storage-unit semantics
      stay pinned in one place.
   3. `positions[row.accountId, default: [:]][instrument, default: 0] += quantity`.
3. **Build a sorted cursor over post rows.** Decode each `postRow` into
   an internal `(dayKey: Date, accountId: UUID, instrument: Instrument,
   quantity: Decimal)` tuple, where
   `dayKey = Calendar.current.startOfDay(for: row.sampleDate)`. Sort
   the array by `dayKey` ascending. This is the new fold's equivalent
   of `applyInvestmentValues`'s sorted `[InvestmentValueSnapshot]` — a
   pre-built, instrument-resolved, dayKey-keyed cursor that the walk
   advances through. Grouping by the SQL `\.day` UTC string is
   intentionally avoided here: the new fold's outer iteration is over
   local `Date` keys, and matching UTC day-strings to local-startOfDay
   keys would re-introduce the Rule 10 timezone bug. Building the
   cursor at `dayKey` granularity directly removes the mismatch.
4. **Walk `dailyBalances.keys.sorted()`** in date order. Maintain a
   cursor index `valueIndex` over the sorted post-row tuples. For each
   `dayKey`:
   1. **Advance the cursor:** while `valueIndex < tuples.count` and
      `tuples[valueIndex].dayKey <= dayKey`, apply
      `positions[t.accountId, default: [:]][t.instrument, default: 0] += t.quantity`
      and `valueIndex += 1`. This applies *every* trades-mode row
      whose `dayKey` is on-or-before the current outer `dayKey`,
      including rows for days that are not themselves in
      `dailyBalances` (the carry-forward correctness fix).
   2. Skip the rest of this iteration if `positions` is empty (no
      trades-mode account has ever held anything yet) — leaves the
      day's `DailyBalance` untouched.
   3. Inside the explicit two-catch block from §10, call
      `sumTradesModePositions(positions:on:profileInstrument:conversionService:)`
      to obtain the day's `InstrumentAmount` total in the profile
      instrument.
   4. **On success:** rebuild the day's `DailyBalance` with
      `investmentValue = (existing.investmentValue ??
      .zero(instrument: profileInstrument)) + total` and `netWorth =
      balance + investmentValue`. Because `dayKey` came from
      `dailyBalances.keys.sorted()`, the existing entry is provably
      present — direct subscript access (`dailyBalances[dayKey]!`) is
      sound, but the spec sketch in §10 uses an `if let existing` bind
      to keep the success-path code readable without an
      implicit-unwrap.
   5. **On any non-cancellation throw (Rule 11 — failing day must
      surface as unavailable):** log via
      `handlers.handleInvestmentValueFailure(error, dayKey)` and
      `dailyBalances.removeValue(forKey: dayKey)`. The chart shows a
      gap on that day, matching `walkDays`'s existing per-day-failure
      contract.
5. **After the outer walk completes**, any tail tuples whose `dayKey`
   exceeds every `dailyBalances` key are intentionally not visited.
   They cannot affect any output because no `dailyBalances` entry on
   or after them exists. (The bestFit / forecast steps run on the
   already-converted historic span, and forecast valuation is out of
   scope per §Non-Goals.)

The `priorRows` / `postRows` parameters are deliberately *not* the
unfiltered `aggregation.priorAccountRows` / `aggregation.accountRows`
— they're the pre-filtered fields from §2, named without the
`accountRows` suffix to avoid suggesting "every account" at the call
site. The doc comment on the entry point states the filtering
contract explicitly.

### 5. Conversion helper — `sumTradesModePositions`

Mirrors `sumInvestmentValues`, file-private, **non-optional** return
type. As part of this PR, also clean up the vestigial `?` on
`sumInvestmentValues`'s return type — it never returns `nil` on
success (any error throws), and dropping the `?` removes a latent
silent-nil-return risk and brings the predecessor signature into line
with the new helper. The mechanical change: drop `?` from
`sumInvestmentValues`'s return type, return the `InstrumentAmount`
directly at the bottom of the function, and update the single caller
in `applyInvestmentValues` to `let totalValue = try await
sumInvestmentValues(...)` (no optional-bind).

```swift
private static func sumTradesModePositions(
  positions: [UUID: [Instrument: Decimal]],
  on date: Date,
  profileInstrument: Instrument,
  conversionService: any InstrumentConversionService
) async throws -> InstrumentAmount
```

For each `(accountId, [Instrument: Decimal])`, for each
`(instrument, qty)`:

- If `instrument.id == profileInstrument.id`, add `qty` to the running
  `Decimal` total (Rule 8 fast path — applied at the leaf level so an
  account holding both profile-instrument and foreign-instrument
  positions still routes only the foreign positions through the
  service).
- Otherwise call `conversionService.convert(qty, from: instrument, to:
  profileInstrument, on: date)` and add the result.

A failed convert throws to the caller (per-day error contract — see
§4). Returns `InstrumentAmount(quantity: total, instrument:
profileInstrument)`. On a warm cache the per-day cost is
O(distinct instruments held that day), which is bounded.

**Cancellation contract.** The inner loop relies on the conversion
service's cooperative cancellation: every `await
conversionService.convert(...)` is itself a suspension point that
re-checks `Task.isCancelled` and throws `CancellationError` when the
enclosing task is cancelled. The `CancellationError` propagates
through this helper into the per-day two-catch block in §10, where
the cancel branch rethrows immediately. No manual `Task.isCancelled`
check between iterations is required — same pattern as
`sumInvestmentValues`. The Rule 8 fast-path branch performs no
suspension, so a single `Task.isCancelled` check at the top of the
helper would only fire after each suspension anyway; we omit it for
parity with the predecessor.

The caller passes `dayKey` (the `startOfDay`-normalized key from §4)
as `on:`. Add a one-line comment at the call site stating "`dayKey`
is `Calendar.current.startOfDay(for: row.sampleDate)` — same
normalization as `walkDays` and the conversion-service lookup" so
future readers don't need to chase the call site to verify Rule 10.

### 6. Wire into `assembleDailyBalances` and tighten the snapshot fold

Inside `assembleDailyBalances` (`+DailyBalances.swift`), after the
existing `applyInvestmentValues` call:

```swift
try await applyInvestmentValues(
  aggregation.investmentValues,
  to: &dailyBalances,
  context: context,
  handlers: handlers)

try await applyTradesModePositionValuations(
  priorRows: aggregation.priorTradesModeAccountRows,
  postRows: aggregation.tradesModeAccountRows,
  to: &dailyBalances,
  context: context,
  handlers: handlers)
```

**`applyInvestmentValues` is updated in this PR** so its per-day error
branch matches the new fold (and `walkDays`). Concretely:

- The existing two-catch block at lines 130–135 of
  `+DailyBalancesInvestmentValues.swift` already has the right shape
  (`catch let cancel as CancellationError { throw cancel } catch
  { ... }`); the only diff is in the second catch's body.
- **Before:** the second catch was
  `handlers.handleInvestmentValueFailure(error, date); continue`.
- **After:**
  ```swift
  catch {
    handlers.handleInvestmentValueFailure(error, date)
    dailyBalances.removeValue(forKey: date)  // new — Rule 11
    continue
  }
  ```
- The success-path guard `guard let totalValue, let balance =
  dailyBalances[date] else { continue }` (line 136) is unchanged —
  not affected by this fix.

Before this change, a snapshot-fold conversion failure left the day's
`DailyBalance` untouched — the chart line at that day reflected only
the bank-balance + transfers-only investments contribution, with no
indication that the snapshot couldn't be computed. Per Rule 11, that's
an incorrect partial total rendered as authoritative. Removing the
day matches `walkDays`'s existing per-day-failure contract and ends
the deviation called out in the round-1 instrument-conversion review.

**Fold ordering.** Output (`investmentValue` / `netWorth` updates) is
order-independent because the two folds touch disjoint account sets,
both drop the day from `dailyBalances` on failure (if either fold
fails for a day, the day is gone from the result regardless of which
ran first), and addition is commutative. The cumulative-position
update inside the trades fold (§4 step 4i) advances regardless of
whether the current day is still in `dailyBalances` — so a day
dropped by `applyInvestmentValues` does not skip its trades-mode
rows, and the carry-forward position state stays correct on every
following day. Logging order (snapshots before trades) is the only
observable order difference.

`applyBestFit` and the forecast tail run after both folds, both
already iterate `dailyBalances.values` — they automatically skip
dropped days.

### 7. Edge cases

- **No trades-mode accounts in the profile.** The pre-filter produces
  empty arrays; the new fold early-returns; behaviour is bit-identical
  to today.
- **Trades-mode account with only a `.transfer` leg (cash deposited but
  never traded).** The cash sits as a position on the investment
  account; the fold sums it via the Rule 8 fast path (or via FX
  conversion if the cash leg is in a non-profile fiat). The day's
  `investmentValue` picks up the cash. This is correct — cash on an
  investment account is part of the account's value.
- **Trades-mode account with a buy on day D and no other activity.**
  Day D appears in `dailyBalances` (walkDays sees the trade legs as
  account rows). The fold valuates the position on day D using day D's
  price. Days after D with other-account activity carry forward the
  position via the cumulative dict; their valuations use that day's
  price.
- **Stock not yet listed on day D (price-cache miss).** Conversion
  throws → fold logs via `handleInvestmentValueFailure` → fold drops
  day D from `dailyBalances`. The chart shows a gap on D. Sibling days
  render normally.
- **Same-day BUY + SELL of equal quantities.** SQL `SUM` over legs
  grouped by `(day, account, instrument, type)` does *not* net BUY vs
  SELL (those are still both `type = 'trade'` but with opposite
  quantities — they net inside the same group). After the cumulative
  fold, the per-instrument quantity for the day is zero. The fold
  sums it (zero contribution via fast path) and adds zero to
  `investmentValue` — i.e. the day's `investmentValue` stays at
  whatever the snapshot fold produced (or `.zero(...)` if no snapshot
  fold ran for the day). This is correct: a day with no net position
  change should not move `investmentValue`.
- **Profile instrument changes mid-history.** Out of scope (no profile
  flow currently allows this), and would require re-running the
  pipeline with a new profile instrument anyway.
- **Mixed-mode profile.** Snapshot and trades-mode accounts are
  partitioned by `valuation_mode`; the snapshot fold reads
  `recorded-value` accounts only; the trades fold reads
  `calculated-from-trades` accounts only. Both fold totals add into
  one `investmentValue` per day. Either fold's failure on day D drops
  D entirely (per §6).
- **Mode flip mid-window.** A user flipping an account from snapshot
  to trades changes the SQL classification; the next pipeline run
  classifies the account into the new set. The historic chart will
  re-render under the new mode (snapshot contributions disappear;
  trades contributions appear). This matches today's mode-flip
  semantics — same surface, no special handling.

### 8. SQL plan-pinning test

Add one pinning test to `MoolahTests/Backends/GRDB/DailyBalancesPlanPinningTests.swift`,
named symmetrically to the sibling
`fetchInvestmentAccountIdsUsesAccountByType`:

```swift
@Test("fetchTradesModeInvestmentAccountIds uses account_by_type")
func fetchTradesModeInvestmentAccountIdsUsesAccountByType() throws {
  let database = try makeDatabase()
  // Mirrors the per-account id loader driven by
  // `GRDBAnalysisRepository.fetchTradesModeInvestmentAccountIds`. The
  // production SQL filters on `type = 'investment'` AND
  // `valuation_mode = 'calculatedFromTrades'`. The `account_by_type`
  // index keys on `(type)` and serves the selective `type =
  // 'investment'` predicate; the `valuation_mode` predicate filters
  // the candidate rows post-seek. SQLite emits `SEARCH account USING
  // INDEX account_by_type` for this shape, which is *not* a full
  // table scan.
  let detail = try planDetail(
    database,
    query: """
      SELECT id FROM account
      WHERE type = 'investment' AND valuation_mode = 'calculatedFromTrades'
      """)
  #expect(detail.contains("SEARCH account USING INDEX account_by_type"))
  #expect(!PlanPinningTestHelpers.planHasFullTableScanOf(detail, alias: "account"))
}
```

The assertion deliberately matches the sibling one-for-one — same
index name, same scan-rejection — so a regression that diverges the
two predicates is visible.

### 9. Tests

All new tests use Swift Testing per `guides/TEST_GUIDE.md`. Reuses the
existing `DateFailingConversionService`
(`MoolahTests/Support/DateFailingConversionService.swift`) for Rule 11
scoping, and `DateBasedFixedConversionService` for the per-day rate
table — no new test doubles.

#### 9.1 Plan-pinning

- §8: `fetchTradesModeInvestmentAccountIdsUsesAccountByType`. The
  Swift-side filter pass that produces `priorTradesModeAccountRows`
  / `tradesModeAccountRows` from the existing prior/post arrays is an
  in-memory `Array.filter` (no SQL), so no additional plan-pinning
  test is required for it.

#### 9.2 Aggregation-layer integration

Add to the existing
`MoolahTests/Backends/GRDB/GRDBDailyBalancesAggregateTests.swift` (or
its closest sibling):

- **`fetchDailyBalancesAggregation` populates
  `tradesModeInvestmentAccountIds`** when the profile contains a
  trades-mode account.
- **`fetchDailyBalancesAggregation` populates
  `priorTradesModeAccountRows` and `tradesModeAccountRows`** with
  *only* trades-mode account rows (sibling recorded-value account
  rows are excluded from these fields, even though they remain in
  `priorAccountRows` / `accountRows`).
- **Empty-mode profile** → both fields are empty arrays.

#### 9.3 Fold contract

Add to
`MoolahTests/Backends/GRDB/GRDBAnalysisRepositoryDailyBalancesTests.swift`
(or its closest sibling):

1. Trades-mode account with one buy of N shares at price P on day D
   → day D's `investmentValue` ≈ `N * P`. Day D+1 (if present in
   `dailyBalances`) carries the position forward and revaluates at
   day D+1's price.
2. Two trades-mode accounts, both with positions on day D →
   `investmentValue` sums both contributions.
3. One trades-mode + one recorded-value account on day D → Day D's
   `investmentValue` = (recorded snapshot total) + (trades-mode
   valuation). `netWorth` reflects both.
4. **Rule 11 per-day failure scoping** for the new fold — a
   `DateFailingConversionService` that throws only on day D drops day
   D from `dailyBalances`, leaves day D-1 and D+1 intact, and fires
   `handleInvestmentValueFailure` exactly once with `(error, dayKey:
   D)`.
5. **Rule 11 per-day failure scoping** for the snapshot fold (new
   behaviour) — a snapshot-conversion failure on day D drops day D
   from `dailyBalances`, leaves siblings intact. Pinned by the same
   `DateFailingConversionService` shape as case 4.
6. **Rule 11 mixed-fold failure** — when both folds run and the trades
   fold fails on day D (the snapshot fold succeeded on D), day D is
   dropped, sibling days unaffected.
7. **Rule 10 same-startOfDay normalization** — a trade transaction at
   23:59:59 local on day D and a trade at 00:00:01 local on day D+1
   apply on the correct days; `Calendar.current.startOfDay`-keyed
   comparisons match `walkDays`'s key.
8. **No trades-mode accounts ⇒ no behaviour change** — fold is a
   no-op; `investmentValue` reflects only the snapshot fold; pinning
   tests for the existing path stay green.
9. **Empty `dailyBalances` ⇒ no-op** — nothing to fold over; no
   logger output.
10. **CSV-imported trade with a `.transfer` cash leg + a `.trade`
    position leg.** A profile-instrument cash transfer of `C` and a
    same-day trade buying `N` shares of an instrument priced `P` on
    that day → day's `investmentValue` ≈ `C + N * P`. Cash leg adds
    via Rule 8 fast path (in profile instrument) or FX otherwise;
    position leg adds via stock-price conversion.
11. **Same-day BUY + SELL of equal quantities** → day's net
    contribution = zero; `investmentValue` unchanged from the
    snapshot fold.
12. **Carry-forward correctness across a dropped day** — a
    trades-mode account has a buy on day D₁; the snapshot fold drops
    day D₁ from `dailyBalances` (e.g. via a recorded-value
    snapshot-conversion failure on a sibling account). Day D₂
    (D₂ > D₁) is in `dailyBalances` and the trades-mode position is
    valuated correctly on D₂ — i.e. day D₁'s buy was applied to the
    cumulative `positions` dict during the cursor walk even though
    D₁ itself was not visited as an output day. Asserts that the
    fix in §4 step 4i (advance positions for every dayKey ≤ outer
    dayKey, regardless of `dailyBalances` membership) is in effect.

### 10. Two-catch shape (literal sketch)

Both folds use the same explicit two-catch pattern so future readers
don't have to infer the cancellation contract from prose. `dayKey`
came from `dailyBalances.keys.sorted()` — the entry must exist, so we
bind it via `if let existing = dailyBalances[dayKey]` rather than
force-unwrapping; either is sound, the `if let` reads more naturally:

```swift
do {
  let total = try await sumTradesModePositions(
    positions: positions,
    // dayKey is `Calendar.current.startOfDay(for: row.sampleDate)` —
    // same normalization as walkDays and the conversion-service lookup.
    on: dayKey,
    profileInstrument: context.profileInstrument,
    conversionService: context.conversionService)
  if let existing = dailyBalances[dayKey] {
    let combined =
      (existing.investmentValue ?? .zero(instrument: context.profileInstrument))
      + total
    dailyBalances[dayKey] = DailyBalance(
      date: existing.date,
      balance: existing.balance,
      earmarked: existing.earmarked,
      availableFunds: existing.availableFunds,
      investments: existing.investments,
      investmentValue: combined,
      netWorth: existing.balance + combined,
      bestFit: existing.bestFit,
      isForecast: existing.isForecast)
  }
} catch let cancel as CancellationError {
  throw cancel
} catch {
  handlers.handleInvestmentValueFailure(error, dayKey)
  dailyBalances.removeValue(forKey: dayKey)
  continue
}
```

`applyInvestmentValues` is updated per §6 to match in the catch
branch — the only difference between the two folds is which input
drives the per-day total (cumulative positions vs. carry-forward
snapshots).

### 11. Logging

Both folds reuse
`DailyBalancesHandlers.handleInvestmentValueFailure: @Sendable (Error,
Date) -> Void`. The production caller wires this to the existing
`Logger` (`subsystem: "com.moolah.app", category:
"GRDBAnalysisRepository"`). No new logger category required.

`Calendar.current` is used inside the `@concurrent`
`assembleDailyBalances` for the `startOfDay` math — Foundation's
`Calendar` is a value type and `Calendar.current` returns a copy, so
the access is safe in the off-main context. This matches the existing
`walkDays` and `advanceInvestmentCursor` usage.

### 12. Performance

- **Pre-filter inside `readDailyBalancesAggregation`:** O(N_total)
  one-shot pass over the SUM rows, where `N_total` is the bounded SUM
  row count.
- **Pre-fold priors:** O(N_priors_trades_only).
- **Per day:** O(M × I) conversion calls, where M = trades-mode
  account count and I = distinct instruments held. Warm-cache calls
  are O(1) per (instrument, date) tuple via `StockPriceCache` /
  `ExchangeRateCache` / `CryptoPriceCache`. Cold-cache calls pay one
  round-trip per (instrument, date) — same cost
  `PositionsHistoryBuilder` already pays for the per-account chart.

For a typical user (≤5 trades-mode accounts × ≤10 instruments ×
~365 days = ~18 000 conversion calls per request) this is well
within the cached-rate budget. Sequential `await` in the day loop
matches `applyInvestmentValues` and `PositionsHistoryBuilder`;
switching to a `TaskGroup` is a self-contained change if profiling
later shows it's user-visible.

The new SQL fetch (`fetchTradesModeInvestmentAccountIds`) adds one
small-table read inside the existing `database.read` snapshot; cost
is the same shape as `fetchInvestmentAccountIds` (resolves through
`account_by_type`).

### 13. File-size budget

Current sizes:

- `+DailyBalancesInvestmentValues.swift` — 195 lines.
- `+DailyBalancesAggregation.swift` — ~330 lines.
- `+DailyBalances.swift` — ~360 lines.

The new fold (~50 lines including doc comments) plus the new helper
(~20 lines) plus the new fetch (~15 lines) lands on
`+DailyBalancesInvestmentValues.swift`, taking it to ~280 lines —
well under the SwiftLint `file_length` warn threshold (400). The
aggregation-layer wiring (one extra SQL fetch call site, two extra
struct fields, one filter pass) lands on `+DailyBalancesAggregation.swift`
and `+DailyBalances.swift`; both stay under threshold. The
implementer should run `just format-check` after each commit to
confirm.

## Out-of-Scope Followups

- Extending the trades-mode contribution onto the *forecast tail* via
  `Date()` valuation — would mirror Rule 7's service-level clamp and
  could be added without further design.
- A persisted "valued positions over time" series (e.g. for offline
  rendering or sync). The current design recomputes from scratch on
  every request; persistence would only be worthwhile if profiling
  shows the recompute is the bottleneck.
- Parallelising the per-day conversion fan-out via `TaskGroup`.
- A user-facing "this day's contribution couldn't be computed" /
  "retry" affordance on the chart UI itself (today the chart silently
  gaps days dropped by the pipeline; an on-screen retry-now indicator
  is a separate UI concern).

## Migration & Rollout

Single PR. The change is additive (one new SQL fetch, one new fold,
two new aggregation fields) plus one tightening (snapshot fold's
per-day failure now drops the day, matching walkDays). Behind no
flag.

The snapshot-fold tightening is a small behavioural change: a
recorded-value snapshot whose conversion fails on a given day will
now cause that day to gap in the chart instead of rendering with a
stale partial total. This matches `walkDays`'s pre-existing
per-day-failure contract, brings the daily-balance pipeline into
Rule 11 compliance, and is the right behaviour given the chart's
"missing day = visible gap" semantics. No tests rely on the old
behaviour (`MoolahTests/Backends/GRDB/GRDBDailyBalancesAssembleTests`
asserts `handleInvestmentValueFailure` is invoked but doesn't
assert the day is retained); the new tests in §9.3 case 5 pin the
new behaviour.

Trades-mode accounts gain accurate historical chart contribution
immediately — there is no observable regression for any existing
user because the *only* behaviour change for trades-mode is "now
contribute their position-valuation series to the historical chart
on days they previously contributed zero (or only a transfer leg)."

Rollout matches recent analysis-fold PRs:

1. Open the PR against `main`.
2. Run `code-review`, `database-code-review`,
   `instrument-conversion-review`, `concurrency-review` agents per
   project policy.
3. Add to the merge queue via the `merge-queue` skill.

No CloudKit schema change. No GRDB migration. No new sync surface.
