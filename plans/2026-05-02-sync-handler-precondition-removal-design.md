# Sync Handler Precondition Removal — Design

**Issue:** [#619](https://github.com/ajsutton/moolah-native/issues/619) — Sync handler trap fires for un-sessionized profiles outside the migration window.

## 1. Problem

`SyncCoordinator.handlerForProfileZone(profileId:zoneID:)` requires a per-profile `ProfileGRDBRepositories` bundle to have been registered before it is called. Today, the registration is owned by `ProfileSession.registerWithSyncCoordinator`, which only runs when a session is constructed. Sessions are built lazily by `SessionManager.session(for:)` during view rendering. CKSyncEngine, by contrast, can deliver events for any profile that exists in the index, regardless of which window is open.

The mismatch produces three reachable failure modes:

1. **Migration race.** Profile-index migration still in flight when sync starts; `ProfileStore.profiles` is empty; no session built; trap fires. Mitigated by [#620](https://github.com/ajsutton/moolah-native/pull/620), which gates engine start on the index migration.
2. **Multi-profile, non-active push.** User has profiles A/B/C; only A's window is open; another device writes to B; CKSyncEngine fetches for B; no session for B; trap fires.
3. **Single-profile pre-render race.** Profile exists in the index but `ProfileWindowView` hasn't rendered; the engine wins the race; trap fires.

A second symptom of the same gap surfaces in `handleEncryptedDataReset` (`SyncCoordinator+Zones.swift:239`): when iCloud rotates encryption keys for a zone whose session isn't registered, `try?` silently skips `clearAllSystemFields()`. Records keep stale `encodedSystemFields`; the startup backfill scan only re-queues records where `encodedSystemFields == nil`, so they are never re-uploaded — sync update loss.

## 2. Goal

Eliminate the entire class of "sync event arrives for an un-sessionized profile" errors. The fix should be impossible to regress: future code paths cannot reintroduce the trap because the precondition that caused it should no longer exist.

### Non-goals

- Reworking `instrumentRemoteChangeCallbacks` registration. Its session-scoped lifecycle is correct (no session = no live UI subscribers = nothing to notify).
- Reworking `setProfileGRDBRepositories`'s sibling `addObserver` registration. That observer drives `scheduleReloadFromSync` which does need a live session; absence is correct.
- Per-profile UI eagerness. Stores, services, file watchers, etc. continue to be built lazily on first profile open.

## 3. Design

### 3.1 Make `SyncCoordinator` self-sufficient for handler construction

Today, `handlerForProfileZone` consults a per-profile bundle that an external caller must have registered:

```swift
// current
if let registered = profileGRDBRepositories[profileId] {
  grdbRepositories = registered
} else if let factory = fallbackGRDBRepositoriesFactory {
  grdbRepositories = try factory(profileId)
  profileGRDBRepositories[profileId] = grdbRepositories
} else {
  preconditionFailure("…wiring bug…")
}
```

After: the coordinator builds the bundle itself, on demand, from `containerManager.database(for: profileId)` (the per-profile GRDB queue, which is process-wide cached). All ten GRDB repositories share the same constructor shape — `init(database:, onRecordChanged:, onRecordDeleted:)` — and the apply path uses synchronous `applyRemoteChangesSync` entry points that never invoke the hooks. So the coordinator's bundle uses the no-op hook defaults and is functionally indistinguishable from the session's bundle for everything the apply path does.

```swift
// proposed
let grdbRepositories = try makeGRDBRepositories(for: profileId)
```

`makeGRDBRepositories(for:)` is a private helper on `SyncCoordinator` that:
1. Calls `containerManager.database(for: profileId)` to get (and migrate) the GRDB queue.
2. Constructs a fresh `ProfileGRDBRepositories` value with default no-op hooks.
3. Returns it. Caching of the resulting `ProfileDataSyncHandler` continues via `dataHandlers[profileId]` exactly as today.

### 3.2 Delete the registration surface

Once the coordinator is self-sufficient, the entire registration mechanism becomes vestigial:

- `SyncCoordinator.profileGRDBRepositories: [UUID: ProfileGRDBRepositories]` — delete.
- `SyncCoordinator.fallbackGRDBRepositoriesFactory` and the corresponding `init` parameter — delete.
- `SyncCoordinator.setProfileGRDBRepositories(profileId:bundle:)` — delete.
- `SyncCoordinator.removeProfileGRDBRepositories(profileId:)` — delete.
- `ProfileSession.wireRepositorySync(coordinator:)` and `registerGRDBRepositoriesForSync(coordinator:)` — delete (the call site in `registerWithSyncCoordinator` becomes a no-op and is removed).
- The `cleanupSync` call to `coordinator.removeProfileGRDBRepositories(profileId:)` — delete.
- `handlerForProfileZone` becomes non-throwing again (the `SyncCoordinatorError.profileNotRegistered` path PR #620 introduced disappears). The `try?`/`try` mix at every call site collapses back to a direct call.

`SyncCoordinatorError.profileNotRegistered` itself goes away. If it has no remaining cases the enum is removed; if it has other cases it stays minus that one.

### 3.3 Two-instance audit

The session continues to own its own `ProfileGRDBRepositories` (through `CloudKitBackend`) with real hooks for queueing CKSyncEngine on user mutations. The coordinator owns its own bundle for sync apply with no-op hooks. Both share the same `DatabaseQueue`. Confirmed equivalences:

| Concern | Today | After |
|---|---|---|
| User mutation queues upload | Session bundle's hooks fire from `upsert`/`delete` | Unchanged |
| Sync apply does not echo | `applyRemoteChangesSync` does not invoke hooks | Unchanged (coordinator's no-op hooks would also be silent if invoked) |
| Database serialisation | One queue per profile via `containerManager.database(for:)` | Unchanged |
| Instrument-registry subscriber notification on remote pull | `onInstrumentRemoteChange` callback bridges from coordinator → session's live registry | Unchanged |
| Schema migrations | Run on first `database(for:)` call | Unchanged (coordinator may now be the first caller) |

### 3.4 Lifecycle simplification

`ProfileSession.registerWithSyncCoordinator` shrinks to just observer registration plus the instrument-change callback. The "must be the last statement of init / call order guarantees the race is won" comment in `wireRepositorySync` is removed along with the function.

`SyncCoordinator.startAfter(profileIndexMigration:)` (introduced by PR #620) becomes unnecessary on the trap-prevention axis. Whether it stays for other reasons is decided in §6.

### 3.5 Migrator: stop clobbering sync-applied rows

`SwiftDataToGRDBMigrator` runs from `ProfileSession.setUp()` (background task scheduled after `init`) and copies SwiftData rows into GRDB via `upsert`. Today the trap blocks sync apply for un-sessionized profiles, so the migrator is the only writer at the time it runs. With the trap gone, sync can write to GRDB for a profile before the user opens it. When the user later opens the session and the migrator runs, `upsert` overwrites GRDB rows with potentially-older SwiftData data — including the cached `encodedSystemFields` blob, which can also kick a `.serverRecordChanged` cycle.

**Fix:** swap `upsert` for `INSERT … ON CONFLICT(id) DO NOTHING` (GRDB's `insert(_:onConflict: .ignore)`) in every per-type migrator. Semantics: if the row already exists in GRDB, leave it alone — sync put it there with newer truth. The per-type "migration complete" `UserDefaults` flag still latches once the pass finishes, so the migrator continues to no-op on subsequent launches; idempotency is preserved.

This change applies to every migrator under `Backends/GRDB/Migration/SwiftDataToGRDBMigrator+*.swift` (CSVImportProfile, ImportRule, Instruments, Categories, Accounts, Earmarks, EarmarkBudgetItems, InvestmentValues, Transactions, TransactionLegs, ProfileIndex). The profile-index migrator is included for symmetry — although its window is closed by PR #620's gate, behavioural consistency across migrators is worth more than the ten-line diff.

### 3.6 What stays in PR #620

PR #620's index-migration gate is no longer necessary to prevent the trap. But it does provide a separate property: it ensures `ProfileStore.profiles` is populated before the engine starts probing zones, so observability and progress UI see a consistent state. We keep the gate. We delete the precondition-failure split inside `handlerForProfileZone` (the throws-vs-precondition refactor) since the underlying error case is gone.

## 4. Test plan

New / updated unit tests in `MoolahTests`:

- **Apply without session.** Construct a `SyncCoordinator` against an in-memory `ProfileContainerManager`, never construct any `ProfileSession`, call the apply path with a synthetic batch for a profile id present in the index. Assert: rows land in GRDB, no trap.
- **Encrypted reset without session.** Same setup; trigger `handleEncryptedDataReset` for a profile zone with no session. Assert: `clearAllSystemFields()` ran (verify by reading rows back) and the records were re-queued.
- **Multi-profile background apply.** Index has profiles A and B; only A has a `ProfileSession`; deliver an apply batch for B. Assert: B's GRDB rows updated; A's session unaffected.
- **Migrator does not clobber.** Seed GRDB with a row for id X. Run the migrator with a SwiftData row for id X carrying a *different* `encodedSystemFields`. Assert: GRDB's row is untouched; flag latches.
- **Migrator still seeds empty tables.** Seed SwiftData only; GRDB empty. Run migrator. Assert: rows present; flag latches.

Removal of test scaffolding:

- `fallbackGRDBRepositoriesFactory` parameter usage in test helpers (`MoolahTests/Support/ProfileDataSyncHandlerTestSupport.swift` and the two `MoolahBenchmarks` files) — the helpers stop injecting it; the benchmarks already construct in-memory `ProfileContainerManager`s.

## 5. Migration / rollout

No data migration. No user-visible behaviour change. All deletions are internal.

For the in-flight v1 SwiftData → v2 GRDB upgrade window: §3.5's migrator change closes the data-loss exposure that Option B would otherwise open. Users who have already migrated (flags latched) are unaffected by either change.

## 6. Considered alternatives

- **Option A — Eager session construction.** Wire `ProfileStore` to call `sessionManager.session(for:)` whenever profiles arrive. Keeps the registration contract and ensures it is always satisfied. Rejected because it pays the cost of building 10+ stores, 3 rate services, FolderWatch, the migration task, and the hourly PRAGMA optimize tick for every profile at launch — including profiles the user may never open this session — and because the fragile precondition would survive the change, leaving the door open for a future wiring bug to reintroduce the trap.
- **Option C — Defer engine start until every profile has a session.** Strictly worse than A: same cost, plus user-visible sync delay.
- **Migrator switches to "skip if any GRDB row exists."** Brittle when migration is interrupted partway; the next launch could see a non-empty table and conclude no work is needed despite missing rows. Rejected.

## 7. Out of scope

- Restructuring `instrumentRemoteChangeCallbacks` to a session-agnostic broadcast (Notification / AsyncStream). The session-scoped registration is already correct on the no-session path; not a bug.
- General observability cleanup of stale `dataHandlers` entries on profile delete. Pre-existing edge case; harmless dangling references; tracked separately if/when it manifests.
