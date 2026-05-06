# Reactive Sync Refresh — Design

**Date:** 2026-05-06
**Status:** Draft
**Author:** Adrian Sutton (with Claude)

## Problem

Domain-data views in the app — sidebar accounts/earmarks/balances/totals, and by extension every screen that reads from a `*Store` — do not reactively reflect remote sync. When CKSyncEngine pulls a change written on another device, the change lands in the local GRDB queue, but the user does not see it in the sidebar (or any other view) until they pull-to-refresh, switch profiles, or relaunch the app.

The wiring exists in code today (`SyncCoordinator → ProfileSession.scheduleReloadFromSync → store.reloadFromSync`) but is brittle: a closed-world `storesToReload(for:)` map decides which stores reload for which record types, an early-return guard inside each store's `reloadFromSync` (`if fresh.ordered != accounts.ordered { ... }`) can suppress emissions, and an `addObserver` registration race between session init and CKSyncEngine startup can leave the chain dormant. The exact failure point matters less than the structural fragility: the design has multiple silent-failure modes and grows linearly in surface area for every new feature.

## Decisions log

The design crystallised through the following choices:

| Question | Decision |
|---|---|
| Symptom shape | A — nothing updates from remote sync until manual refresh |
| Scope | B — every domain-data view, by policy |
| Architecture | C — reactive GRDB observation (replace, don't extend, the existing pattern) |
| Granularity | α — every domain repository protocol gains `observe…() -> AsyncStream<[T]>` |
| Mutations | (a) — drop optimistic updates entirely; mutation methods write through, observation emits canonical state |
| Protocol surface | (iii) — hybrid; whole-table observations for small datasets, parameterized observations for windowed/filtered reads |
| Performance | Measure first; ship simplest reactive design; add mitigations only when warranted by signpost data and benchmarks |

## Section 1 — Architecture overview

**Goal.** Every domain-data view in the app reactively reflects the GRDB state. There is no manual refresh path, no central "which stores reload for which record types" map, and no observer-on-CKSyncEngine-events plumbing for store reload.

**Single principle.** *The local GRDB queue is the source of truth for all domain reads. Any code path that wants the user to see a change writes to GRDB and stops.* CKSyncEngine apply, user mutations, importer, sync-engine ingestion, and price/rate refreshes all become "things that write to GRDB". Stores never know which one.

**Data flow.**

```
┌────────────────────────┐    writes    ┌─────────────────────┐
│ CKSyncEngine apply     │─────────────▶│                     │
│ User mutations         │─────────────▶│   GRDB queue        │
│ Price/rate refresh     │─────────────▶│  (data.sqlite)      │
│ Importer               │─────────────▶│                     │
└────────────────────────┘              └──────────┬──────────┘
                                                   │ ValueObservation
                                                   │ (per query)
                                                   ▼
                                        ┌─────────────────────┐
                                        │ Repository.observe… │
                                        │  AsyncStream<[T]>   │
                                        └──────────┬──────────┘
                                                   │ for-await
                                                   ▼
                                        ┌─────────────────────┐
                                        │ @Observable Store   │
                                        │ assigns to @State   │
                                        └──────────┬──────────┘
                                                   │ SwiftUI tracks
                                                   ▼
                                        ┌─────────────────────┐
                                        │ View re-renders     │
                                        └─────────────────────┘
```

**What goes away.**

- `ProfileSession.scheduleReloadFromSync` and `pendingChangedTypes` debounce
- `ProfileSession+SyncWiring.swift` (`StoreReloadPlan`, `storesToReload(for:)`)
- Every store's `reloadFromSync()` and the early-return `fresh.ordered != accounts.ordered` guards
- Every store's optimistic-update + rollback bookkeeping in `create` / `update` / `delete`
- `SyncCoordinator.addObserver(for:)` and the per-profile observer registry (the index observer stays — it's a separate concern)
- `fetchSessionChangedTypes` accumulation and the `notifyObservers` flush in `endFetchingChanges`

**What stays.**

- `SyncProgress` and `SyncProgressFooter` — these observe sync *activity* (uploading/downloading), not data
- `instrumentRemoteChangeCallbacks` — fire-and-forget hook into a non-store consumer; can stay or be migrated separately
- `iCloudAvailability` and the account-status probe — independent of data flow
- CKSyncEngine itself, schema, zone routing, retry/backoff — entirely untouched
- Repository pull methods (`fetchAll`, `fetch(for:)`, etc.) — kept for one-shot reads (validation in mutation methods, ad-hoc tests)

**Scope of "the GRDB write is the only signal".** The principle applies *only* to domain-data stores (account rows, transactions, earmarks, etc.). Sync-status state — `iCloudAvailability`, `SyncProgress`, profile-index zone state — is observed directly on `SyncCoordinator` (which is itself `@Observable @MainActor`) and does not flow through GRDB. Future readers should not add a GRDB table for any of these signals. The decoupling is asymmetric: row data goes through GRDB; lifecycle/availability state does not.

**What this fixes for symptom A.** The current bug — "nothing updates until pull-to-refresh" — disappears by construction. There is no "trigger refresh" code path that could fail to fire; the trigger *is* the GRDB write that the sync apply already performs. Every observed read sees the new state on the next emission.

## Section 2 — Performance discipline

**Default position.** Ship the simplest reactive design first: each repository exposes `observeAll() -> AsyncStream<[T]>`, GRDB `ValueObservation` re-runs on each commit, store assigns the result. No pre-emptive throttling, debouncing, transaction coalescing, or scope-narrowing. We do not predict where the cost will land; we measure it.

**Why simple first.** Today's debounce (500 ms / 2000 ms) was added in response to a specific incident, not from a model. The reactive design has fundamentally different cost characteristics — re-fetch is off-main, GRDB's region tracking is precise, `removeDuplicates` is a one-line addition — so today's mitigations may not be the ones we need. Adding them up front locks in complexity we may never have needed; adding them later, against measurements, lands them where they actually pay off.

**Measurement is a deliverable that ships before the reactive cutover.** Before any store is migrated:

1. **Signpost instrumentation lands first** at the four points that bound the cost: GRDB commit, observation re-fetch start, observation re-fetch end, store assignment. Per `guides/BENCHMARKING_GUIDE.md`. Reusable shape so every store gets the same trace.
2. **Bulk-sync benchmark lands first** in `MoolahBenchmarks`: simulate a 50k-transaction initial sync into an empty profile, measure observation emissions, re-fetch CPU, and main-thread time. Captures a baseline for the *current* (debounced) pattern, then for the *new* (reactive) pattern after each store migrates.
3. **Acceptance criteria** below — these are the thresholds that, if breached after measurement, justify reaching into the toolbox.

| Scenario | Target |
|---|---|
| 50k-tx initial sync, sidebar visible | Main-thread time < 50 ms cumulative |
| Single remote tx edit, sidebar visible | Store update < 250 ms from sync apply |
| Local mutation | Emission delivered in < 50 ms |
| Steady-state idle (no writes) | 0% CPU (no polling) |

**Mitigation toolbox — used only if a measurement breaches a threshold.** Listed roughly cheapest-to-deepest:

- `.removeDuplicates()` on the observation (free if rows are `Equatable`)
- Tighten the observation projection / region (cheap; per-store work)
- AsyncSequence `.throttle(for:)` on the consumer side (cheap)
- Coalesce CKSyncEngine apply commits — **per delivery batch, not per fetch session**. Today the apply path already commits per delivery batch (`writer.write { }` once per `applyRemoteChanges` call), which is the safe granularity. Wrapping the entire `willFetchChanges … endFetchingChanges` window in a single outer `writer.write` would hold the serial writer queue for the full duration of a 50k-row sync, blocking every user mutation and price-cache write for that period — which is unsafe per `DATABASE_CODE_GUIDE.md` §8. If a benchmark says per-batch granularity is too fine-grained, the next hop is *grouping a small number of consecutive batches* (e.g. 500 records per transaction), not one transaction per session. Adopting this also means the "Bulk-sync test: sidebar populates progressively" acceptance criterion above must be relaxed to "sidebar populates in chunks" — one transaction per N batches gives one emission per chunk.
- Promote `observeRates()` from `AsyncStream<Void>` to `AsyncStream<Set<String>>` (affected base/ticker IDs) so stores can skip ticks for instruments their profile doesn't use (see Section 3 caveat)
- Suspend observation while view is off-screen (per-store; required for `AnalysisRepository` likely, but we'll find out)
- Move expensive aggregations to a longer throttle / on-demand only

Each is added in a separate commit, justified by a benchmark number, and re-measured after.

**Note on `.removeDuplicates()`.** Even though it's listed as a "mitigation", the design enables it by default in section 4 (it's a one-line addition with measured-zero cost when results haven't changed). The "mitigation" framing is for cases where it's NOT enabled — e.g. a `Void`-emitting tick stream where it would suppress every emission.

## Section 3 — Repository protocol changes

Per choice (iii), every reactive consumer's read gets a matching `observe…` sibling with the same parameter shape. Existing pull methods stay — they're still useful inside mutation methods and one-shot validations.

**Whole-table observations** (small datasets, observe everything):

| Repo | Existing pull | New reactive sibling |
|---|---|---|
| `AccountRepository` | `fetchAll() -> [Account]` | `observeAll() -> AsyncStream<[Account]>` |
| `CategoryRepository` | `fetchAll() -> [Category]` | `observeAll() -> AsyncStream<[Category]>` |
| `EarmarkRepository` | `fetchAll() -> [Earmark]` | `observeAll() -> AsyncStream<[Earmark]>` |
| `ImportRuleRepository` | `fetchAll() -> [ImportRule]` | `observeAll() -> AsyncStream<[ImportRule]>` |
| `CSVImportProfileRepository` | `fetchAll() -> [CSVImportProfile]` | `observeAll() -> AsyncStream<[CSVImportProfile]>` |

**Parameterized observations** (windowed / filtered):

| Repo | Existing pull | New reactive sibling |
|---|---|---|
| `TransactionRepository` | `fetch(filter:page:pageSize:) -> TransactionPage` | `observe(filter:page:pageSize:) -> AsyncStream<TransactionPage>` |
| `TransactionRepository` | `fetchAll(filter:) -> [Transaction]` | `observeAll(filter:) -> AsyncStream<[Transaction]>` |
| `EarmarkRepository` | `fetchBudget(earmarkId:) -> [EarmarkBudgetItem]` | `observeBudget(earmarkId:) -> AsyncStream<[EarmarkBudgetItem]>` |

| `InvestmentRepository` | `fetchValues(accountId:page:pageSize:)` | `observeValues(accountId:page:pageSize:) -> AsyncStream<InvestmentValuePage>` |
| `InvestmentRepository` | `fetchDailyBalances(accountId:)` | `observeDailyBalances(accountId:) -> AsyncStream<[AccountDailyBalance]>` |

**Conversion service** — separate from row repos because conversion depends on rate cache tables, not domain rows:

```swift
protocol InstrumentConversionService: Sendable {
  // existing methods unchanged
  func observeRates() -> AsyncStream<Void>  // tick stream
}
```

Stores that compute converted values (e.g. `AccountStore.convertedCurrentTotal`) subscribe to *both* their data observation *and* this tick stream, recomputing when either fires. The GRDB implementation wraps a `ValueObservation` over **all three** cache table families: `exchange_rate` (FX), `stock_price`, and `crypto_price`. (Today there is no single `rate_cache` table — see Section 4 for the actual implementation.)

**Known limitation of the `Void` shape.** Because the stream emits `Void`, a store cannot tell *which* instrument's rate changed. A profile whose only instrument is `AUD` will recompute its converted total when the cache is updated for an unrelated `EUR/USD` rate. This is acceptable for the initial cut (per Section 2's measure-first policy), but the per-write recompute cost must be exercised in the commit-6 benchmark with a scenario that writes rates for instruments the profile doesn't use. If the cost is measurable, the mitigation listed in Section 2 promotes the stream shape to `AsyncStream<Set<String>>` so stores can filter before recomputing.

**Stays pull-only** (one-shot validations, mutations, suggestions, migrations — no observation needed):

- All `create` / `update` / `delete` / `setBudget` / `setValue` / `removeValue` / `reorder`
- `TransactionRepository.fetchPayeeSuggestions(prefix:)` — autocomplete
- `AccountRepository.backfillValuationModeForUnsnapshotInvestmentAccounts()` — migration

**Deferred to a later spec — `AnalysisRepository`.** All of `fetchDailyBalances`, `fetchExpenseBreakdown`, `fetchIncomeAndExpense`, `fetchCategoryBalances*`, `loadAll(...)` stay pull-only for now. These are expensive joins and we have no measurement to justify observation yet (per section 2). When/if measurement says we want it, the reactive surface here would follow the same `observe…` pattern with on-demand suspension while the analysis view is off-screen.

**Out of scope for this design** (separate concerns, untouched):

- `AuthProvider`, `WalletSyncStateRepository`, `InstrumentRegistryRepository`, `CryptoPriceClient`, `StockPriceClient`, `ExchangeRateClient`, `CoinGeckoCatalog`, `TokenResolutionClient`, `StockSearchClient`, `StockTickerValidator` — not user-displayed domain rows; either internal or have their own callback mechanism (`instrumentRemoteChangeCallbacks` already covers `InstrumentRegistry`).

**Domain-layer purity check.** `AsyncStream<T>` is `Foundation` / Swift std lib (`Sendable`), so adding these methods to Domain protocols does not pull in GRDB or any backend. The protocol surface stays backend-agnostic.

## Section 4 — GRDB implementation

**Prerequisite — `DATABASE_CODE_GUIDE.md` update.** §2 of the guide currently bans `ValueObservation` ("Not adopted at this time. Adopting `ValueObservation` requires a guide update and is not a per-feature decision."). The first commit of this work (Section 8 commit 0) replaces that paragraph with the conventions codified below. No reactive code can land before that guide update is in.

The shape every `observe…` method takes:

```swift
extension GRDBAccountRepository: AccountRepository {
  func observeAll() -> AsyncStream<[Account]> {
    ValueObservation
      .tracking { db in try AccountRow.fetchAll(db).map(Account.init) }
      .removeDuplicates()
      .values(in: database)            // .task scheduler is the default
      .toAsyncStream()
  }
}
```

**Per-method conventions** (enforced by the `database-code-review` agent):

1. **`ValueObservation.tracking { db in ... }`** — region is inferred automatically from the SQL. No manual region declaration.
2. **`.removeDuplicates()` is default.** Every `observe…` method that emits a value type includes it. Domain row types (`Account`, `Earmark`, etc.) already conform to `Equatable`; verify per-type during migration. **Carve-out:** `observeRates()` (which emits `Void`) does **not** apply `.removeDuplicates()` — `Void == Void` would suppress every emission. The exception is documented at the `observeRates()` snippet below.
3. **Re-fetch runs on a GRDB reader queue** (default `ValueObservation` behaviour). The `MainActor` only sees the completed value.
4. **No explicit `scheduling:` argument.** `.values(in:)` defaults to the `.task` scheduler (cooperative thread pool), which is the correct choice for `AsyncSequence` consumption inside a Swift `Task`. The store's `for await` runs in a `@MainActor`-isolated context, so each emission is received on `MainActor` automatically — no need for the GCD-targeted `.async(onQueue: .main)` (that scheduler exists for the Combine and callback APIs, not for `AsyncSequence`, and would cause a redundant double dispatch).
5. **AsyncStream bridge.** GRDB's `.values(in:)` returns an `AsyncValueObservation<T>` that is itself an `AsyncSequence`. We wrap it once in a small extension (`toAsyncStream()`) so every domain protocol returns the same concrete `AsyncStream<T>` type — keeps Domain free of GRDB types and gives stores a uniform iteration surface.
6. **The `toAsyncStream()` bridge MUST wire `continuation.onTermination`** to cancel the underlying `ValueObservation` task. Without this, an `AsyncStream` consumer that cancels its `Task` would not propagate cancellation back to the GRDB layer and the observation would leak. This is a correctness requirement, not a polish.
7. **`AsyncStream` cancellation.** When the consuming `Task` is cancelled, `AsyncStream` ends its iteration and `onTermination` fires (per requirement 6), which tears down the underlying observation. Stores hold the `Task` handle and cancel in `cleanupSync` (matches today's pattern).

**Errors — categorise, with explicit wiring to the store.** `ValueObservation`'s underlying delivery is `AsyncThrowingStream`. The `toAsyncStream()` bridge converts it to a non-throwing `AsyncStream<T>` *only after categorising the error*:

- **Programmer bugs** (`SQLITE_ERROR` from malformed SQL, schema mismatch in debug builds, missing tables) — assert/`fatalError` in debug; in release, surface to the store as `error: Error?` and stop the observation. These should never silently restart; that hides the bug.
- **Transient I/O** (`SQLITE_FULL` disk exhaustion, `SQLITE_IOERR`) — log at `error` level and restart the observation with backoff (1 s, 5 s, 30 s, then capped at 30 s). The store sees a brief gap in emissions.
- **Retry budget exhaustion** — after, say, 5 consecutive transient failures the wrapper stops retrying and surfaces the most recent error to the store via `error: Error?`. The user sees a stale view *and* an error indicator, rather than a silently frozen view. (Fewer than 5 might be wrong; the exact budget is a tuning parameter to be set against measurement.)

**Bridge signature wires the error path.** `toAsyncStream()` takes an explicit error callback so the bridge can hand surfaced errors to the store:

```swift
extension AsyncValueObservation {
  func toAsyncStream(
    onError: @MainActor @Sendable @escaping (any Error) -> Void
  ) -> AsyncStream<Element> { … }
}
```

Repository methods pass a closure that captures their store callback site indirectly — but because repositories don't know about stores, the cleanest shape is to expose two surfaces on the repository:

```swift
protocol AccountRepository: Sendable {
  func observeAll() -> AsyncStream<[Account]>            // value emissions
  func observeErrors() -> AsyncStream<any Error>          // surfaced errors
  // … existing methods unchanged
}
```

(Parallel verb-form naming with `observeAll()`; both methods read as imperative starts of an observation channel.)

The store subscribes to both inside `observe()`'s `TaskGroup`:

```swift
group.addTask {
  for await error in self.repository.observeErrors() {
    self.error = error      // @MainActor-isolated; safe
  }
}
```

The repository implementation backs both streams with a single shared continuation pair so `toAsyncStream`'s `onError` callback feeds the error stream while values flow normally. **Stream completion contract:** after the bridge surfaces an error to the store (programmer bug or retry-budget exhaustion), the bridge completes both `observeAll()` and `observeErrors()` streams (i.e. yields `nil` from `next()`). The `for await` loops in the store's `TaskGroup` exit naturally; the `TaskGroup` returns; the observation `Task` completes. Without this completion semantics, the `observeErrors()` child task would block indefinitely on a stream that no longer emits, retaining the store and preventing clean teardown. Tests assert all three invariants: a programmer-bug error appears on `observeErrors()`; a transient error does not appear (it gets retried); after retry-budget exhaustion, both streams complete. If a future repository forgets to expose `observeErrors()`, the protocol method requirement makes it a compile error — no silent suppression.

**`InstrumentConversionService` exposes the same error surface.** The conversion service's `observeRates()` is also backed by a `ValueObservation` and can fail with the same categories of error. Without a parallel `observeErrors()` on the conversion service, a rate-cache observation failure that exhausts the retry budget would silently freeze converted totals — `INSTRUMENT_CONVERSION_GUIDE.md` Rule 11 ("a failed conversion must surface a retryable error to the user") would be violated by absence of the surfacing path. The protocol therefore gains a matching method:

```swift
protocol InstrumentConversionService: Sendable {
  func observeRates() -> AsyncStream<Void>
  func observeErrors() -> AsyncStream<any Error>
  // existing methods unchanged
}
```

Stores that subscribe to `observeRates()` also subscribe to `observeErrors()` and route the error to `self.error` (the same property used for repository errors — no need for a separate channel).

**Logging contract.** Every error log written by the bridge MUST include: the repository name (`AccountRepository`), the method name (`observeAll`), and the underlying error. Format:

```
GRDB observation error in AccountRepository.observeAll: SQLITE_IOERR (errno 5)
```

This is auditable in code review and consistent across all repositories. No `print()`, no bare `logger.error("\(error)")`.

**Parameterized observations** look identical, with the parameter captured into the `tracking` closure:

```swift
func observeAll(filter: TransactionFilter) -> AsyncStream<[Transaction]> {
  ValueObservation
    .tracking { [filter] db in try fetchTransactions(filter: filter, in: db) }
    .removeDuplicates()
    .values(in: database)
    .toAsyncStream()
}
```

When the consumer changes the filter (e.g. user navigates from one account to another), it cancels the prior `Task` and starts a new `for await` on the new parameterized stream. No store-level diffing logic needed.

**`InstrumentConversionService.observeRates()`** wraps a `ValueObservation` whose region covers all three live price cache tables: `exchange_rate` (FX), `stock_price`, and `crypto_price`. It emits `Void` (no data, just a tick) so the store knows to recompute its converted totals. Use a `.tracking { db in … }` closure with one trivial read per table so GRDB's region inference picks up the union of all three:

```swift
func observeRates() -> AsyncStream<Void> {
  ValueObservation
    .tracking { db in
      // Region inference: each read registers the table as part of
      // the observed region. The fetched values themselves are
      // discarded; only the region matters.
      _ = try Int.fetchOne(db, sql: "SELECT 1 FROM exchange_rate LIMIT 1")
      _ = try Int.fetchOne(db, sql: "SELECT 1 FROM stock_price LIMIT 1")
      _ = try Int.fetchOne(db, sql: "SELECT 1 FROM crypto_price LIMIT 1")
      return ()
    }
    .values(in: database)
    .toAsyncStream(onError: …)   // see Errors above
}
```

Three notes:

- Verify the table names against `ProfileSchema+RateCaches.swift` during implementation; the schema is the source of truth.
- Do **not** apply `removeDuplicates` to this stream — `Void == Void` would suppress every emission. (Convention 2 above carves this out explicitly.)
- An earlier draft used a single `SELECT 1 FROM rate_cache LIMIT 1` read. There is no `rate_cache` table; that draft was wrong. The three-read inference closure above is the spec-mandated form. The alternative `tracking(region:fetch:)` API exists in GRDB but its variadic vs single-region argument labels are version-specific; the inference closure form is portable across GRDB minor versions and is what implementations must use.

**Test backend.** The test backend uses an in-memory `DatabaseQueue`. `ValueObservation` works identically against in-memory queues — same code path, no test seam needed. Tests can drive observation by performing a write through the same backend (`testBackend.accounts.create(...)`) and awaiting the next emission. See section 7 for the test pattern.

**Where this implementation lives.** Each `GRDB*Repository.swift` file gets the new `observe…` methods alongside its existing pull methods. The `toAsyncStream()` and any shared helpers live in a new `Backends/GRDB/Observation/` directory (one file: `ValueObservation+AsyncStream.swift`). Conversion service observation lives in the existing `GRDBInstrumentConversionService.swift` (or wherever the existing impl is — confirm during implementation).

## Section 5 — Store rewiring

The store collapses from "two sources of truth (local array + DB)" to one. Mutation methods become pass-throughs; the observation loop owns all state assignment.

**Canonical pattern** (`AccountStore` as the example, since it has both data observation and rate-tick observation):

```swift
@Observable
@MainActor
final class AccountStore {
  private(set) var accounts = Accounts(from: [])
  private(set) var error: Error?
  private(set) var convertedCurrentTotal: InstrumentAmount?
  private(set) var convertedInvestmentTotal: InstrumentAmount?
  private(set) var convertedNetWorth: InstrumentAmount?
  private(set) var convertedBalances: [UUID: InstrumentAmount] = [:]

  private let repository: AccountRepository
  private let conversionService: any InstrumentConversionService
  private let targetInstrument: Instrument
  private let investmentValueCache: InvestmentValueCache
  private var observationTask: Task<Void, Never>?

  init(...) {
    // assignments unchanged
    // Strong self capture: the store is @MainActor, the task already
    // holds an implicit strong reference, and `stopObserving()` (called
    // from `cleanupSync`) is the sole lifetime gate. A weak capture
    // here would just add a nil-check hazard without preventing the
    // retain — and the `guard let self else { return }` pattern would
    // mask cancellation-propagation bugs by silently exiting.
    observationTask = Task { await self.observe() }
  }

  deinit {
    // Safety net for the case where `cleanupSync` is missed (e.g. an
    // early-error tear-down path that drops the ProfileSession without
    // calling cleanupSync). Cancels the strongly-held observation Task
    // so it does not retain `self` and a stale GRDB connection forever.
    // Under normal lifecycle, `stopObserving()` runs first via
    // `cleanupSync` and this is a no-op. `Task.cancel()` is safe to
    // call from a non-isolated `deinit`.
    observationTask?.cancel()
    conversionTask?.cancel()
  }

  private func observe() async {
    await withTaskGroup(of: Void.self) { group in
      group.addTask {
        for await fresh in self.repository.observeAll() {
          await self.apply(accounts: fresh)
        }
      }
      group.addTask {
        for await _ in self.conversionService.observeRates() {
          await self.recomputeConvertedTotals()
        }
      }
      // Cancellation of `observationTask` cancels the group; the
      // `for await` loops exit; the group returns naturally.
    }
  }

  private func apply(accounts fresh: [Account]) async {
    self.accounts = Accounts(from: fresh)
    await preloadInvestmentValues()
    await recomputeConvertedTotals()
  }

  func stopObserving() {
    observationTask?.cancel()
    observationTask = nil
  }

  // Mutations: pass-through. No optimistic insert, no rollback, no manual state.
  func create(_ account: Account, openingBalance: InstrumentAmount? = nil) async throws -> Account {
    error = nil
    do {
      var toCreate = account
      if toCreate.type == .investment && toCreate.valuationMode == .recordedValue {
        toCreate.valuationMode = .calculatedFromTrades
      }
      return try await repository.create(toCreate, openingBalance: openingBalance)
    } catch {
      self.error = error
      throw error
    }
  }

  // delete, update: same shape — call through, surface error, return.
}
```

**What disappears from every store:**

- `func load() async` — observation runs from `init`, no manual load
- `func reloadFromSync() async` — same path as load; not needed
- `var isLoading: Bool` — no separate loading state; the empty initial state IS the loading state, with the first emission being "loaded". (If a view actually needs to distinguish "still loading" from "loaded but empty", keep a `hasLoadedAtLeastOnce: Bool` flag flipped to true on first emission. Add only where needed.)
- Optimistic-update arrays (`accounts = Accounts(from: accounts.ordered + [created])`)
- Rollback paths in `catch` blocks (`accounts = previousAccounts`)
- `pendingChangedTypes`, `syncReloadTask`, `lastSyncEventTime`, debounce logic in `ProfileSession`

**What stays:**

- `error: Error?` published property — mutations still throw and the store still surfaces errors to the view
- `showHidden: Bool` and other view-driven preferences (computed properties filtering `accounts`)
- `recomputeConvertedTotals()` — the derived-state computation. Now driven by emissions from either source instead of by mutation methods.
- `conversionTask` retry loop for transient conversion failures — semantics adjusted (see "Retry-loop interaction" below)

**Retry-loop interaction with observation-driven recompute.** Today `recomputeConvertedTotals()` unconditionally cancels and nils `conversionTask` at the top, then spawns a new retry loop only if the pass failed. Under the reactive design, `recomputeConvertedTotals()` runs on every emission from either stream (`observeAll()` *or* `observeRates()`), so unrelated rate writes would reset the retry clock — a potentially infinite delay in recovery for a profile with frequent unrelated rate fetches. Required change: cancel the retry loop **only when the recompute succeeds**. If the new pass also fails, leave the existing retry loop running (its remaining wait already partially elapsed, so it fires sooner). If there is no existing retry loop and the new pass fails, spawn one. This preserves the "eventual recovery" guarantee while eliminating the clock-reset regression.

```swift
private func recomputeConvertedTotals() async {
  let snapshot = await computeBalanceSnapshot()
  publishSnapshot(snapshot)
  if !snapshot.anyFailed {
    // Success — kill any in-flight retry; nothing left to retry.
    conversionTask?.cancel()
    conversionTask = nil
    return
  }
  // Failure — start a retry only if one isn't already running.
  guard conversionTask == nil else { return }
  let delay = retryDelay
  // Strong self + explicit @MainActor for the same reasons as the
  // `observationTask` above. `@MainActor` annotation is required: the
  // closure mutates `self.conversionTask` and calls
  // `publishSnapshot` (both MainActor-isolated). Without it, the Task
  // body would inherit the surrounding context's isolation, which is
  // already MainActor here — but explicit is safer because future
  // refactors that move `recomputeConvertedTotals` off MainActor
  // would silently introduce a race. `deinit` is the safety net for
  // `conversionTask` if the store is dropped while a retry is queued.
  conversionTask = Task { @MainActor in
    while !Task.isCancelled {
      try? await Task.sleep(for: delay)
      guard !Task.isCancelled else { return }
      let retry = await self.computeBalanceSnapshot()
      self.publishSnapshot(retry)
      if !retry.anyFailed {
        self.conversionTask = nil
        return
      }
    }
  }
}
```

**Lifecycle.** `observationTask` is cancelled in `cleanupSync`:

```swift
func cleanupSync(coordinator: SyncCoordinator) {
  // ... existing cleanup ...
  accountStore.stopObserving()
  earmarkStore.stopObserving()
  // ... per migrated store ...
}
```

Each store exposes a `stopObserving()` (named in the plural sense — a store may own multiple observation `Task`s; the method tears down all of them) that cancels the observation `Task` and nils its handle. The `for await` loops exit, the `TaskGroup` completes, the observation `Task` returns. No cascading cleanup needed because `toAsyncStream()`'s `continuation.onTermination` (Section 4 requirement 6) propagates cancellation back to the underlying `ValueObservation`.

**Sign-out teardown ordering.** When `handleAccountChange(.signOut)` runs, it calls `deleteLocalData()` which issues `DELETE FROM …` statements against every per-profile table. The reactive design requires these to happen *before* the per-store `stopObserving()` calls so the observation can emit the empty-state transition to subscribed views. Ordering:

1. `handleAccountChange(.signOut)` runs `deleteAllLocalData()`. GRDB commits the wipes.
2. `ValueObservation` re-fetches and emits empty arrays. Stores assign empty state. Views render the signed-out empty state in real time.
3. `cleanupSync(coordinator:)` runs (typically driven by the parent session manager observing the same sign-out signal). Each store's `stopObserving()` cancels its observation `Task`.

If the order were reversed (stop observation first, then wipe), the user would see the last-known-populated state frozen on screen until they switch profiles or relaunch.

**Sign-in re-subscription ordering.** When `.signIn` arrives:

1. The new `ProfileSession` is constructed; each store's `init` spawns its `observationTask` immediately.
2. The first emission from `observeAll()` is the initial DB snapshot (typically empty for a fresh sign-in). Stores publish the empty state.
3. `queueAllExistingRecordsForAllZones()` runs. CKSyncEngine fetches and writes to GRDB.
4. `ValueObservation` re-fetches and emits the populated state. Stores publish; views render.

**Why the ordering self-enforces.** `ValueObservation` always emits the current DB state on subscription, regardless of whether subsequent writes have already occurred. If `observationTask` is somehow started after CKSyncEngine has already committed its first write, the first emission still contains the post-write state — there is no observable race where a write is missed because the observation wasn't ready. The ordering is therefore a tidiness invariant, not a correctness invariant. Verification during the manual sign-in test confirms the observability property; a unit test that seeds the GRDB queue, then constructs the store, then awaits the first emission, asserts the seeded data is visible.

**Per-view parameterized observation pattern.** Views that own a parameter (e.g. `AccountDetailView` for a specific `accountId`) call a single store method from `.task(id:)`. **The `for await` loop lives in the store, not the view** (per the thin-view rule):

```swift
struct AccountDetailView: View {
  let accountId: UUID
  @Environment(TransactionStore.self) private var transactionStore

  var body: some View {
    List(transactionStore.transactions(for: accountId)) { ... }
      .task(id: accountId) {
        await transactionStore.subscribe(for: accountId)
      }
  }
}
```

The store's `subscribe(for accountId:)` owns the `for await` loop:

```swift
@MainActor func subscribe(for accountId: UUID) async {
  for await page in repository.observe(filter: .account(accountId), ...) {
    transactionsByAccount[accountId] = page
  }
}
```

The view contributes one method call; the store contributes the loop, the state assignment, and any per-account bookkeeping. When the view's `.task(id: accountId)` is cancelled (because the user navigated away or selected a different account), the `for await` exits cleanly via `toAsyncStream()`'s termination handler.

Bare `for await` loops in view bodies are explicitly disallowed — they push business logic into the view and bypass the testability discipline. Code review will reject them.

**Concurrent subscriptions for the same id.** If two views (e.g. a split view) subscribe for the same `accountId` simultaneously, each gets its own `for await` loop. Both loops write the same canonical data to the same store property — wasteful but correct (last-write-wins on identical values is a no-op). Per Section 2's measure-first policy, this is not a concern unless profiling shows the duplicate work is meaningful; the mitigation (refcounted shared subscription per id) is added then, not pre-emptively.

**Mutation surface ergonomics.** A few mutation methods today return the created/updated entity and have callers that depend on that return value (e.g. for navigating to the new row). That contract is preserved — `repo.create` returns the canonical row from the DB; the observation will deliver the same row in its next emission, but the synchronous return value is still useful for "navigate to this id". No call sites change.

**What the views see.** Views are unchanged. They already bind to `@Observable` store properties via `@Environment`. The reactive design just makes those properties update from a different source. Zero view-side migration needed. (View-side updates only happen if a view today calls `store.load()` explicitly; those calls become no-ops or get deleted.)

## Section 6 — Sync coordinator cleanup

The reactive cutover removes one entire concept from `SyncCoordinator`: per-profile change-type observers for store reload. Other concerns (sync activity progress, iCloud account state, instrument-registry remote-change callback) are independent and stay.

**Removed from `SyncCoordinator` and its extensions:**

| Symbol | File | Reason |
|---|---|---|
| `ProfileObserver` struct, `profileObservers: [UUID: [ProfileObserver]]` | `SyncCoordinator.swift` | Per-profile change-type observer registry, no remaining consumers |
| `addObserver(for:callback:)`, `removeObserver(token:)` | `SyncCoordinator.swift` | Public API for the registry above |
| `ObserverToken` struct | `SyncCoordinator.swift` | Token type for the registry above |
| `notifyObservers(for:changedTypes:)` | `SyncCoordinator.swift` | Fires the callbacks |
| `accumulateFetchSessionChanges(for:changedTypes:)` | `SyncCoordinator.swift` | Per-fetch-session accumulation buffer |
| `fetchSessionChangedTypes: [UUID: Set<String>]` | `SyncCoordinator.swift` | Buffer state |
| `flushFetchSessionChanges()` | `SyncCoordinator+Lifecycle.swift` | End-of-fetch flush of the above |
| The `if isFetchingChanges { accumulate } else { notify }` branches | `SyncCoordinator+RecordChanges.swift`, `+Zones.swift` | All four call sites |

**Removed from `ProfileSession` / `ProfileSession+SyncWiring.swift`:**

| Symbol | Reason |
|---|---|
| `syncObserverToken`, `registerWithSyncCoordinator(_:)`, the `addObserver` call in `finishInit` | No more observer to register |
| `scheduleReloadFromSync(changedTypes:)`, `pendingChangedTypes`, `lastSyncEventTime`, `syncReloadTask` | No more change-type → store reload mapping |
| The whole `ProfileSession+SyncWiring.swift` file (`StoreReloadPlan`, `storesToReload(for:)`) | Closed-world map is what we deleted |
| `cleanupSync(coordinator:)` clauses for the two removed task handles and the observer token | Cleaned up by their absence |

**Stays in `SyncCoordinator`** (independent concerns, untouched):

- `SyncProgress` and the willFetchChanges / didFetchChanges / sentRecordZoneChanges hooks that drive it — this is sync *activity* (uploading, downloading), not data reload, and `SyncProgressFooter` still consumes it
- `iCloudAvailability`, the `CKAccountStatus` probe, and `handleAccountChange` — independent
- `IndexObserver` / `addIndexObserver` / `notifyIndexObservers` / `fetchSessionIndexChanged` — the profile-index zone serves a separate UX (Welcome screen, profile list); its observation contract is unchanged. (If we want to migrate this to the same reactive pattern later, it's a separate small spec.)
- `instrumentRemoteChangeCallbacks: [UUID: @Sendable () -> Void]` and `removeInstrumentRemoteChangeCallback(profileId:)` — fire-and-forget hook for `InstrumentRegistry`, conceptually separate from row stores; can stay as-is or migrate in a follow-up
- `profileIndexFetchedAtLeastOnce`, `fetchSessionTouchedIndexZone` — Welcome screen state
- All zone routing, retry/backoff, state persistence, push-notification handling, fetch scheduling — unchanged

**Net effect on `SyncCoordinator`.** It loses the role of "broadcaster of which record types changed for which profile" and is back to being purely a CKSyncEngine wrapper that applies remote changes to GRDB. The "what changes" question is answered by GRDB itself, via `ValueObservation`. This is the intended decoupling: the sync layer stops knowing what features care about what data.

**Confirmed bug in the legacy path — must be fixed in the same PR.** The CKSyncEngine apply path currently writes to GRDB *and* notifies observers in the same `MainActor` turn (`SyncCoordinator+RecordChanges.swift:174-184`). The `if isFetchingChanges { accumulate } else { notify }` branch combined with the `flushFetchSessionChanges` end-of-fetch flush has a race: if `endFetchingChanges` runs before all `applyFetchedProfileDataChanges` async tasks complete (possible when zones are processed concurrently and the last zone finishes after the flush), the late-arriving notification fires `notifyObservers` directly (because `isFetchingChanges` is now `false`) — but the `fetchSessionChangedTypes` for that zone was already cleared by the flush. The store never gets notified. **This matches symptom A** and is one of the failure modes the reactive design fixes by construction.

The reactive design eliminates this entire class of bug because the GRDB commit *is* the signal — there is no separate notification flush to race against. Even so, the legacy path persists during the per-store rollout (Section 8) and the bug must not ship without a fix in place. **In Section 8 commit 14 (the cleanup commit), include an explicit pre-step that fixes the race in the legacy path before deleting it.** Either: fix it in the commit immediately preceding 14, or fold the fix into 14 alongside the deletion. No build that contains the legacy notification path may ship without the fix.

**Migration safety.** During the per-store rollout (section 8), the legacy notification path stays intact until the last store has migrated. Within a single PR, the notification → reload chain and the observation chain coexist for any not-yet-migrated store. The two paths are idempotent — both eventually call the same repo-level reads — so a store reloading twice during transition is a no-op other than wasted work. The deletion of the legacy chain happens in the final commit of the PR.

## Section 7 — Test surface

The shift is from *imperative* tests (`await store.load(); assert state`) to *reactive* tests (`perform write; await next emission; assert state`). The test backend already uses an in-memory GRDB queue; `ValueObservation` works against it identically. No new test seam, no mocks.

**New repository contract tests** — every repo with an `observe…` method gets one observation contract test alongside its existing `fetchAll` contract test. Standard shape:

```swift
@Test
func observeAllEmitsOnCreate() async throws {
  let backend = TestBackend.create()
  // `observeAll()` returns the non-throwing AsyncStream<[Account]>
  // produced by toAsyncStream(). next() returns Optional<[Account]>
  // and never throws — errors are caught and routed to the store
  // via the bridge's error-categorisation path (see Section 4).
  var iterator = backend.accounts.observeAll().makeAsyncIterator()

  let initial = await iterator.next()  // empty
  #expect(initial?.isEmpty == true)    // CODE_GUIDE.md §14: prefer isEmpty over == []

  _ = try await backend.accounts.create(Account(name: "A", type: .bank, instrument: .AUD))

  // Safe ordering on DatabaseQueue: the queue is serial, so step (1)
  // — iterator.next() suspends until the initial emission lands —
  // happens-before step (2) — the create write commits. The next()
  // below cannot return the initial-empty value because that was
  // already consumed. If the backend ever migrates to DatabasePool,
  // this test pattern needs revisiting because reads and writes
  // would parallelise.
  let afterCreate = await iterator.next()
  #expect(afterCreate?.count == 1)
}
```

Three observation invariants per repo, one test each:

1. **Initial value emits once** with the current DB state (empty for a fresh test backend).
2. **Mutation through the repo emits a new value** that reflects the change.
3. **`removeDuplicates` works** — a no-op write (e.g. update with identical fields) does *not* re-emit. Catches a regression where someone removes the deduplication.

**Store test rewrites** — every existing `*StoreTests` file moves from `await store.load(); assert` to:

```swift
@Test
func sidebarRefreshesOnRemoteAccountInsert() async throws {
  let backend = TestBackend.create()
  let store = AccountStore(repository: backend.accounts, ...)
  await store.waitForFirstEmission()

  // Simulate a remote sync writing through the same backend
  _ = try await backend.accounts.create(Account(name: "Synced", ...))

  await store.waitForNextEmission(matching: { $0.accounts.count == 1 })
  #expect(store.accounts.first?.name == "Synced")
}
```

Two test helpers ship with this design (in `MoolahTests/Support/`):

- `func waitForFirstEmission(timeout: Duration = .seconds(2)) async throws` — awaits the first observation emission to land in the store. On timeout, throws a `StoreEmissionTimeoutError` whose message names the store type (e.g. `AccountStore`) so the test failure message is actionable. The default 2 s budget is generous for in-memory queues; tests with deliberately long-running setup may pass an explicit `timeout`.
- `func waitForNextEmission(matching: (Self) -> Bool, timeout: Duration = .seconds(2)) async throws` — awaits until the predicate over the store's current state returns true. Used when a test wants to await a specific transition rather than just "the next one". On timeout, throws with a message naming the store type, the failed predicate description (passed by the test as a string), and the store's current state.

Tests do not poll, sleep, or busy-loop; they await a stream. The helpers are wired through a per-store `AsyncStream<Void>` of "I just applied an emission" ticks. **Confining test instrumentation to test-only code:** the tick stream MUST NOT live on the production `@Observable` store class. It lives on a test-target extension (in `MoolahTests/Support/StoreObservation+Test.swift`) that conforms each store to a `TestableStoreObservation` protocol. The protocol implementation is added at the test target only via an `extension AccountStore: TestableStoreObservation { … }` in the test bundle — keeps the production store free of test-only state. The tick continuation is finished in the test extension's teardown so leaks fail tests fast rather than hanging on timeout.

**Replaces today's coverage:**

- `MoolahTests/App/ProfileSessionTests.swift::storesToReload` — entire suite **deleted**. The closed-world map it tests no longer exists.
- Every store test that uses `store.load()` to drive setup — rewrites to the helper above.
- Every store test that asserts the optimistic mutation pattern (e.g. "after `create`, the store's `accounts` array contains the new item before the repo write completes") — rewrites to await emission. The optimistic contract no longer holds.

**New tests added:**

1. `AccountStoreTests::sidebarRefreshesOnRemoteAccountInsert` — the symptom-A regression test. Asserts the original bug stays fixed: a write into the GRDB backend (simulating CKSyncEngine apply) produces a store update without any explicit refresh call.
2. `AccountStoreTests::convertedTotalRecomputesOnRateTick` — asserts that `conversionService.observeRates()` triggers a recompute even when account positions are unchanged. **This test must use the real `GRDBInstrumentConversionService` against the in-memory `TestBackend` GRDB queue, not `FixedConversionService` or any other test double.** A `FixedConversionService` ignores the rate cache entirely and would make the test vacuous — it would pass even if `observeRates()` was never wired correctly. The test arranges: (a) a starting state that needs conversion through one of the three cache tables; (b) a direct write into that cache table via `TestBackend`; (c) assertion that the store's converted total updated within a bounded wait. Because all three cache table families participate in `observeRates()`, the test should be parameterised across `exchange_rate`, `stock_price`, and `crypto_price` writes — proves the union region is wired correctly.
3. `AccountStoreTests::observationCancelledOnCleanup` — asserts `stopObserving()` causes the observation `Task` to exit (no leaks).
4. `EarmarkStoreTests::sidebarRefreshesOnRemoteEarmarkInsert` — same as (1) for earmarks.

**Performance test added** (per section 2) — `BalanceDeltaBenchmarks` (or new `SyncReactivityBenchmarks`) gets a "50k initial sync into reactive store" benchmark. Establishes baseline before the cutover, measures delta after.

**UI test guidance** — UI tests already drive through `TestBackend` and the existing `XCUITest` harness. With the reactive design, a UI test that creates a transaction in one window's backend and checks it appears in another window's sidebar becomes possible without intermediate refresh. Whether to add such a test is a separate decision (not required for this design); flag for the writing-plans phase to consider.

## Section 8 — Rollout

**Single PR, multiple commits, manual test before merge.** Each commit builds and tests cleanly on its own (CI passes per commit), but the user-visible behavior is only complete at the final commit when the legacy notification chain is removed. Reviewable as a unit; revertible at the PR level only.

**Commit sequence:**

0. **Update `DATABASE_CODE_GUIDE.md` §2.** `ValueObservation` is currently banned by §2 ("Not adopted at this time. Adopting `ValueObservation` requires a guide update and is not a per-feature decision."). This commit replaces that paragraph with the conventions codified in Section 4 of this design (`.tracking { }` form, `.removeDuplicates()` default, `.values(in:)` with the `.task` scheduler default, the `toAsyncStream()` bridge with `continuation.onTermination`, the error-categorisation rules, the logging contract). No code change. Without this commit landed, every subsequent commit would fail the `database-code-review` agent. **Must be the first commit.**

1. **Add `toAsyncStream` helper + signposts.** Lands `Backends/GRDB/Observation/ValueObservation+AsyncStream.swift` (with the `continuation.onTermination` wiring per Section 4 requirement 6 and the error categorisation per Section 4 "Errors") and the `os_signpost` instrumentation pattern (per Section 2). No behaviour change. Test: helper unit test that exercises both the value-emission and cancellation paths.

2. **Add reactive baseline benchmark.** Adds `MoolahBenchmarks/SyncReactivityBenchmarks.swift` with the 50k initial-sync scenario, run against the *current* (debounced) implementation. Captures baseline numbers in the PR description. No behaviour change.

3. **`AccountRepository.observeAll` + GRDB impl + contract test.** Repository protocol gains the method, GRDB implements it, contract test covers the three observation invariants. `AccountStore` is **not** migrated yet — the new method has no caller. No behaviour change to live code paths.

4. **`InstrumentConversionService.observeRates` + GRDB impl + contract test.** Same shape as (3). Used by `AccountStore` and `EarmarkStore` once they migrate. The implementation MUST track all three cache tables (`exchange_rate`, `stock_price`, `crypto_price`) per Section 4. **The contract test MUST be parameterised — one sub-test per cache table family.** A single test that writes into all three tables in sequence and awaits one emission would satisfy "exercises a write into each" but would silently false-pass if the union region accidentally only registered one of the three. Per-family sub-tests isolate a missing region registration to the specific family that's broken.

5. **Migrate `AccountStore` to the reactive pattern.** Deletes `load()` / `reloadFromSync()` / optimistic-update bookkeeping; adds `observe()` task and `stopObserving()` in init/cleanup; mutations become pass-through; updates `recomputeConvertedTotals()` to the conditional-cancel retry pattern from Section 5. Adds `AccountStoreTests::sidebarRefreshesOnRemoteAccountInsert` (the symptom-A regression test), the parameterised rate-tick test (one assertion per cache table family), and the `observationCancelledOnCleanup` test. Updates existing `AccountStoreTests` to the emission-awaiting pattern. **Sidebar's account totals now auto-refresh on sync** — the user-visible bug is fixed at this commit. Removes the `.accounts` entry from `ProfileSession.storesToReload(for:)` so the legacy path stops calling the now-removed `accountStore.reloadFromSync()`. Verifies the sign-out / sign-in teardown ordering described in Section 5 ("Sign-out teardown ordering") via either a unit test or a manual log inspection during `cleanupSync`.

6. **Add reactive measurement against migrated `AccountStore`.** Re-run the `SyncReactivityBenchmarks` suite, capture numbers, attach to PR description. **Decision point:** if any threshold from section 2 is breached, pause and pull in the relevant mitigation from the toolbox (a separate commit before continuing) before migrating more stores. If thresholds are met, continue.

7. **Repeat the (3, 4, 5) shape for `EarmarkRepository` / `EarmarkStore`.** Same structure: protocol method, GRDB impl, contract test, store migration, regression test, remove from `storesToReload`.

8. **Repeat for `CategoryRepository` / `CategoryStore`.**

9. **Repeat for `ImportRuleRepository` / `ImportRuleStore`.**

10. **Add `TransactionRepository.observeAll(filter:)` + `observe(filter:page:pageSize:)` + GRDB impls + contract tests.** Parameterized observation; bigger surface, more careful contract testing.

11. **Migrate `TransactionStore` and the views that own transaction observations** (account detail, all-transactions, recently-added). Biggest single commit because it touches both the store and the parameterized-observation view pattern. Adds the symptom-A regression test for transactions.

12. **Migrate `InvestmentStore` + add `InvestmentRepository.observeValues` / `observeDailyBalances`.** Smaller surface; the tricky part is the existing `onInvestmentValueChanged` cross-store callback into `AccountStore` — that may itself become unnecessary once both stores are reactive (`AccountStore`'s `accounts.observeAll()` will pick up the position changes that `updateInvestmentValue` was pushing).

13. **Migrate `ImportStore` and `CSVImportProfileRepository`.** `ImportStore`'s staging state is per-profile-on-disk and not synced — most of it stays as-is. Only the parts that read CloudKit-synced rows get reactive.

14. **Fix the `isFetchingChanges` race AND remove the legacy notification chain — single commit, not two.** Both halves below land in the same commit. Splitting them into two consecutive commits is **not allowed** in this PR: a bisect through this PR could land on the fix-only commit, which still contains the buggy notification path in live code (just with the race closed) — the same hazard that motivated the requirement in the first place. Reviewability is preserved by clear commit-message structure, not by commit splitting.
    - **Fix:** the race in `applyFetchedProfileDataChanges` / `flushFetchSessionChanges` documented in Section 6 ("Confirmed bug in the legacy path"). Change the late-notification path to re-add types into `fetchSessionChangedTypes` instead of bypassing it, then schedule a follow-up flush. (Holding a lock around the `isFetchingChanges` check is **not** a valid fix: the race is across `await` points within `@MainActor`, and a lock cannot bridge that gap — locks serialise within a single thread, but `await` yields the main actor between the check and the work it gates.)
    - **Delete:** `ProfileSession+SyncWiring.swift`, `scheduleReloadFromSync`, `pendingChangedTypes`, `lastSyncEventTime`, `syncReloadTask`, `syncObserverToken`, `registerWithSyncCoordinator`, the `addObserver(for:callback:)` API on `SyncCoordinator`, `notifyObservers(for:changedTypes:)`, the `accumulateFetchSessionChanges` buffer, and the `flushFetchSessionChanges` end-of-fetch hook. Delete `MoolahTests/App/ProfileSessionTests.swift::storesToReload` suite.

15. **Final measurement.** Re-run `SyncReactivityBenchmarks` with everything migrated. Captures the post-cutover numbers. Verify all section 2 thresholds met; if any are not, the PR doesn't merge until they are.

**Manual test gate before merge.** After commit 15, the user (Adrian) drives the manual test:

- **Two-device test:** edit on Mac A → wait → confirm sidebar updates on Mac B without any user interaction.
- **Bulk-sync test:** install on a fresh device, sign into iCloud with a populated account, confirm the sidebar populates progressively without freezes.
- **Local-mutation test:** create / edit / delete an account, transaction, earmark — confirm UI updates feel snappy (within a frame).
- **Idle test:** leave the app open with no activity for 5 minutes, confirm Activity Monitor shows no CPU draw.

Manual test results go in the PR description; merge only after all four pass.

**`AnalysisRepository`, `WalletSyncStateRepository`, and `InstrumentRegistryRepository` migrations are out of scope** for this PR. They keep their existing pull-only / callback patterns. Each is a separate (small) follow-up spec if/when warranted.

## Risks & open questions

- **`TaskGroup` lifetime in `AccountStore.observe()`.** The Section 5 pattern uses `withTaskGroup` with two child `for await` loops. Cancellation of `observationTask` cancels the group; the loops exit when their underlying `AsyncStream`s terminate (via `toAsyncStream()`'s `continuation.onTermination`, per Section 4 requirement 6). This is the correct shape but needs a quick proof-of-life test before commit 5 lands. Verification: a unit test that creates the store, asserts the observation `Task` is non-nil, calls `stopObserving()`, and asserts the task's value awaits to completion within a bounded timeout.
- **CKSyncEngine apply commit granularity.** The current apply path's commit cadence is unclear from the explore pass. If it commits per-delivery-batch (likely, per `DATABASE_CODE_GUIDE.md` §8), the per-batch granularity is already correct and the Section 2 mitigation is not needed. The benchmark in commit 6 will tell us.
- **`InvestmentValueCache` lifetime.** Today this is a hand-managed cache that `AccountStore` preloads after each reload. With reactive observation, the cache might become unnecessary (replaced by an observation over the investment-values table); decision deferred to commit 12.
- **`hasCompletedInitialConversion` flag.** `AccountStore` today exposes this so views can distinguish "still loading" from "loaded but empty". With reactive observation, the equivalent is "have we received the first emission yet?" — captured by the `waitForFirstEmission` test helper. Confirm during commit 5 that views consuming `hasCompletedInitialConversion` either keep needing it (rename to `hasReceivedFirstEmission`) or can drop it.
- **`Void` tick stream from `observeRates()` causes irrelevant recomputes.** Per Section 3 caveat: every rate-cache write triggers every subscribed store to recompute regardless of whether the change affects this profile's instruments. Acceptable for the initial cut; commit 6's benchmark must include a "rate writes for unused instruments" scenario to decide whether to promote the stream shape to `AsyncStream<Set<String>>`. Risk is bounded — the worst case is wasted CPU on rate-refresh, not a correctness bug.
- **Retry-loop interaction with observation-driven recompute.** Section 5 specifies the conditional-cancel pattern (`recomputeConvertedTotals()` only cancels the retry loop on success, not on every emission). Verify during commit 5 that this preserves "eventual recovery from a transient conversion failure" — i.e. that a failure followed by a real rate update does land the recovery within `retryDelay` of the rate update arrival, not after a multiple of it.

**Closed (not risks):**

- **Push notification delivery.** Verified: iOS `Info-iOS.plist` has `UIBackgroundModes: [remote-notification]`. macOS does not need an equivalent background mode — CloudKit's daemon handles wake-up via APNs without an in-app declaration. No action required.
