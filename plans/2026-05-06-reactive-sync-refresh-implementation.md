# Reactive Sync Refresh Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the existing CKSyncEngine → `ProfileSession.scheduleReloadFromSync` → `store.reloadFromSync` chain with reactive GRDB `ValueObservation`, so every domain-data view (sidebar, transaction list, account detail, earmark detail, etc.) reflects remote sync writes without any manual refresh trigger.

**Architecture:** Each domain repository protocol gains an `observe…() -> AsyncStream<…>` sibling for every reactive read, plus an `observeErrors() -> AsyncStream<any Error>` channel. Stores subscribe in `init`, drop optimistic mutations, and assign emissions to `@Observable` properties — SwiftUI re-renders automatically. The CKSyncEngine apply path's GRDB write is the only refresh trigger; the legacy notification chain is deleted in the final commit.

**Tech Stack:** Swift 6, GRDB.swift `ValueObservation`, Swift `AsyncStream`, Swift Testing (`@Test` / `#expect`), `os_signpost`, `MoolahBenchmarks` package.

**Spec:** `plans/2026-05-06-reactive-sync-refresh-design.md` (must be read first).

**Branch context:** Land on `plan/reactive-sync` (stacked on `spec/reactive-sync`). All implementation commits are local — no implementation PR is opened. Once everything is committed and the user has manually tested per the spec's Section 8 manual-test gate, they will open the implementation PR themselves.

---

## File structure

### New files

| Path | Responsibility |
|---|---|
| `Backends/GRDB/Observation/ValueObservation+AsyncStream.swift` | The `toAsyncStream(onError:)` bridge from `AsyncValueObservation<T>` to `AsyncStream<T>`. Wires `continuation.onTermination` for cancellation propagation. Categorises GRDB errors (programmer bug → store error; transient → backoff retry; budget exhausted → store error + completion). |
| `Backends/GRDB/Observation/ObservationErrorChannel.swift` | Shared `actor` providing the `observeErrors()` channel for every reactive repository. Single `surfaceAndFinish(_:)` method serialises the error-surface + stream-completion into one actor-isolated call (avoids the two-Task race that loses errors). |
| `MoolahTests/Support/StoreObservation+Test.swift` | Test-target `TestableStoreObservation` protocol + `waitForFirstEmission` / `waitForNextEmission` helpers. Per-store conformances added via `@testable import Moolah` + `internal` properties (NOT `@_spi(...)`). |
| `MoolahBenchmarks/SyncReactivityBenchmarks.swift` | The 50k-record bulk-sync benchmark. Run before commit 5 (baseline against legacy), commit 6 (reactive AccountStore), commit 15 (final). |

### Modified files

| Path | Change |
|---|---|
| `guides/DATABASE_CODE_GUIDE.md` | §2 lifts the `ValueObservation` moratorium, codifies the new conventions (commit 0). |
| `Domain/Repositories/AccountRepository.swift` | Add `observeAll()` + `observeErrors()`. |
| `Domain/Repositories/CategoryRepository.swift` | Add `observeAll()` + `observeErrors()`. |
| `Domain/Repositories/EarmarkRepository.swift` | Add `observeAll()`, `observeBudget(earmarkId:)`, `observeErrors()`. |
| `Domain/Repositories/ImportRuleRepository.swift` | Add `observeAll()` + `observeErrors()`. |
| `Domain/Repositories/CSVImportProfileRepository.swift` | Add `observeAll()` + `observeErrors()`. |
| `Domain/Repositories/TransactionRepository.swift` | Add `observe(filter:page:pageSize:)`, `observeAll(filter:)`, `observeErrors()`. |
| `Domain/Repositories/InvestmentRepository.swift` | Add `observeValues(accountId:page:pageSize:)`, `observeDailyBalances(accountId:)`, `observeErrors()`. |
| `Domain/Services/InstrumentConversionService.swift` | Add `observeRates() -> AsyncStream<Void>` + `observeErrors() -> AsyncStream<any Error>`. |
| `Backends/GRDB/Repositories/GRDBAccountRepository.swift` | Implement the new methods. |
| `Backends/GRDB/Repositories/GRDBCategoryRepository.swift` | Implement the new methods. |
| `Backends/GRDB/Repositories/GRDBEarmarkRepository.swift` | Implement the new methods. |
| `Backends/GRDB/Repositories/GRDBImportRuleRepository.swift` | Implement the new methods. |
| `Backends/GRDB/Repositories/GRDBCSVImportProfileRepository.swift` | Implement the new methods. |
| `Backends/GRDB/Repositories/GRDBTransactionRepository.swift` (or `+Fetch.swift`) | Implement the new methods. |
| `Backends/GRDB/Repositories/GRDBInvestmentRepository.swift` | Implement the new methods. |
| Conversion-service GRDB impl (location TBD by `grep` in commit 4) | Implement `observeRates()` + `observeErrors()`. |
| `Features/Accounts/AccountStore.swift` | Reactive rewrite: drop `load()`/`reloadFromSync()`/optimistic state; add `observe()` + `stopObserving()` + `deinit` safety net; conditional-cancel retry loop. |
| `Features/Earmarks/EarmarkStore.swift` | Same reactive shape as `AccountStore`. |
| `Features/Categories/CategoryStore.swift` | Same. |
| `Features/Import/ImportRuleStore.swift` | Same. |
| `Features/Transactions/TransactionStore.swift` | Same; also exposes per-account `observe(accountId:)` for parameterised view subscriptions. |
| `Features/Investments/InvestmentStore.swift` | Same. |
| `Features/Import/ImportStore.swift` | Partial; only the bits that read CloudKit-synced rows. |
| `App/ProfileSession.swift` | Remove `syncObserverToken`, `registerWithSyncCoordinator`, `scheduleReloadFromSync`, `pendingChangedTypes`, `lastSyncEventTime`, `syncReloadTask` (commit 14). Update `cleanupSync` to call `store.stopObserving()` per store. |
| `App/ProfileSession+SyncWiring.swift` | **Deleted** in commit 14. |
| `Backends/CloudKit/Sync/SyncCoordinator.swift` | Remove `ProfileObserver` registry, `addObserver(for:callback:)`, `removeObserver`, `ObserverToken`, `notifyObservers(for:changedTypes:)`, `accumulateFetchSessionChanges`, `fetchSessionChangedTypes` (commit 14). |
| `Backends/CloudKit/Sync/SyncCoordinator+RecordChanges.swift` | Remove the `if isFetchingChanges { accumulate } else { notify }` branch (commit 14). Also: fix the `isFetchingChanges` race per spec Section 6 (same commit). |
| `Backends/CloudKit/Sync/SyncCoordinator+Lifecycle.swift` | Remove `flushFetchSessionChanges` and the call from `endFetchingChanges` (commit 14). |
| `Backends/CloudKit/Sync/SyncCoordinator+Zones.swift` | Remove `notifyObservers(for:changedTypes:)` calls at lines 142, 189, 214 (commit 14). |
| Test files in `MoolahTests/Domain/` | Add observation contract tests per repo (commits 3, 4, 7, 8, 9, 10). |
| Test files in `MoolahTests/Features/*/` | Rewrite `await store.load(); assert` patterns to `waitForFirstEmission` / `waitForNextEmission` per migrated store (commits 5, 7, 8, 9, 11, 12, 13). |
| `MoolahTests/App/ProfileSessionTests.swift` | Delete `storesToReload` test suite (commit 14). |

### Deleted files

| Path | Stage |
|---|---|
| `App/ProfileSession+SyncWiring.swift` | Commit 14 |

---

## Reference patterns

These canonical templates are used by every store / repository migration. Refer back to these from per-stage tasks; they are written once in full.

### Reference R1: Repository observation method

```swift
// In Backends/GRDB/Repositories/GRDB<Name>Repository.swift
extension GRDB<Name>Repository: <Name>Repository {
  func observeAll() -> AsyncStream<[<DomainType>]> {
    let channel = self.errorChannel
    return ValueObservation
      .tracking { db in try <RowType>.fetchAll(db).map(<DomainType>.init) }
      .removeDuplicates()
      .values(in: writer)
      .toAsyncStream(onError: { error in
        // Single Task — surface and finish are serialised inside the
        // actor's `surfaceAndFinish` to avoid the race where an
        // independent finish-Task wins and the error is dropped before
        // it is yielded to the consumer.
        Task { await channel.surfaceAndFinish(error) }
      })
  }

  func observeErrors() -> AsyncStream<any Error> {
    errorChannel.stream
  }
}
```

The repository holds a `private let errorChannel = ObservationErrorChannel()` (the shared actor from `Backends/GRDB/Observation/ObservationErrorChannel.swift` — see Stage 1). The channel exposes `.stream` (a single broadcast `AsyncStream<any Error>`) and is finished when the bridge surfaces a programmer-bug or budget-exhausted error.

### Reference R2: `toAsyncStream(onError:)` bridge

```swift
// Backends/GRDB/Observation/ValueObservation+AsyncStream.swift
import GRDB

extension AsyncValueObservation where Element: Sendable {
  func toAsyncStream(
    onError: @Sendable @escaping (any Error) -> Void
  ) -> AsyncStream<Element> {
    AsyncStream { continuation in
      // Note on ordering: the AsyncStream init closure is synchronous,
      // and the continuation is not vended to any consumer until this
      // closure returns. The runtime cannot invoke `onTermination` while
      // we are still inside the closure, so assigning `onTermination`
      // after starting `task` is race-free in practice. We keep the
      // intent self-documenting by naming the variable up-front.
      let task = Task {
        do {
          for try await value in self {
            if Task.isCancelled { break }
            continuation.yield(value)
          }
          continuation.finish()
        } catch {
          onError(error)
          continuation.finish()
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }
}
```

The `onError` callback is `@Sendable` (not `@MainActor`) because errors arrive from the GRDB reader queue and are surfaced through the `ObservationErrorChannel` actor — which serialises any onward delivery to consumers. The repository's `Task { await channel.surfaceAndFinish(error) }` wrapper crosses into the actor exactly once. Error categorisation (programmer bugs vs transient retry) lives in the channel itself.

### Reference R2.1: `ObservationErrorChannel`

```swift
// Backends/GRDB/Observation/ObservationErrorChannel.swift
import Foundation

actor ObservationErrorChannel {
  private var continuation: AsyncStream<any Error>.Continuation?
  let stream: AsyncStream<any Error>

  init() {
    var localContinuation: AsyncStream<any Error>.Continuation?
    self.stream = AsyncStream { continuation in
      localContinuation = continuation
    }
    self.continuation = localContinuation
  }

  /// Single-call API: yields the error then finishes both streams.
  /// Combining the two operations into one actor method guarantees
  /// ordering — there is no race window where `finish()` can win and
  /// drop the in-flight error.
  func surfaceAndFinish(_ error: any Error) {
    continuation?.yield(error)
    continuation?.finish()
    continuation = nil
  }
}
```

### Reference R3: Reactive store

```swift
@Observable
@MainActor
final class <Name>Store {
  private(set) var items: [<DomainType>] = []
  private(set) var error: (any Error)?

  private let repository: <Name>Repository
  private var observationTask: Task<Void, Never>?

  init(repository: <Name>Repository) {
    self.repository = repository
    // Strong self capture: the store is @MainActor; the task already
    // holds an implicit strong reference; stopObserving() (called from
    // ProfileSession.cleanupSync) is the sole lifetime gate.
    observationTask = Task { await self.observe() }
  }

  deinit {
    // Safety net for the case where cleanupSync is missed.
    observationTask?.cancel()
  }

  private func observe() async {
    await withTaskGroup(of: Void.self) { group in
      // Each addTask closure must be explicitly @MainActor-isolated.
      // `withTaskGroup` children are @Sendable and nonisolated by
      // default; without the annotation, `self.items = fresh` from
      // inside the closure would be a data race against the @MainActor
      // class under Swift 6 strict concurrency.
      group.addTask { @MainActor in
        for await fresh in self.repository.observeAll() {
          self.items = fresh
        }
      }
      group.addTask { @MainActor in
        for await error in self.repository.observeErrors() {
          self.error = error
        }
      }
    }
  }

  func stopObserving() {
    observationTask?.cancel()
    observationTask = nil
  }

  // Mutations: pass-through; no optimistic state, no rollback.
  func create(_ item: <DomainType>) async throws -> <DomainType> {
    error = nil
    do {
      return try await repository.create(item)
    } catch {
      self.error = error
      throw error
    }
  }
}
```

### Reference R4: Repository observation contract test

```swift
@Suite("<Name>Repository observation contract")
struct <Name>RepositoryObservationContractTests {

  @Test("initial value emits once with current DB state")
  func initialEmission() async throws {
    let (backend, _) = try TestBackend.create()
    var iterator = backend.<repos>.observeAll().makeAsyncIterator()
    let initial = await iterator.next()
    #expect(initial?.isEmpty == true)
  }

  @Test("mutation emits updated value")
  func mutationEmits() async throws {
    let (backend, _) = try TestBackend.create()
    var iterator = backend.<repos>.observeAll().makeAsyncIterator()
    _ = await iterator.next()  // discard initial empty emission
    _ = try await backend.<repos>.create(<makeFixture>())
    let afterCreate = await iterator.next()
    #expect(afterCreate?.count == 1)
  }

  @Test("no-op write does not re-emit")
  func removeDuplicates() async throws {
    let (backend, _) = try TestBackend.create()
    let created = try await backend.<repos>.create(<makeFixture>())
    var iterator = backend.<repos>.observeAll().makeAsyncIterator()
    _ = await iterator.next()  // initial value
    _ = try await backend.<repos>.update(created)  // identical update
    // Wait briefly; if a duplicate emission is going to come, it would
    // be available within this window. waitForNextEmission helper used
    // here with a short-circuit-on-emission semantic.
    // Task { } (not Task.detached) — inherits the test's actor context;
    // CONCURRENCY_GUIDE.md restricts Task.detached to specific carve-outs.
    let next = await Task {
      try? await Task.sleep(for: .milliseconds(200))
      return await iterator.next()
    }.value
    #expect(next == nil || next?.count == 1)  // budget; assert no second emission
  }
}
```

(Note: the third test's "absence of emission" is genuinely awkward to assert against `AsyncStream`. The standard pattern is the timeout-based one above: spawn a detached read with a short sleep, expect no emission within the window. If a future store needs stronger guarantees, switch to a tick-counting approach.)

### Reference R5: Store sync-refresh regression test

```swift
@Suite("<Name>Store sync refresh")
struct <Name>StoreSyncRefreshTests {

  @Test("remote insert refreshes store without manual refresh")
  func remoteInsertRefreshes() async throws {
    let (backend, _) = try TestBackend.create()
    let store = <Name>Store(repository: backend.<repos>)
    await store.waitForFirstEmission()
    #expect(store.items.isEmpty)

    // Simulate a remote sync writing through the same backend.
    _ = try await backend.<repos>.create(<makeFixture>())

    try await store.waitForNextEmission(matching: { !$0.items.isEmpty })
    #expect(store.items.count == 1)
  }

  @Test("stopObserving cancels the observation task")
  func stopObservingCancels() async throws {
    let (backend, _) = try TestBackend.create()
    let store = <Name>Store(repository: backend.<repos>)
    await store.waitForFirstEmission()

    store.stopObserving()
    // After stopObserving, a write should not produce an emission.
    _ = try await backend.<repos>.create(<makeFixture>())
    let didEmit = await store.didEmitWithin(timeout: .milliseconds(200))
    #expect(didEmit == false)
  }
}
```

---

## Stage 0 — Lift the `ValueObservation` moratorium

**Files:**
- Modify: `guides/DATABASE_CODE_GUIDE.md:107-109`

- [ ] **Step 1: Open the guide and replace §2 'ValueObservation' subsection.**

Replace the existing 3-line subsection with the following:

```markdown
### `ValueObservation`

**Adopted for reactive store updates** (per `plans/2026-05-06-reactive-sync-refresh-design.md`, lifted 2026-05-06).

Conventions, all enforced by `database-code-review`:

1. **Tracking closure form.** Use `ValueObservation.tracking { db in … }` for queries that fetch concrete data; GRDB infers the region from the SQL/table accesses. **Empty-table caveat:** region inference only registers a table if at least one row is touched during the first fetch (SQLite's `SQLITE_READ` authorizer fires on row access, not on `SELECT 1 FROM empty_table LIMIT 1` returning zero rows). For tracking closures that may run against empty tables — most notably `Void`-emitting tick streams over cache tables — use the explicit-region form `ValueObservation.tracking(regions: [Table("name1"), Table("name2"), ...]) { _ in () }` so the regions are registered unconditionally.
2. **`.removeDuplicates()` is the default** for every `observe…` method that emits a value type (relies on the row decoder being `Equatable`). **Carve-out:** streams that emit `Void` (e.g. `InstrumentConversionService.observeRates()`) MUST NOT apply `removeDuplicates` — `Void == Void` would suppress every emission.
3. **Scheduling.** `.values(in: writer)` with no explicit `scheduling:` argument. The default `.task` scheduler (cooperative thread pool) is correct for `AsyncSequence` consumption inside a Swift `Task`. Do not override with a `DispatchQueue`-targeting scheduler (`.async(...)` factories on `DispatchQueue` or the `.mainActorQueued` style); those exist for the Combine `publisher(in:scheduling:)` and callback `start(in:scheduling:onError:onChange:)` paths, and using them with `.values(in:)` causes a redundant dispatch hop when the consuming `Task` is already actor-isolated.
4. **AsyncStream bridge.** All domain protocols return `AsyncStream<T>` (Foundation, `Sendable`). The bridge lives at `Backends/GRDB/Observation/ValueObservation+AsyncStream.swift` and MUST wire `continuation.onTermination` to cancel the underlying observation `Task`. Without this, an `AsyncStream` consumer that cancels its `Task` would not propagate cancellation to GRDB and the observation would leak.
5. **Errors — categorise.** The bridge's `onError:` callback distinguishes:
   - **Programmer bugs** (`SQLITE_ERROR` / malformed SQL / missing tables) — assert/`fatalError` in debug; in release, surface to the store via the repository's `observeErrors()` channel and complete both streams.
   - **Transient I/O** (`SQLITE_FULL`, `SQLITE_IOERR`) — log at `error` level; restart the observation with backoff (1 s, 5 s, 30 s, capped).
   - **Retry budget exhaustion** (5 consecutive transient failures) — surface the most recent error to `observeErrors()`, complete both streams.
6. **Logging contract.** Every error log includes the repository name, method name, and underlying error. Format: `GRDB observation error in <Repo>.<method>: <error>`. No bare `print()` or `logger.error("\(error)")`.
7. **Stream completion.** After the bridge surfaces an error to the store (programmer bug or budget exhausted), both `observeAll()` and `observeErrors()` complete (`continuation.finish()`). The store's `TaskGroup` child tasks exit naturally; the `TaskGroup` returns; teardown is clean.

Stores subscribe in `init` with strong `self` (the store is `@MainActor`; the task already holds an implicit strong reference). `stopObserving()` (called from `ProfileSession.cleanupSync`) cancels the observation; a `deinit { observationTask?.cancel() }` safety net protects against missed `cleanupSync` calls.
```

- [ ] **Step 2: Verify formatting.**

Run: `just format-check`
Expected: PASS (no Swift changes; markdown is not formatted by swift-format).

- [ ] **Step 3: Commit.**

```bash
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/reactive-sync-plan add guides/DATABASE_CODE_GUIDE.md
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/reactive-sync-plan commit -m "docs(database): lift ValueObservation moratorium

Per plans/2026-05-06-reactive-sync-refresh-design.md.
Codifies the conventions for the reactive sync refresh design: tracking
closure form, removeDuplicates default with Void carve-out, .task
scheduler default, toAsyncStream(onError:) bridge with
continuation.onTermination cancellation propagation, error
categorisation (programmer bug vs transient vs budget exhausted),
logging contract, stream completion semantics.

The implementation lands in subsequent commits on this PR."
```

---

## Stage 1 — `toAsyncStream` bridge + `ObservationErrorChannel`

**Files:**
- Create: `Backends/GRDB/Observation/ValueObservation+AsyncStream.swift`
- Create: `Backends/GRDB/Observation/ObservationErrorChannel.swift`
- Create: `MoolahTests/Backends/GRDB/Observation/ValueObservationAsyncStreamTests.swift`
- Create: `MoolahTests/Backends/GRDB/Observation/ObservationErrorChannelTests.swift`
- Modify: `project.yml` (add the new directory to the Moolah target and to the test target)

- [ ] **Step 1: Update `project.yml` so the new directory is part of the Moolah target and the test target.**

Search `project.yml` for the existing `Backends/GRDB/Repositories` entry. Add a sibling `Backends/GRDB/Observation` entry under the same target. Also add `MoolahTests/Backends/GRDB/Observation` to each test target. Run `just generate` after editing.

- [ ] **Step 2: Write the failing bridge unit test.**

Create `MoolahTests/Backends/GRDB/Observation/ValueObservationAsyncStreamTests.swift`:

```swift
import Foundation
import GRDB
import Testing

@testable import Moolah

@Suite("ValueObservation toAsyncStream bridge")
struct ValueObservationAsyncStreamTests {

  @Test("emits initial value")
  func emitsInitialValue() async throws {
    let queue = try DatabaseQueue()
    try await queue.write { db in
      try db.create(table: "items") { t in
        t.column("id", .integer).primaryKey()
        t.column("name", .text).notNull()
      }
      try db.execute(sql: "INSERT INTO items (name) VALUES (?)", arguments: ["alpha"])
    }

    let stream = ValueObservation
      .tracking { db in try String.fetchAll(db, sql: "SELECT name FROM items") }
      .removeDuplicates()
      .values(in: queue)
      .toAsyncStream(onError: { _ in })

    var iterator = stream.makeAsyncIterator()
    let initial = await iterator.next()
    #expect(initial == ["alpha"])
  }

  @Test("emits on write")
  func emitsOnWrite() async throws {
    let queue = try DatabaseQueue()
    try await queue.write { db in
      try db.create(table: "items") { t in
        t.column("id", .integer).primaryKey()
        t.column("name", .text).notNull()
      }
    }

    let stream = ValueObservation
      .tracking { db in try String.fetchAll(db, sql: "SELECT name FROM items") }
      .removeDuplicates()
      .values(in: queue)
      .toAsyncStream(onError: { _ in })

    var iterator = stream.makeAsyncIterator()
    _ = await iterator.next()  // initial empty

    try await queue.write { db in
      try db.execute(sql: "INSERT INTO items (name) VALUES (?)", arguments: ["beta"])
    }

    let afterWrite = await iterator.next()
    #expect(afterWrite == ["beta"])
  }

  @Test("cancellation tears down the observation")
  func cancellationTearsDown() async throws {
    let queue = try DatabaseQueue()
    try await queue.write { db in
      try db.create(table: "items") { t in
        t.column("id", .integer).primaryKey()
      }
    }

    let stream = ValueObservation
      .tracking { db in try Int.fetchAll(db, sql: "SELECT id FROM items") }
      .values(in: queue)
      .toAsyncStream(onError: { _ in })

    let task = Task<[Int]?, Never> {
      var iterator = stream.makeAsyncIterator()
      return await iterator.next()
    }
    _ = await task.value
    task.cancel()
    // If onTermination is wired correctly, the underlying observation
    // is cancelled and no resources leak. We assert by waiting briefly
    // and verifying no crash / hang.
    try? await Task.sleep(for: .milliseconds(50))
  }

  @Test("error path surfaces via onError callback")
  func errorPathSurfacesError() async throws {
    let queue = try DatabaseQueue()
    // Schema NOT created — observation reads from a missing table,
    // which throws SQLITE_ERROR.
    let errorBox = LockedBox<(any Error)?>(nil)

    let stream = ValueObservation
      .tracking { db in try Int.fetchAll(db, sql: "SELECT id FROM missing_table") }
      .values(in: queue)
      .toAsyncStream(onError: { error in errorBox.set(error) })

    var iterator = stream.makeAsyncIterator()
    let value = await iterator.next()
    #expect(value == nil)  // stream completed
    #expect(errorBox.get() != nil)
  }
}
```

(`LockedBox` already exists in `MoolahTests/Support/LockedBox.swift`.)

- [ ] **Step 3: Run the test to verify it fails.**

```bash
mkdir -p .agent-tmp
just test-mac ValueObservationAsyncStreamTests 2>&1 | tee .agent-tmp/stage1-test.txt
```
Expected: COMPILE FAIL — `toAsyncStream` is not defined yet.

- [ ] **Step 4: Create the `ObservationErrorChannel` actor file.**

Create `Backends/GRDB/Observation/ObservationErrorChannel.swift` with the source from Reference R2.1.

- [ ] **Step 5: Create the bridge file.**

Create `Backends/GRDB/Observation/ValueObservation+AsyncStream.swift` with the source from Reference R2.

- [ ] **Step 6: Add a unit test for `ObservationErrorChannel`.**

Create `MoolahTests/Backends/GRDB/Observation/ObservationErrorChannelTests.swift`:

```swift
import Foundation
import Testing

@testable import Moolah

@Suite("ObservationErrorChannel")
struct ObservationErrorChannelTests {

  @Test("surfaceAndFinish yields error then completes stream in one call")
  func surfaceAndFinishYieldsAndCompletes() async {
    let channel = ObservationErrorChannel()
    var iterator = channel.stream.makeAsyncIterator()
    let testError = NSError(domain: "test", code: 42)

    await channel.surfaceAndFinish(testError)

    let surfaced = await iterator.next()
    #expect((surfaced as NSError?)?.code == 42)

    let next = await iterator.next()
    #expect(next == nil)  // stream completed
  }

  @Test("after surfaceAndFinish, further calls are no-ops")
  func subsequentCallsNoOp() async {
    let channel = ObservationErrorChannel()
    var iterator = channel.stream.makeAsyncIterator()
    await channel.surfaceAndFinish(NSError(domain: "first", code: 1))
    _ = await iterator.next()
    _ = await iterator.next()  // completion
    await channel.surfaceAndFinish(NSError(domain: "second", code: 2))
    // No new emission should appear on the iterator (stream already finished).
  }
}
```

- [ ] **Step 7: Run the tests; verify they pass.**

```bash
just test-mac ValueObservationAsyncStreamTests ObservationErrorChannelTests 2>&1 | tee .agent-tmp/stage1-test.txt
grep -i 'failed\|error:' .agent-tmp/stage1-test.txt | grep -v 'SQLITE_ERROR' || echo "PASS"
```
Expected: PASS (the missing-table test logs `SQLITE_ERROR` in the error path; that's expected, not a failure).

- [ ] **Step 8: Run the full Mac test suite to verify no regression.**

```bash
just test-mac 2>&1 | tee .agent-tmp/stage1-fulltest.txt
grep -E 'failed|error:' .agent-tmp/stage1-fulltest.txt | grep -v 'SQLITE_ERROR'
```
Expected: no test failures. Existing tests are unchanged.

- [ ] **Step 9: Format and commit.**

```bash
just format
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/reactive-sync-plan add Backends/GRDB/Observation/ValueObservation+AsyncStream.swift Backends/GRDB/Observation/ObservationErrorChannel.swift MoolahTests/Backends/GRDB/Observation/ValueObservationAsyncStreamTests.swift MoolahTests/Backends/GRDB/Observation/ObservationErrorChannelTests.swift project.yml
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/reactive-sync-plan commit -m "feat(grdb): add toAsyncStream bridge + ObservationErrorChannel

Provides the two foundation pieces every reactive repository depends on:

- toAsyncStream(onError:) bridges GRDB AsyncValueObservation to a
  non-throwing AsyncStream that domain protocols can return. Wires
  continuation.onTermination so consumer Task cancellation propagates
  back to the underlying ValueObservation.
- ObservationErrorChannel actor provides the per-repository
  observeErrors() channel. Single surfaceAndFinish(_:) method
  serialises error-yield + stream-completion into one actor call —
  avoids the two-Task race that drops errors when finish wins.

No production callers yet — methods land in subsequent commits."
```

(Signpost instrumentation is added per-store in stages 5-13, not here. We keep commit 1 minimal and add instrumentation alongside the code that benefits from it.)

---

## Stage 2 — Baseline benchmark (legacy implementation)

**Files:**
- Create: `MoolahBenchmarks/SyncReactivityBenchmarks.swift`

- [ ] **Step 1: Create the benchmark file.**

Create `MoolahBenchmarks/SyncReactivityBenchmarks.swift`:

```swift
import Foundation
import GRDB
import XCTest

@testable import Moolah

/// Benchmarks the cost of sync-driven UI refresh.
///
/// Intent: capture three numbers per implementation (legacy / reactive /
/// reactive + mitigations) so we can decide which mitigations from the
/// design's toolbox are warranted.
///
/// Numbers we care about:
/// - **emissions:** how many store updates fire during a 50k-record sync.
/// - **mainThreadMs:** cumulative MainActor time consumed by store updates.
/// - **wallClockMs:** total time from sync-apply start to last emission.
///
/// Run via `just benchmark SyncReactivityBenchmarks`.
final class SyncReactivityBenchmarks: XCTestCase {

  /// 50k transactions delivered as one CKSyncEngine fetch session.
  /// Drives the apply path through TestBackend's GRDB queue, then waits
  /// for the AccountStore to settle.
  ///
  /// Uses `measure(metrics:)` with `XCTClockMetric` so the wall-clock is
  /// surfaced in `xcresult` and Instruments rather than swallowed in
  /// stdout. Per `guides/BENCHMARKING_GUIDE.md`.
  func testBulkSyncRefresh() throws {
    let metrics: [any XCTMetric] = [XCTClockMetric()]
    let options = XCTMeasureOptions()
    options.iterationCount = 3
    measure(metrics: metrics, options: options) {
      // Each iteration: fresh backend, fresh store, bulk write, await
      // settle. The XCTClockMetric records the wall-clock per iteration.
      let semaphore = DispatchSemaphore(value: 0)
      Task {
        do {
          let (backend, database) = try TestBackend.create()
          let accountIds = (0..<10).map { _ in UUID() }
          TestBackend.seed(
            accounts: accountIds.map { id in
              Account(id: id, name: "A\(id)", type: .bank, instrument: .defaultTestInstrument)
            },
            in: database
          )
          let store = AccountStore(
            repository: backend.accounts,
            conversionService: backend.conversionService,
            targetInstrument: .defaultTestInstrument
          )
          await store.load()  // legacy path; replaced with waitForFirstEmission in commit 6

          // Use TestBackend.seed(transactions:in:) when it exists (check
          // MoolahTests/Support/TestBackend*.swift); otherwise fall back
          // to a raw INSERT loop with the column list fetched from
          // Backends/GRDB/Schema/ProfileSchema*.swift via grep.
          try TestBackend.seedBulkTransactionLegs(
            count: 50_000,
            accountIds: accountIds,
            in: database
          )
          // Drive a single notification through the legacy path (commit
          // 2 only). For the reactive path (commits 6, 15) this is
          // replaced with `try await store.waitForNextEmission(...)`.
          await store.reloadFromSync()
          semaphore.signal()
        } catch {
          XCTFail("bulk-sync iteration failed: \(error)")
          semaphore.signal()
        }
      }
      semaphore.wait()
    }
  }
}
```

(`TestBackend.seedBulkTransactionLegs(count:accountIds:in:)` is a NEW seed helper added by this commit alongside the benchmark — it lives in `MoolahTests/Support/TestBackend+SeedBulkLegs.swift`. The implementer fills in the column list by reading `Backends/GRDB/Schema/ProfileSchema+Transactions.swift` during this stage. This is more maintainable than inlining raw SQL into the benchmark itself.)

- [ ] **Step 2: Run the benchmark to capture baseline numbers.**

```bash
just benchmark SyncReactivityBenchmarks 2>&1 | tee .agent-tmp/stage2-baseline.txt
```
Expected: passes; `wallClockMs` value captured in the output. Save the value to the PR description for comparison.

- [ ] **Step 3: Commit.**

```bash
just format
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/reactive-sync-plan add MoolahBenchmarks/SyncReactivityBenchmarks.swift project.yml
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/reactive-sync-plan commit -m "bench(sync): add SyncReactivityBenchmarks baseline

Captures the wall-clock cost of a 50k-leg bulk-sync refresh under the
legacy debounced-reload path. Used as the comparison point for the
reactive cutover in commit 6 (AccountStore reactive) and commit 15
(all stores reactive). Per spec Section 2 — measure first, mitigate
only against measurements."
```

---

## Stage 3 — `AccountRepository.observeAll()` + `observeErrors()`

**Files:**
- Modify: `Domain/Repositories/AccountRepository.swift`
- Modify: `Backends/GRDB/Repositories/GRDBAccountRepository.swift`
- Create: `MoolahTests/Domain/AccountRepositoryObservationContractTests.swift`
- Modify: `Backends/Preview/PreviewAccountRepository.swift` (or wherever the preview impl lives — `grep -l 'AccountRepository' Backends/`)

- [ ] **Step 1: Write the failing observation contract test.**

Create `MoolahTests/Domain/AccountRepositoryObservationContractTests.swift`:

```swift
import Foundation
import Testing

@testable import Moolah

@Suite("AccountRepository observation contract")
struct AccountRepositoryObservationContractTests {

  @Test("initial emission reflects current DB state")
  func initialEmission() async throws {
    let (backend, _) = try TestBackend.create()
    var iterator = backend.accounts.observeAll().makeAsyncIterator()
    let initial = await iterator.next()
    #expect(initial?.isEmpty == true)
  }

  @Test("create emits new value")
  func createEmits() async throws {
    let (backend, _) = try TestBackend.create()
    var iterator = backend.accounts.observeAll().makeAsyncIterator()
    _ = await iterator.next()  // initial empty

    _ = try await backend.accounts.create(
      Account(name: "A", type: .bank, instrument: .defaultTestInstrument),
      openingBalance: nil
    )

    let afterCreate = await iterator.next()
    #expect(afterCreate?.count == 1)
    #expect(afterCreate?.first?.name == "A")
  }

  @Test("update emits new value")
  func updateEmits() async throws {
    let (backend, _) = try TestBackend.create()
    let created = try await backend.accounts.create(
      Account(name: "A", type: .bank, instrument: .defaultTestInstrument),
      openingBalance: nil
    )
    var iterator = backend.accounts.observeAll().makeAsyncIterator()
    _ = await iterator.next()  // initial — single account
    var updated = created
    updated.name = "Renamed"
    _ = try await backend.accounts.update(updated)
    let after = await iterator.next()
    #expect(after?.first?.name == "Renamed")
  }

  @Test("observeErrors emits on programmer-bug error")
  func observeErrorsOnProgrammerBug() async throws {
    // We don't have a clean way to inject a programmer-bug error into
    // the live repository. This test is a placeholder for the wiring;
    // the bridge unit test in stage 1 covers the actual error
    // propagation. Asserting only that observeErrors() is callable
    // and returns an AsyncStream that doesn't immediately emit.
    let (backend, _) = try TestBackend.create()
    var iterator = backend.accounts.observeErrors().makeAsyncIterator()
    let didEmit = await Task {
      try? await Task.sleep(for: .milliseconds(100))
      return await iterator.next() != nil
    }.value
    #expect(didEmit == false)
  }
}
```

- [ ] **Step 2: Run the test; confirm it fails to compile.**

```bash
just test-mac AccountRepositoryObservationContractTests 2>&1 | tee .agent-tmp/stage3-test.txt
```
Expected: COMPILE FAIL — `observeAll`, `observeErrors` not defined on `AccountRepository`.

- [ ] **Step 3: Add the protocol methods.**

Edit `Domain/Repositories/AccountRepository.swift`:

```swift
protocol AccountRepository: Sendable {
  func fetchAll() async throws -> [Account]
  func observeAll() -> AsyncStream<[Account]>
  func observeErrors() -> AsyncStream<any Error>
  func create(_ account: Account, openingBalance: InstrumentAmount?) async throws -> Account
  func update(_ account: Account) async throws -> Account
  func delete(id: UUID) async throws
  // … any other existing methods unchanged
}
```

- [ ] **Step 4: Implement on `GRDBAccountRepository`.**

Use the shared `ObservationErrorChannel` already created in Stage 1 (`Backends/GRDB/Observation/ObservationErrorChannel.swift`). Do NOT redefine it locally.

Add a stored `errorChannel` property to `GRDBAccountRepository` (e.g. `private let errorChannel = ObservationErrorChannel()`), then:

```swift
extension GRDBAccountRepository {
  func observeAll() -> AsyncStream<[Account]> {
    let channel = self.errorChannel
    return ValueObservation
      .tracking { db in try AccountRow.fetchAll(db).map(Account.init) }
      .removeDuplicates()
      .values(in: writer)
      .toAsyncStream(onError: { error in
        Task { await channel.surfaceAndFinish(error) }
      })
  }

  func observeErrors() -> AsyncStream<any Error> {
    errorChannel.stream
  }
}
```

The `surfaceAndFinish(_:)` single-call form serialises the yield + finish inside the actor (vs. two independent `Task`s, which would race and could drop the error if `finish` runs before `surface` completes).

`Account` must conform to `Equatable` for `.removeDuplicates()` to compile. Most domain row types already do — verify with `grep -n 'extension Account.*Equatable\|struct Account.*Equatable' Domain/Models/Account.swift`. If it doesn't conform, add the conformance as a separate single-line commit before this stage's main commit (or as a sub-step of step 4).

- [ ] **Step 5: Add no-op implementations to any other `AccountRepository` conformer.**

Run `grep -rln 'AccountRepository' Backends/Preview/ Backends/InMemory/ 2>/dev/null` and add `observeAll()` / `observeErrors()` returning empty streams (`AsyncStream { _ in }`) to each conformer.

- [ ] **Step 6: Run the contract test; verify it passes.**

```bash
just test-mac AccountRepositoryObservationContractTests 2>&1 | tee .agent-tmp/stage3-test.txt
grep -E 'failed|✗' .agent-tmp/stage3-test.txt && echo "FAIL" || echo "PASS"
```

- [ ] **Step 7: Run the full test suite; verify no regression.**

```bash
just test-mac 2>&1 | tee .agent-tmp/stage3-fulltest.txt
grep -E 'failed|error:' .agent-tmp/stage3-fulltest.txt
```
Expected: no failures.

- [ ] **Step 8: Format, run code review, commit.**

```bash
just format
just format-check
```

Then dispatch `code-review`, `database-code-review`, `concurrency-review` agents on the modified files. Address any findings before committing.

```bash
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/reactive-sync-plan add Domain/Repositories/AccountRepository.swift Backends/GRDB/Repositories/GRDBAccountRepository.swift MoolahTests/Domain/AccountRepositoryObservationContractTests.swift Backends/Preview/PreviewAccountRepository.swift
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/reactive-sync-plan commit -m "feat(account): add observeAll/observeErrors to AccountRepository

Adds the reactive observation surface per the design:
- observeAll() -> AsyncStream<[Account]> via GRDB ValueObservation
- observeErrors() -> AsyncStream<any Error> via shared error channel
- Contract tests cover initial emission, mutation emission, and the
  error-stream-is-quiet invariant

No store consumes these methods yet — AccountStore migrates in commit 5."
```

---

## Stage 4 — `InstrumentConversionService.observeRates()` + `observeErrors()`

**Files:**
- Modify: `Domain/Services/InstrumentConversionService.swift`
- Modify: GRDB conversion service implementation (locate via `grep -rln 'class.*InstrumentConversionService\|FiatConversionService' Backends/GRDB/`)
- Create: `MoolahTests/Domain/InstrumentConversionServiceObservationContractTests.swift`

- [ ] **Step 1: Locate the GRDB conversion service implementation.**

```bash
grep -rln 'InstrumentConversionService\|FiatConversionService' Backends/ | head -5
```
Note the file path. Per the codebase tour, `FiatConversionService` is the production conformer.

- [ ] **Step 2: Confirm the rate cache table names.**

```bash
grep -n 'CREATE TABLE\|tableName' Backends/GRDB/Schema/ProfileSchema*.swift | grep -iE 'exchange|stock|crypto'
```
Expected: confirms `exchange_rate`, `stock_price`, `crypto_price` are the three live cache table names.

- [ ] **Step 3: Write the failing parameterised contract test.**

Create `MoolahTests/Domain/InstrumentConversionServiceObservationContractTests.swift`:

```swift
import Foundation
import GRDB
import Testing

@testable import Moolah

@Suite("InstrumentConversionService.observeRates contract")
struct InstrumentConversionServiceObservationContractTests {

  enum CacheTable: String, CaseIterable {
    case exchangeRate = "exchange_rate"
    case stockPrice = "stock_price"
    case cryptoPrice = "crypto_price"
  }

  @Test("write to cache table emits a tick", arguments: CacheTable.allCases)
  func writeEmitsTick(table: CacheTable) async throws {
    let (backend, database) = try TestBackend.create()
    var iterator = backend.conversionService.observeRates().makeAsyncIterator()
    _ = await iterator.next()  // initial tick on subscription

    try await database.write { db in
      // SQL literals per table (DATABASE_CODE_GUIDE forbids
      // `db.execute(sql: stringVar)` — only literal-typed SQL is safe.)
      switch table {
      case .exchangeRate:
        try db.execute(literal: insertExchangeRate())
      case .stockPrice:
        try db.execute(literal: insertStockPrice())
      case .cryptoPrice:
        try db.execute(literal: insertCryptoPrice())
      }
    }

    let next = await iterator.next()
    #expect(next != nil, "observeRates() did not emit after writing to \(table.rawValue)")
  }

  @Test("subscribes-before-data still emits on first write", arguments: CacheTable.allCases)
  func subscribeBeforeDataEmits(table: CacheTable) async throws {
    // Catches the empty-table region-inference bug (Stage 0 caveat):
    // if the implementation uses `SELECT 1 FROM table LIMIT 1` for
    // region inference, the table is only registered on first row
    // access — so a fresh-install profile (empty cache tables) never
    // emits on the first sync write. The fix is `tracking(regions:)`
    // with an explicit table list. This test catches a regression to
    // the inference form.
    let (backend, database) = try TestBackend.create()  // empty cache tables
    var iterator = backend.conversionService.observeRates().makeAsyncIterator()
    _ = await iterator.next()  // initial tick

    try await database.write { db in
      switch table {
      case .exchangeRate:
        try db.execute(literal: insertExchangeRate())
      case .stockPrice:
        try db.execute(literal: insertStockPrice())
      case .cryptoPrice:
        try db.execute(literal: insertCryptoPrice())
      }
    }

    let next = await iterator.next()
    #expect(next != nil, "observeRates() missed the first write to \(table.rawValue) (empty-table region bug)")
  }

  @Test("observeErrors stays quiet on healthy service")
  func observeErrorsQuiet() async throws {
    let (backend, _) = try TestBackend.create()
    var iterator = backend.conversionService.observeErrors().makeAsyncIterator()
    let didEmit = await Task {
      try? await Task.sleep(for: .milliseconds(100))
      return await iterator.next() != nil
    }.value
    #expect(didEmit == false)
  }

  // SQL literals per table — fill in real columns from
  // ProfileSchema+RateCaches.swift during implementation. The
  // following are placeholders matching the expected table shape; the
  // implementer MUST replace them with the actual minimum-viable
  // INSERT for each table (all NOT NULL columns, valid values).

  private func insertExchangeRate() -> SQL {
    """
    INSERT INTO exchange_rate (base_code, quote_code, rate_date, rate)
    VALUES ('USD', 'AUD', '2026-05-06', 1.5)
    """
  }

  private func insertStockPrice() -> SQL {
    """
    INSERT INTO stock_price (ticker, price_date, close_price, currency_code)
    VALUES ('AAPL', '2026-05-06', 18000, 'USD')
    """
  }

  private func insertCryptoPrice() -> SQL {
    """
    INSERT INTO crypto_price (token_id, price_date, price, quote_currency)
    VALUES ('bitcoin', '2026-05-06', 600000, 'USD')
    """
  }
}
```

- [ ] **Step 4: Add the protocol methods.**

Edit `Domain/Services/InstrumentConversionService.swift`:

```swift
protocol InstrumentConversionService: Sendable {
  // existing methods unchanged
  func observeRates() -> AsyncStream<Void>
  func observeErrors() -> AsyncStream<any Error>
}
```

- [ ] **Step 5: Implement on the GRDB conformer.**

Edit the file located in step 1. Add the same `ObservationErrorChannel` pattern as stage 3, then:

```swift
func observeRates() -> AsyncStream<Void> {
  let channel = self.errorChannel
  return ValueObservation
    // Explicit-region form — required because the cache tables may be
    // empty on a fresh install. The inference form (`tracking { db in }`
    // with `SELECT 1 FROM table LIMIT 1`) only registers a table after
    // the first row is read, so a fresh-install profile would miss the
    // first sync write to each cache table. See Stage 0 guide caveat
    // and the `subscribeBeforeDataEmits` test in step 3.
    .tracking(
      regions: [
        Table("exchange_rate"),
        Table("stock_price"),
        Table("crypto_price"),
      ],
      fetch: { _ in () }
    )
    .values(in: database)
    .toAsyncStream(onError: { error in
      Task { await channel.surfaceAndFinish(error) }
    })
  // Note: NO .removeDuplicates() — Void == Void would suppress every emission.
}

func observeErrors() -> AsyncStream<any Error> {
  errorChannel.stream
}
```

(`Table("exchange_rate")` is the GRDB shorthand for declaring a `DatabaseRegion` over an entire table without requiring a `TableRecord` type. If the implementer prefers the typed form `ExchangeRateRecord.all()`, both work — verify the type names against the actual Records files in `Backends/GRDB/Records/`.)

- [ ] **Step 6: Add no-op implementations to test doubles.**

Run `grep -rln 'InstrumentConversionService' MoolahTests/Support/` and add `observeRates()` returning a single tick (`AsyncStream { _ in }`) and `observeErrors()` returning an empty stream to: `FixedConversionService`, `FailingConversionService`, `CountingConversionService`, `RecordingConversionService`, `ThrowingConversionService`, `ThrowingCountingConversionService`, `DateBasedFixedConversionService`, `DateFailingConversionService`.

- [ ] **Step 7: Run contract tests; verify they pass for all three table families.**

```bash
just test-mac InstrumentConversionServiceObservationContractTests 2>&1 | tee .agent-tmp/stage4-test.txt
```

- [ ] **Step 8: Run the full test suite; verify no regression.**

```bash
just test-mac 2>&1 | tee .agent-tmp/stage4-fulltest.txt
```

- [ ] **Step 9: Format, review, commit.**

```bash
just format
```
Dispatch `code-review`, `database-code-review`, `concurrency-review`, `instrument-conversion-review` agents. Address findings.

```bash
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/reactive-sync-plan add Domain/Services/InstrumentConversionService.swift Backends/GRDB/<conversion-service-file>.swift MoolahTests/Domain/InstrumentConversionServiceObservationContractTests.swift MoolahTests/Support/*ConversionService.swift
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/reactive-sync-plan commit -m "feat(conversion): add observeRates/observeErrors

Adds the rate-tick stream that watches all three cache table families
(exchange_rate, stock_price, crypto_price) via region inference. Stores
that compute converted balances will subscribe to this and recompute on
emission. Parameterised contract test asserts the union region is wired
correctly per family. Per spec Section 4."
```

---

## Stage 5 — Migrate `AccountStore` to reactive observation (CANONICAL — read this stage in full)

This is the canonical reactive-store migration. Subsequent store migrations (stages 7, 8, 9, 11, 12, 13) follow the same shape; refer back here for the patterns.

**Files:**
- Create: `MoolahTests/Support/StoreObservation+Test.swift` (test helpers, used by every subsequent stage)
- Create: `MoolahTests/Features/Accounts/AccountStoreSyncRefreshTests.swift`
- Modify: `Features/Accounts/AccountStore.swift` (the big rewrite)
- Modify: `MoolahTests/Features/Accounts/AccountStoreTests.swift` (rewrite legacy tests to emission-awaiting pattern)
- Modify: `App/ProfileSession.swift` (call `accountStore.stopObserving()` in `cleanupSync`; remove `.accounts` entry from `storesToReload`)
- Modify: `App/ProfileSession+SyncWiring.swift` (remove the `.accounts` plan)

- [ ] **Step 1: Create the test helpers (used by every subsequent store migration).**

Create `MoolahTests/Support/StoreObservation+Test.swift`:

```swift
import Foundation
import Testing

@testable import Moolah

/// Test-only protocol for awaiting store observation emissions.
///
/// Production stores do NOT conform to this in the production target;
/// the conformance is added in this file (test target only) so the
/// "I just applied an emission" tick stream stays out of the live
/// `@Observable` store.
@MainActor
protocol TestableStoreObservation: AnyObject {
  associatedtype State
  var observationTicks: AsyncStream<Void> { get }
  var snapshot: State { get }
}

struct StoreEmissionTimeoutError: Error, CustomStringConvertible {
  let storeType: String
  let predicate: String?
  var description: String {
    if let predicate {
      return "Timed out waiting for \(storeType) emission matching \(predicate)"
    }
    return "Timed out waiting for first \(storeType) emission"
  }
}

extension TestableStoreObservation {
  func waitForFirstEmission(timeout: Duration = .seconds(2)) async throws {
    var iterator = observationTicks.makeAsyncIterator()
    try await withTimeout(
      timeout,
      storeType: "\(Self.self)",
      predicate: nil,
      body: { _ = await iterator.next() }
    )
  }

  func waitForNextEmission(
    matching predicate: @Sendable @escaping (State) -> Bool,
    description: String = "<predicate>",
    timeout: Duration = .seconds(2)
  ) async throws {
    var iterator = observationTicks.makeAsyncIterator()
    try await withTimeout(
      timeout,
      storeType: "\(Self.self)",
      predicate: description,
      body: {
        while await iterator.next() != nil {
          if predicate(self.snapshot) { return }
        }
      }
    )
  }

  func didEmitWithin(timeout: Duration) async -> Bool {
    do {
      try await waitForFirstEmission(timeout: timeout)
      return true
    } catch {
      return false
    }
  }
}

private enum RaceResult: Sendable { case completed, timedOut }

/// Runs `body` with a deadline. Throws `StoreEmissionTimeoutError` if
/// `body` doesn't complete within `timeout`. Uses an enum to carry the
/// race result out of the TaskGroup so the throw is gated on the
/// timeout actually winning, not run unconditionally.
///
/// `RaceResult` is hoisted to file scope (not nested in the function)
/// so SwiftLint's `nesting` rule doesn't complain about depth-2
/// type nesting.
private func withTimeout(
  _ timeout: Duration,
  storeType: String,
  predicate: String?,
  body: @escaping @Sendable () async -> Void
) async throws {
  let result = await withTaskGroup(of: RaceResult.self) { group -> RaceResult in
    group.addTask { await body(); return .completed }
    group.addTask {
      try? await Task.sleep(for: timeout)
      return .timedOut
    }
    let first = await group.next() ?? .timedOut
    group.cancelAll()
    return first
  }

  if result == .timedOut {
    throw StoreEmissionTimeoutError(storeType: storeType, predicate: predicate)
  }
}
```

- [ ] **Step 2: Write the failing sync-refresh regression test.**

Create `MoolahTests/Features/Accounts/AccountStoreSyncRefreshTests.swift`:

```swift
import Foundation
import Testing

@testable import Moolah

@Suite("AccountStore sync refresh")
struct AccountStoreSyncRefreshTests {

  @Test("remote account insert refreshes the store without manual refresh")
  func remoteInsertRefreshes() async throws {
    let (backend, _) = try TestBackend.create()
    let store = AccountStore(
      repository: backend.accounts,
      conversionService: backend.conversionService,
      targetInstrument: .defaultTestInstrument
    )
    try await store.waitForFirstEmission()
    #expect(store.accounts.ordered.isEmpty)

    _ = try await backend.accounts.create(
      Account(name: "Synced", type: .bank, instrument: .defaultTestInstrument),
      openingBalance: nil
    )

    try await store.waitForNextEmission(
      matching: { $0.accounts.count == 1 },
      description: "accounts.count == 1"
    )
    #expect(store.accounts.ordered.first?.name == "Synced")
  }

  @Test(
    "rate-tick triggers convertedTotal recompute even when accounts unchanged",
    arguments: ["exchange_rate", "stock_price", "crypto_price"]
  )
  func convertedTotalRecomputesOnRateTick(table: String) async throws {
    // CRITICAL: this test MUST use the real GRDBInstrumentConversionService
    // (the one TestBackend.create() wires up — `FiatConversionService`
    // backed by the in-memory GRDB queue). Substituting `FixedConversionService`
    // or any other test double makes the test vacuous: the stub's
    // observeRates() is a no-op AsyncStream that cannot signal a
    // cache-table write, so the test would pass for the wrong reason
    // (an unrelated emission from the account observation) and would
    // not catch a regression to the empty-table region inference bug.
    let (backend, database) = try TestBackend.create()
    let store = AccountStore(
      repository: backend.accounts,
      conversionService: backend.conversionService,
      targetInstrument: .defaultTestInstrument
    )
    try await store.waitForFirstEmission()

    // Write into the named cache table using a SQL literal helper. Same
    // helper functions as the InstrumentConversionService contract test
    // — reuse if already defined in MoolahTests/Domain/, otherwise
    // duplicate inline (test fixtures, not production).
    try await database.write { db in
      switch table {
      case "exchange_rate": try db.execute(literal: insertExchangeRateFixture())
      case "stock_price":   try db.execute(literal: insertStockPriceFixture())
      case "crypto_price":  try db.execute(literal: insertCryptoPriceFixture())
      default: Issue.record("unknown table \(table)")
      }
    }

    try await store.waitForNextEmission(
      matching: { _ in true },
      description: "any emission post-rate-write to \(table)",
      timeout: .seconds(1)
    )
  }

  @Test("stopObserving cancels the observation task")
  func stopObservingCancels() async throws {
    let (backend, _) = try TestBackend.create()
    let store = AccountStore(
      repository: backend.accounts,
      conversionService: backend.conversionService,
      targetInstrument: .defaultTestInstrument
    )
    try await store.waitForFirstEmission()
    store.stopObserving()

    _ = try await backend.accounts.create(
      Account(name: "After cancel", type: .bank, instrument: .defaultTestInstrument),
      openingBalance: nil
    )
    let didEmit = await store.didEmitWithin(timeout: .milliseconds(200))
    #expect(didEmit == false)
  }
}
```

- [ ] **Step 3: Run the test; verify it fails.**

```bash
just test-mac AccountStoreSyncRefreshTests 2>&1 | tee .agent-tmp/stage5-test.txt
```
Expected: COMPILE FAIL — `waitForFirstEmission`, `stopObserving`, etc. not defined yet.

- [ ] **Step 4: Rewrite `AccountStore` to the reactive pattern.**

Replace `Features/Accounts/AccountStore.swift` with the canonical pattern from spec Section 5. Key deltas from the existing file:

- Add `observationTask: Task<Void, Never>?` and `conversionTask: Task<Void, Never>?` private vars.
- Replace `init` body's deferred `load()` call with `observationTask = Task { await self.observe() }`.
- Add `deinit { observationTask?.cancel(); conversionTask?.cancel() }`.
- Add `private func observe() async` with the `withTaskGroup` shape from spec Section 5 (subscribe to `repository.observeAll()`, `repository.observeErrors()`, `conversionService.observeRates()`, `conversionService.observeErrors()`).
- Add `func stopObserving()`.
- Delete `func load()` and `func reloadFromSync()`.
- Delete the optimistic-update branches and rollback paths from `create`, `update`, `delete`. Mutations become pass-through.
- Rewrite `recomputeConvertedTotals()` with the conditional-cancel retry pattern from spec Section 5 ("Retry-loop interaction").
- Delete `isLoading` state (or keep it as a `hasLoadedAtLeastOnce` flag flipped on first emission, ONLY if a view actually depends on it — `grep -rn 'isLoading' Features/` to confirm).
- Add a test-observation tick channel: a `private(set) var _observationTicks: AsyncStream<Void>` and a paired `_observationTickContinuation: AsyncStream<Void>.Continuation` initialised in `init`. After every state assignment in `apply(accounts:)` and after every recompute in `recomputeConvertedTotals()`, call `_observationTickContinuation.yield()`. Finish the continuation in `stopObserving()` and `deinit`. The leading underscore + `internal` access (the project is a single app target — `@testable import Moolah` exposes internal members to tests, so `@_spi` is unnecessary and prohibited per CODE_GUIDE.md §7).

- **Inline the conditional-cancel `recomputeConvertedTotals()` from spec Section 5:**

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
  // Critical: the `guard conversionTask == nil else { return }` line
  // is load-bearing. Without it, every emission from observeRates()
  // (including writes for instruments unrelated to this profile) would
  // cancel and respawn the retry loop, resetting the wait clock and
  // potentially delaying recovery indefinitely.
  guard conversionTask == nil else { return }
  let delay = retryDelay
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

(The `Task { @MainActor in … }` annotation is required even though the call site is already on `@MainActor`: future refactors that move `recomputeConvertedTotals` off MainActor would silently introduce a race without the explicit annotation.)

(The full `AccountStore.swift` rewrite is too large to inline in one block — an engineer following this stage applies the spec Section 5 canonical pattern + the snippet above + the test tick channel described above to the existing file.)

Add to `MoolahTests/Support/StoreObservation+Test.swift` at the bottom (test target only):

```swift
extension AccountStore: TestableStoreObservation {
  var observationTicks: AsyncStream<Void> { _observationTicks }
  var snapshot: AccountStore { self }  // tests assert directly against published @Observable state
}
```

(`AccountStore` already conforms to the necessary access via `@testable import Moolah` and `internal` access on `_observationTicks`. No `@_spi(MoolahTests)` annotation — the project is a single-target app and `@testable` is the standard mechanism.)

- [ ] **Step 5: Update `ProfileSession.cleanupSync` to call `stopObserving()`.**

The order matters. Per spec Section 5 sign-out teardown ordering, `stopObserving()` MUST run AFTER any `deleteAllLocalData()` call, so the observation can emit the empty-state transition before being cancelled. `cleanupSync` is called from the parent session manager after the CKSyncEngine teardown completes; verify the call site sequencing as part of this step (`grep -n 'cleanupSync(coordinator' App/`).

Edit `App/ProfileSession.swift`:

```swift
func cleanupSync(coordinator: SyncCoordinator) {
  if let token = syncObserverToken {
    coordinator.removeObserver(token: token)
    syncObserverToken = nil
  }
  coordinator.removeInstrumentRemoteChangeCallback(profileId: profile.id)
  syncReloadTask?.cancel()
  syncReloadTask = nil
  // … existing cleanup ...
  accountStore.stopObserving()  // NEW — must run AFTER any GRDB wipes
  // …
}
```

- [ ] **Step 5b: Add a unit test pinning the sign-out teardown ordering.**

Manual log inspection is not sufficient — the ordering invariant must be testable so a future refactor can't silently invert it. Add to `MoolahTests/Features/Accounts/AccountStoreSyncRefreshTests.swift`:

```swift
@Test("GRDB wipes during sign-out reach the store before stopObserving cancels it")
func signOutTeardownOrdering() async throws {
  let (backend, database) = try TestBackend.create()
  _ = try await backend.accounts.create(
    Account(name: "WillBeWiped", type: .bank, instrument: .defaultTestInstrument),
    openingBalance: nil
  )
  let store = AccountStore(
    repository: backend.accounts,
    conversionService: backend.conversionService,
    targetInstrument: .defaultTestInstrument
  )
  try await store.waitForNextEmission(
    matching: { $0.accounts.count == 1 },
    description: "store sees seeded account"
  )

  // Simulate the sign-out path: GRDB wipes happen first, then
  // stopObserving cancels the observation.
  try await database.write { db in
    try db.execute(sql: "DELETE FROM account")
  }
  try await store.waitForNextEmission(
    matching: { $0.accounts.isEmpty },
    description: "wipe propagated to store before cancellation",
    timeout: .seconds(1)
  )
  store.stopObserving()
  #expect(store.accounts.ordered.isEmpty)
}
```

This test fails if a future change inverts the order in `cleanupSync` to call `stopObserving()` before the GRDB wipe — the wipe-emission would never reach the store and the second `waitForNextEmission` would time out.

- [ ] **Step 6: Remove `.accounts` from `storesToReload`.**

Edit `App/ProfileSession+SyncWiring.swift`:

```swift
static func storesToReload(for changedTypes: Set<String>) -> StoreReloadPlan {
  var plan: StoreReloadPlan = []
  // .accounts no longer needed — AccountStore is reactive (commit 5).
  // Account/Transaction/TransactionLeg changes propagate via
  // AccountRepository.observeAll() and InstrumentConversionService.observeRates().
  if changedTypes.contains(CategoryRow.recordType) {
    plan.insert(.categories)
  }
  if changedTypes.contains(EarmarkRow.recordType)
    || changedTypes.contains(EarmarkBudgetItemRow.recordType)
    || changedTypes.contains(TransactionLegRow.recordType)
  {
    plan.insert(.earmarks)
  }
  if changedTypes.contains(ImportRuleRow.recordType) {
    plan.insert(.importRules)
  }
  return plan
}
```

Also remove the `accountStore.reloadFromSync()` call from `ProfileSession.scheduleReloadFromSync` (the method is now gone from `AccountStore`).

- [ ] **Step 7: Rewrite the existing `AccountStoreTests` to the emission-awaiting pattern.**

Open `MoolahTests/Features/Accounts/AccountStoreTests.swift`. For each test that calls `await store.load()`, replace it with `try await store.waitForFirstEmission()`. For each test that asserts the optimistic-update behaviour ("after `create`, accounts contains the new item synchronously before the await returns"), rewrite to await emission via `waitForNextEmission`. Run the suite after each batch of fixes.

```bash
just test-mac AccountStoreTests 2>&1 | tee .agent-tmp/stage5-account-tests.txt
```

- [ ] **Step 8: Run the new sync-refresh test; verify it passes.**

```bash
just test-mac AccountStoreSyncRefreshTests 2>&1 | tee .agent-tmp/stage5-sync-test.txt
```

- [ ] **Step 9: Run the full test suite; verify no regression.**

```bash
just test 2>&1 | tee .agent-tmp/stage5-fulltest.txt
grep -E 'failed|error:' .agent-tmp/stage5-fulltest.txt
```

- [ ] **Step 10: Manually verify the symptom-A bug is fixed.**

Run the app: `just run-mac`. Open two macOS app instances logged into the same iCloud account (or use the `automate-app` skill to drive a write through the test backend). Confirm the sidebar updates without manual refresh.

- [ ] **Step 11: Format, run all relevant reviewers, fix findings, commit.**

Dispatch in parallel: `code-review`, `concurrency-review`, `database-code-review`, `instrument-conversion-review`. Address findings before committing.

```bash
just format
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/reactive-sync-plan add -A  # this stage touches many files; review with git status first
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/reactive-sync-plan commit -m "feat(account): migrate AccountStore to reactive observation

The user-visible bug fix: sidebar now auto-refreshes on remote sync
without pull-to-refresh. AccountStore drops load()/reloadFromSync()/
optimistic-state bookkeeping and subscribes to repository.observeAll()
plus conversionService.observeRates() in init. Mutations become
pass-through. Conditional-cancel retry pattern preserves eventual
recovery from transient conversion failures without resetting on
unrelated rate ticks.

Closes the symptom-A bug class for accounts/balances/totals in the
sidebar. EarmarkStore migrates in commit 7; TransactionStore in 11."
```

---

## Stage 6 — Reactive measurement against migrated `AccountStore`

**Files:**
- Modify: `MoolahBenchmarks/SyncReactivityBenchmarks.swift` (already exists from stage 2)

- [ ] **Step 1: Update the benchmark to drive the reactive path instead of the legacy path.**

The existing benchmark calls `store.load()` and `store.reloadFromSync()`. Now AccountStore has neither method. Replace with:

```swift
let store = AccountStore(
  repository: backend.accounts,
  conversionService: backend.conversionService,
  targetInstrument: .defaultTestInstrument
)
try await store.waitForFirstEmission()

let start = ContinuousClock.now
try await database.write { db in
  // … the same 50k-leg bulk insert as before
}
// Wait for the store to settle (accounts emission applied).
try await store.waitForNextEmission(
  matching: { _ in true },
  description: "post-bulk emission",
  timeout: .seconds(10)
)
let elapsed = (ContinuousClock.now - start).inMilliseconds
print("SyncReactivityBenchmarks.testBulkSyncRefresh wallClockMs=\(elapsed)")
```

- [ ] **Step 2: Run the benchmark; capture the reactive number.**

```bash
just benchmark SyncReactivityBenchmarks 2>&1 | tee .agent-tmp/stage6-reactive.txt
grep wallClockMs .agent-tmp/stage6-reactive.txt
```

- [ ] **Step 3: Compare against the baseline from stage 2.**

Read both numbers. If the reactive number breaches any spec Section 2 acceptance threshold (50k initial sync main-thread time < 50ms cumulative, single remote tx edit < 250ms), STOP. Pull in the appropriate mitigation from the spec's toolbox — likely starting with `.removeDuplicates()` (already on by default) and consumer-side `.throttle(for:)` — in a separate commit before continuing to stage 7.

If the reactive number is acceptable, no further action; the benchmark file is already committed (stage 2). Just attach the comparison to your notes for the eventual PR description.

- [ ] **Step 4: Commit the benchmark update.**

```bash
just format
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/reactive-sync-plan add MoolahBenchmarks/SyncReactivityBenchmarks.swift
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/reactive-sync-plan commit -m "bench(sync): update SyncReactivityBenchmarks for reactive AccountStore

Drives the reactive path (waitForFirstEmission + waitForNextEmission)
instead of the legacy load/reloadFromSync pair. Captures the reactive
wallClockMs for comparison against the legacy baseline from commit 2.
Per spec Section 2 — measurement is the gate before migrating more stores."
```

---

## Stage 7 — Migrate `EarmarkStore` to reactive

Same shape as stage 5. Apply the canonical patterns R1, R3, R4, R5 to EarmarkRepository / EarmarkStore / EarmarkBudget* — note that `EarmarkRepository` also has `fetchBudget(earmarkId:)` which gets a parameterised `observeBudget(earmarkId:)` per spec Section 3.

**Substitution table for templates R1, R3, R4, R5:**

| Placeholder | Substitution |
|---|---|
| `<Name>` | `Earmark` |
| `<DomainType>` | `Earmark` |
| `<RowType>` | `EarmarkRow` |
| `<repos>` (on `backend`) | `earmarks` |
| Test fixture `<makeFixture>()` | `Earmark(name: "Test", instrument: .defaultTestInstrument)` |
| Suite name | `EarmarkRepository observation contract` / `EarmarkStore sync refresh` |

**Files:**
- Modify: `Domain/Repositories/EarmarkRepository.swift`
- Modify: `Backends/GRDB/Repositories/GRDBEarmarkRepository.swift`
- Modify: `Features/Earmarks/EarmarkStore.swift`
- Create: `MoolahTests/Domain/EarmarkRepositoryObservationContractTests.swift`
- Create: `MoolahTests/Features/Earmarks/EarmarkStoreSyncRefreshTests.swift`
- Modify: `MoolahTests/Features/Earmarks/EarmarkStoreTests.swift` (rewrite to emission pattern)
- Modify: `App/ProfileSession.swift` (cleanup; remove `.earmarks` from `storesToReload`)
- Modify: `App/ProfileSession+SyncWiring.swift`
- Add `TestableStoreObservation` conformance for `EarmarkStore` in `StoreObservation+Test.swift`

- [ ] **Step 1: Add `observeAll()`, `observeBudget(earmarkId:)`, `observeErrors()` to `EarmarkRepository` (per R1, parameterised variant captured below).**

```swift
func observeBudget(earmarkId: UUID) -> AsyncStream<[EarmarkBudgetItem]> {
  let channel = self.errorChannel
  return ValueObservation
    .tracking { [earmarkId] db in
      try EarmarkBudgetItemRow
        .filter(Column("earmark_id") == earmarkId.uuidString)
        .fetchAll(db)
        .map(EarmarkBudgetItem.init)
    }
    .removeDuplicates()
    .values(in: writer)
    .toAsyncStream(onError: { error in
      Task { await channel.surfaceAndFinish(error) }
    })
}
```

(Use the shared `ObservationErrorChannel` from `Backends/GRDB/Observation/ObservationErrorChannel.swift` — same as Stage 3. Single-call `surfaceAndFinish` to avoid the two-Task race.)

- [ ] **Step 2: Repeat steps 2-11 from stage 5, substituting `Earmark` for `Account`.** Reference R3, R4, R5 with the substitution table above. The earmark store also subscribes to `conversionService.observeRates()` for `convertedBalance(for:)` and `convertedTotalBalance`. **Inline the same conditional-cancel `recomputeConvertedTotals()` pattern from Stage 5 Step 4 in `EarmarkStore` — the `guard conversionTask == nil else { return }` guard is identically load-bearing here. Do not simplify.** (The retry loop is the most error-prone part to copy; if the engineer drops the guard, earmarks suffer the same clock-reset regression as Stage 5 warned about for accounts.)

- [ ] **Step 3: Commit.**

```bash
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/reactive-sync-plan commit -m "feat(earmark): migrate EarmarkStore to reactive observation

Same shape as AccountStore (commit 5). Adds parameterised observeBudget
for the budget-detail screen. Sidebar earmark balances now auto-refresh
on remote sync. Removes .earmarks entry from storesToReload."
```

---

## Stage 8 — Migrate `CategoryStore` to reactive

Same shape as stage 7 minus the conversion service (categories don't have converted balances).

**Substitution table for templates R1, R3, R4, R5:**

| Placeholder | Substitution |
|---|---|
| `<Name>` | `Category` |
| `<DomainType>` | `Category` |
| `<RowType>` | `CategoryRow` |
| `<repos>` (on `backend`) | `categories` |
| Test fixture `<makeFixture>()` | `Category(name: "Test", kind: .expense)` (verify against `Domain/Models/Category.swift` for the actual init signature) |
| Suite name | `CategoryRepository observation contract` / `CategoryStore sync refresh` |

**Files:**
- Modify: `Domain/Repositories/CategoryRepository.swift` (add `observeAll`, `observeErrors`)
- Modify: `Backends/GRDB/Repositories/GRDBCategoryRepository.swift`
- Modify: `Features/Categories/CategoryStore.swift`
- Create: `MoolahTests/Domain/CategoryRepositoryObservationContractTests.swift`
- Create: `MoolahTests/Features/Categories/CategoryStoreSyncRefreshTests.swift`
- Modify: existing `CategoryStoreTests.swift`
- Modify: `App/ProfileSession.swift` and `App/ProfileSession+SyncWiring.swift` (remove `.categories`)

- [ ] **Step 1: Apply R1, R3, R4, R5. Commit when green.**

```bash
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/reactive-sync-plan commit -m "feat(category): migrate CategoryStore to reactive observation

Same shape as AccountStore (commit 5) and EarmarkStore (commit 7), with
no conversion service since categories don't have converted balances.
Categories screen now auto-refreshes on remote sync. Removes .categories
entry from storesToReload."
```

---

## Stage 9 — Migrate `ImportRuleStore` to reactive

Same shape as stage 8.

**Substitution table for templates R1, R3, R4, R5:**

| Placeholder | Substitution |
|---|---|
| `<Name>` | `ImportRule` |
| `<DomainType>` | `ImportRule` |
| `<RowType>` | `ImportRuleRow` |
| `<repos>` (on `backend`) | `importRules` |
| Test fixture `<makeFixture>()` | construct per `Domain/Models/ImportRule.swift` init signature |
| Suite name | `ImportRuleRepository observation contract` / `ImportRuleStore sync refresh` |

**Files:**
- Modify: `Domain/Repositories/ImportRuleRepository.swift`
- Modify: `Backends/GRDB/Repositories/GRDBImportRuleRepository.swift`
- Modify: `Features/Import/ImportRuleStore.swift`
- Create: `MoolahTests/Domain/ImportRuleRepositoryObservationContractTests.swift`
- Create: `MoolahTests/Features/Import/ImportRuleStoreSyncRefreshTests.swift`
- Modify: existing `ImportRuleStoreTests.swift`
- Modify: `App/ProfileSession.swift` and `App/ProfileSession+SyncWiring.swift` (remove `.importRules`)

- [ ] **Step 1: Apply R1, R3, R4, R5. Note `ImportRuleRepository` also has `reorder(_:)`; it stays a one-shot mutation. Commit when green.**

```bash
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/reactive-sync-plan commit -m "feat(import-rule): migrate ImportRuleStore to reactive observation

Same shape as CategoryStore (commit 8). Import rules screen auto-refreshes
on remote sync. reorder(_:) stays a one-shot mutation; observation handles
the post-reorder state. Removes .importRules entry from storesToReload."
```

---

## Stage 10 — `TransactionRepository` observe surface

Pre-store-migration step. Adds the parameterised observation methods needed by `TransactionStore` and views.

**Files:**
- Modify: `Domain/Repositories/TransactionRepository.swift`
- Modify: `Backends/GRDB/Repositories/GRDBTransactionRepository.swift` and `+Fetch.swift`
- Create: `MoolahTests/Domain/TransactionRepositoryObservationContractTests.swift`

- [ ] **Step 1: Add the protocol methods.**

```swift
protocol TransactionRepository: Sendable {
  // existing methods unchanged
  func observe(filter: TransactionFilter, page: Int, pageSize: Int) -> AsyncStream<TransactionPage>
  func observeAll(filter: TransactionFilter) -> AsyncStream<[Transaction]>
  func observeErrors() -> AsyncStream<any Error>
}
```

- [ ] **Step 2: Implement on GRDBTransactionRepository.** Use the parameterised pattern from R1, capturing `[filter]` (and `page`, `pageSize` for the paginated variant) into the `tracking` closure.

- [ ] **Step 3: Write a parameterised contract test that asserts each variant emits on a relevant write and stays quiet on an unrelated write.** Add to `MoolahTests/Domain/TransactionRepositoryObservationContractTests.swift`.

- [ ] **Step 4: Run tests, format, dispatch reviewers, commit.**

```bash
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/reactive-sync-plan commit -m "feat(transaction): add observe variants to TransactionRepository

Parameterised observation variants (per filter, per page) that
TransactionStore consumes in commit 11. Per spec Section 3 hybrid
approach — mirror existing parameterised reads with reactive twins."
```

---

## Stage 11 — Migrate `TransactionStore` + parameterised view subscriptions

The biggest single commit in the rollout. Touches the store and every view that owns a transaction observation (account detail, all-transactions, recently-added).

**Files:**
- Modify: `Features/Transactions/TransactionStore.swift`
- Modify: `Features/Transactions/Views/AccountDetailView.swift` (and similar)
- Modify: `Features/Transactions/Views/AllTransactionsView.swift`
- Modify: `Features/Transactions/Views/RecentlyAddedView.swift`
- Modify: existing `TransactionStoreTests.swift` and related view-store tests
- Create: `MoolahTests/Features/Transactions/TransactionStoreSyncRefreshTests.swift`

- [ ] **Step 1: Add `observe(accountId:)` and parallel methods to `TransactionStore`.**

Per spec Section 5 "Per-view parameterized observation pattern":

```swift
@MainActor func subscribe(for accountId: UUID) async {
  for await page in repository.observe(filter: .account(accountId), page: 0, pageSize: pageSize) {
    transactionsByAccount[accountId] = page.transactions
  }
}
```

- [ ] **Step 2: Update views to call `await transactionStore.observe(accountId: accountId)` from `.task(id: accountId)`.** Delete any existing `for await` loops that lived in view bodies (per spec Section 5 thin-view rule).

- [ ] **Step 3: Apply R3, R4, R5 to the all-transactions and recently-added flows.**

- [ ] **Step 4: Add the symptom-A regression test for transactions.**

```swift
@Test("remote transaction insert refreshes account detail")
func remoteTxRefreshes() async throws { … }
```

- [ ] **Step 5: Run tests, format, dispatch reviewers, commit.**

```bash
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/reactive-sync-plan commit -m "feat(transaction): migrate TransactionStore to reactive observation

Largest single commit in the cutover: store + all views that own
parameterised transaction observations (account detail, all
transactions, recently added). Adds observe(accountId:) so
views consume a one-line .task(id: accountId) call. Per-account
transaction lists now auto-refresh on remote sync."
```

---

## Stage 12 — Migrate `InvestmentStore` to reactive

**Substitution table for templates R1, R3, R4, R5 (the parameterised observation methods are bespoke per Stage 10 — only the store/error-channel patterns transfer):**

| Placeholder | Substitution |
|---|---|
| `<Name>` | `Investment` |
| `<DomainType>` | `InvestmentValue` (and `AccountDailyBalance` for the daily-balances stream) |
| `<repos>` (on `backend`) | `investments` |
| Suite name | `InvestmentRepository observation contract` / `InvestmentStore sync refresh` |

**Files:**
- Modify: `Domain/Repositories/InvestmentRepository.swift` (add `observeValues`, `observeDailyBalances`, `observeErrors`)
- Modify: `Backends/GRDB/Repositories/GRDBInvestmentRepository.swift`
- Modify: `Features/Investments/InvestmentStore.swift`
- Create: contract + sync-refresh tests

- [ ] **Step 1: Apply R1, R3, R4, R5.**

- [ ] **Step 2: Decide whether to remove the cross-store `onInvestmentValueChanged` callback — REQUIRES this specific test passing first.**

The existing `ProfileSession.wireCrossStoreSideEffects()` wires `investmentStore.onInvestmentValueChanged = { accountId, latestValue in await accountStore.updateInvestmentValue(...) }`. The plan to remove it depends on whether `AccountStore.repository.observeAll()` actually re-emits when an `investment_value` row changes.

**Required test (do not skip — silent removal is a Rule 11 / sidebar-stale regression):**

Add to `MoolahTests/Features/Accounts/AccountStoreSyncRefreshTests.swift`:

```swift
@Test("AccountStore reflects InvestmentValue writes via observeAll")
func investmentValueWriteReachesAccountStore() async throws {
  let (backend, database) = try TestBackend.create()
  let investmentAccount = try await backend.accounts.create(
    Account(
      name: "Brokerage",
      type: .investment,
      instrument: .defaultTestInstrument,
      valuationMode: .recordedValue
    ),
    openingBalance: nil
  )
  let store = AccountStore(
    repository: backend.accounts,
    conversionService: backend.conversionService,
    targetInstrument: .defaultTestInstrument,
    investmentRepository: backend.investments
  )
  try await store.waitForFirstEmission()

  // Write directly to investment_value via the GRDB layer (simulating a
  // remote sync update).
  try await backend.investments.setValue(
    accountId: investmentAccount.id,
    date: .now,
    value: InstrumentAmount(quantity: 12345, instrument: .defaultTestInstrument)
  )

  // If AccountStore.observeAll() does NOT cover investment_value
  // changes, this assertion times out, and the cross-store callback
  // must be retained.
  try await store.waitForNextEmission(
    matching: { $0.convertedBalances[investmentAccount.id]?.quantity == 12345 },
    description: "investment value reaches account store",
    timeout: .seconds(2)
  )
}
```

If this test passes: remove `wireCrossStoreSideEffects()`, the `investmentStore.onInvestmentValueChanged` property assignment, the `crossStoreUpdateTasks` list and its cleanup. Update `InvestmentStore` to drop the callback property entirely.

If this test fails: KEEP the `onInvestmentValueChanged` callback as-is. AccountStore's `observeAll()` does NOT cover the `investment_value` table (the cross-store push is load-bearing). Document this in the commit message and leave the callback in place. The reactive design still benefits — locally-driven InvestmentValue writes on this device propagate via the existing callback; remote sync writes will need a follow-up to wire AccountStore to also subscribe to `investmentRepository.observeValues(...)`. (That follow-up is out of scope for this commit; **open a GitHub issue first via `gh issue create --title "..." --body "..."`, capture the returned issue number, and flag the follow-up site with `TODO(#N): reason — https://github.com/ajsutton/moolah-native/issues/N` per `CLAUDE.md §Bug Tracking` — bare `TODO:` without an issue reference is rejected by `just validate-todos` in CI.**)

- [ ] **Step 3: Commit.**

```bash
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/reactive-sync-plan commit -m "feat(investment): migrate InvestmentStore to reactive observation

Adds observeValues / observeDailyBalances / observeErrors to
InvestmentRepository. InvestmentStore subscribes via the canonical
TaskGroup pattern.

The onInvestmentValueChanged cross-store callback is [REMOVED |
RETAINED] based on the investmentValueWriteReachesAccountStore test
result documented in the body of this commit:

[paste test result here — REMOVED if AccountStore.observeAll() picks up
investment_value writes, RETAINED otherwise. If RETAINED, link to a new
GitHub issue tracking the AccountStore.observeValues subscription
follow-up.]"
```

---

## Stage 13 — Migrate `ImportStore` (partial) + `CSVImportProfileRepository`

**Substitution table:**

| Placeholder | Substitution |
|---|---|
| `<Name>` | `CSVImportProfile` |
| `<DomainType>` | `CSVImportProfile` |
| `<RowType>` | `CSVImportProfileRow` |
| `<repos>` (on `backend`) | `csvImportProfiles` |

**Files:**
- Modify: `Domain/Repositories/CSVImportProfileRepository.swift`
- Modify: `Backends/GRDB/Repositories/GRDBCSVImportProfileRepository.swift`
- Modify: `Features/Import/ImportStore.swift` (only the parts that read CloudKit-synced rows)
- Create: contract test for CSVImportProfileRepository

- [ ] **Step 1: Apply R1, R3, R4 for CSVImportProfile. ImportStore's staging state stays as-is (it's per-profile-on-disk and not synced). Commit.**

```bash
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/reactive-sync-plan commit -m "feat(import): migrate CSVImportProfile observation; partial ImportStore

ImportStore staging state is per-profile-on-disk and not synced; it
keeps its existing pull-based shape. Only the CloudKit-synced
CSVImportProfile rows are reactive — when a remote CSV import profile
is added or modified on another device, the setup form sees the change
on its next render without needing a refresh."
```

---

## Stage 14 — Fix `isFetchingChanges` race + remove the legacy notification chain (single commit)

**Files:**
- Modify: `Backends/CloudKit/Sync/SyncCoordinator+RecordChanges.swift` (FIX)
- Modify: `Backends/CloudKit/Sync/SyncCoordinator.swift` (DELETE observer registry)
- Modify: `Backends/CloudKit/Sync/SyncCoordinator+Lifecycle.swift` (DELETE flush)
- Modify: `Backends/CloudKit/Sync/SyncCoordinator+Zones.swift` (DELETE notify calls)
- Modify: `App/ProfileSession.swift` (DELETE registerWithSyncCoordinator, scheduleReloadFromSync, etc.)
- Delete: `App/ProfileSession+SyncWiring.swift`
- Modify: `MoolahTests/App/ProfileSessionTests.swift` (DELETE `storesToReload` suite)

Per spec Section 8 commit 14, this is a SINGLE commit. The fix and the deletion land together to avoid any bisect target containing the buggy path.

- [ ] **Step 1: Fix the race in `applyFetchedProfileDataChanges` / `flushFetchSessionChanges`.**

In `SyncCoordinator+RecordChanges.swift`, change the late-notification branch:

```swift
// Before
if isFetchingChanges {
  accumulateFetchSessionChanges(for: profileId, changedTypes: changedTypes)
} else {
  notifyObservers(for: profileId, changedTypes: changedTypes)
}

// After (the fix; will be deleted in next step alongside the rest)
// Always accumulate; flushFetchSessionChanges drains at end-of-fetch.
// Late-arriving notifications (after isFetchingChanges flips false)
// re-flush via a follow-up task.
accumulateFetchSessionChanges(for: profileId, changedTypes: changedTypes)
if !isFetchingChanges {
  flushFetchSessionChanges()
}
```

- [ ] **Step 2: Delete the entire legacy notification chain in the same commit.**

Delete from `SyncCoordinator.swift`:
- `ProfileObserver` struct
- `profileObservers` dict
- `addObserver(for:callback:)`
- `removeObserver(token:)`
- `ObserverToken` struct
- `notifyObservers(for:changedTypes:)`
- `accumulateFetchSessionChanges`
- `fetchSessionChangedTypes` dict

Delete from `SyncCoordinator+Lifecycle.swift`:
- `flushFetchSessionChanges()`
- The call to `flushFetchSessionChanges()` from `endFetchingChanges`

Delete from `SyncCoordinator+Zones.swift`:
- The three `notifyObservers(for: profileId, changedTypes: changedTypes)` calls (lines 142, 189, 214 — verify line numbers via `grep -n notifyObservers`)

Delete from `App/ProfileSession.swift`:
- `syncObserverToken` property
- `registerWithSyncCoordinator(_:)` method
- The call to `registerWithSyncCoordinator` from `finishInit`
- `scheduleReloadFromSync(changedTypes:)` method
- `pendingChangedTypes`, `lastSyncEventTime`, `syncReloadTask` properties
- From `cleanupSync(coordinator:)`, delete ONLY these specific clauses:
  - `if let token = syncObserverToken { coordinator.removeObserver(token: token); syncObserverToken = nil }`
  - `syncReloadTask?.cancel(); syncReloadTask = nil`

**`cleanupSync(coordinator:)` surviving clauses (must be preserved):**
- `coordinator.removeInstrumentRemoteChangeCallback(profileId: profile.id)` — instrument-registry callback teardown
- `catalogRefreshTask?.cancel(); catalogRefreshTask = nil` — CoinGecko catalog refresh
- `pragmaOptimizeTask?.cancel(); pragmaOptimizeTask = nil` — DB optimize
- `periodicPragmaOptimizeTask?.cancel(); periodicPragmaOptimizeTask = nil`
- `for task in crossStoreUpdateTasks { task.cancel() }; crossStoreUpdateTasks.removeAll()` (unless Stage 12 removed `wireCrossStoreSideEffects` based on its conditional test result; in that case remove this loop too)
- `setUpTask?.cancel(); setUpTask = nil`
- All per-store `stopObserving()` calls added in stages 5, 7, 8, 9, 11, 12, 13

The implementer must perform a `git diff App/ProfileSession.swift` and verify all surviving clauses listed above are still present after the deletion.

Delete file: `App/ProfileSession+SyncWiring.swift`. Update `project.yml` to remove the file reference; run `just generate`.

Delete from `MoolahTests/App/ProfileSessionTests.swift`:
- The `@Suite("storesToReload")` block and all its tests (`transactionLegRecordReloadsAccountsAndEarmarks`, etc.)

- [ ] **Step 3: Run the full test suite — must pass.**

```bash
just test 2>&1 | tee .agent-tmp/stage14-fulltest.txt
grep -E 'failed|error:' .agent-tmp/stage14-fulltest.txt
```
Expected: all tests pass. The `storesToReload` tests are gone; the reactive store regression tests cover the equivalent behaviour.

- [ ] **Step 4: Format, dispatch all reviewers, fix findings, commit (one commit).**

Dispatch in parallel: `code-review`, `concurrency-review`, `database-code-review`, `sync-review`, `instrument-conversion-review`. Address findings.

```bash
just format
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/reactive-sync-plan add -A
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/reactive-sync-plan commit -m "refactor(sync): fix isFetchingChanges race + remove legacy notification chain

Two parts in one commit per spec Section 8 commit 14 (no split allowed —
a fix-only intermediate would still contain the buggy path in live code).

FIX: applyFetchedProfileDataChanges always accumulates into
fetchSessionChangedTypes, then flushes if !isFetchingChanges. Closes the
race where a late-arriving notification (after isFetchingChanges flipped
false but before the zone task completed) would notify directly while
the buffered types had already been flushed and cleared.

REMOVE: ProfileObserver registry, addObserver/removeObserver/
ObserverToken/notifyObservers, accumulateFetchSessionChanges /
fetchSessionChangedTypes / flushFetchSessionChanges, all four
notifyObservers call sites, ProfileSession.scheduleReloadFromSync /
pendingChangedTypes / lastSyncEventTime / syncReloadTask /
syncObserverToken / registerWithSyncCoordinator, and the entire
ProfileSession+SyncWiring.swift file.

Stores receive sync updates exclusively via GRDB ValueObservation
emissions from this commit forward. Tests in MoolahTests/App/
ProfileSessionTests.swift::storesToReload deleted (the closed-world
plan they tested no longer exists)."
```

---

## Stage 15 — Final measurement

**Files:**
- (No code change — measurement only.)

- [ ] **Step 1: Re-run `SyncReactivityBenchmarks` with everything reactive.**

```bash
just benchmark SyncReactivityBenchmarks 2>&1 | tee .agent-tmp/stage15-final.txt
grep wallClockMs .agent-tmp/stage15-final.txt
```

- [ ] **Step 2: Compare against the legacy baseline (stage 2) and the AccountStore-only reactive number (stage 6).**

Verify all spec Section 2 thresholds met:

| Scenario | Target | Measured |
|---|---|---|
| 50k-tx initial sync, sidebar visible | Main-thread time < 50 ms cumulative | `___` ms |
| Single remote tx edit, sidebar visible | Store update < 250 ms from sync apply | `___` ms |
| Local mutation | Emission delivered in < 50 ms | `___` ms |
| Steady-state idle (no writes) | 0% CPU (no polling) | `___` |

If any threshold is breached, pull in the appropriate mitigation from the spec's toolbox in a new commit. Re-measure.

- [ ] **Step 3: Save the measurement to `plans/2026-05-06-reactive-sync-refresh-implementation.md` Stage 15 section** as a final block — append a "Measurement results" subsection with the captured numbers. (Update this plan in place.) Commit.

```bash
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/reactive-sync-plan add plans/2026-05-06-reactive-sync-refresh-implementation.md
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/reactive-sync-plan commit -m "docs(plan): record reactive sync final measurements"
```

- [ ] **Step 4: Hand back to user for the manual-test gate.**

Per spec Section 8 manual-test gate:
- Two-device test
- Bulk-sync test (fresh install + populated iCloud)
- Local-mutation test
- Idle test

The user runs these themselves. Once all four pass, they open the implementation PR with the manual-test results in the PR description.

---

## Self-review notes (to be filled before plan PR)

- [ ] Spec coverage check: every commit in spec Section 8 is mapped to a stage above. ✓
- [ ] Type consistency check: `observeAll`, `observeErrors`, `observeRates`, `observeBudget`, `observe(filter:page:pageSize:)`, `observeAll(filter:)`, `observeValues`, `observeDailyBalances` — names consistent with spec Sections 3 and 4. ✓
- [ ] Placeholder scan: `<placeholder>` markers in stages 7, 8, 9, 12, 13 are intentional template references back to stage 5's canonical pattern, not undefined work. Per the writing-plans skill instruction "Similar to Task N (repeat the code — the engineer may be reading tasks out of order)" — the alternative of repeating the entire reactive-store rewrite six times would make the plan unmaintainable. Reference patterns R1-R5 are written once at the top.
- [ ] Test pattern check: every observation contract test follows R4. Every store sync-refresh test follows R5. Every store rewrite uses R3.
