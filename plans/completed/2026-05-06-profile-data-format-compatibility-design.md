# Profile data-format compatibility gate — design

**Issue:** [#764](https://github.com/ajsutton/moolah-native/issues/764)
**Status:** Design — pending implementation plan.
**Owner:** Adrian Sutton.
**Date:** 2026-05-06.

## Problem

The app has no version-aware compatibility check between the running build and the profile it's about to read or sync. Today's defensive decoding (e.g. unknown `AccountType` falls back to `.asset`) keeps a few paths from crashing but silently degrades data and offers no signal to the user. Risk modes are crash, incorrect behaviour (a new transaction type aggregated under the wrong category), and data corruption (an older build round-trips a record it didn't fully understand).

The crypto-wallet foundation (PR [#748](https://github.com/ajsutton/moolah-native/pull/748)) just shipped the first meaningfully-versioned change in a series. We need a real gate before more lands.

## Goal

Before opening a profile, detect that its data format is newer than this build supports. When it is:

1. Block reads and writes (no `ProfileSession` is constructed).
2. Don't start CKSyncEngine for that profile's zone.
3. Show "Update Moolah to Continue" with an App Store / GitHub Releases link.
4. Let the user switch to a different profile.

## Non-goals

- **Read-only inspection mode.** Hard-block only. Read-only is a separate piece of work if/when there's evidence users want it; a correct read-only mode in this thin-store / multi-store / sync-coordinator architecture is its own project.
- **Per-record-type capability negotiation.** A whole-profile integer is sufficient and matches the issue's framing.
- **Auto-detection of "an update is available".** The view says *"update the app"*; it doesn't query the App Store API. Async / network state would only complicate a stop-the-world view.

## Decisions

| Question | Choice |
| --- | --- |
| Granularity | Whole-profile integer (`dataFormatVersion: Int`). |
| Placement | On `ProfileRecord` (the profile-index zone). |
| Block semantics | Hard-block. No session, no engine. |
| Bump trigger | Manual constant; bump after successful local migration. |
| Reviewer hook | First-class `database-schema-review` check. |

## Design

### 1. The version constant and the rubric

New file `Domain/Models/DataFormatVersion.swift`. `DataFormatVersion` is a case-less enum used as a namespace — not instantiable, just a home for the constant:

```swift
enum DataFormatVersion {
  /// Highest profile data-format version this build can safely read and write.
  ///
  /// Bump this whenever you ship a forward-incompatible change to the
  /// profile data — anything an older build can't faithfully read,
  /// round-trip, or sync without silent data loss / corruption.
  ///
  /// Forward-incompatible rubric (any one of these requires a bump):
  ///   1. New record type added to CloudKit/schema.ckdb.
  ///   2. New non-defaulted field on a synced record type, where an older
  ///      build's nil decode would mis-classify the record.
  ///   3. New case added to a `// SyncBoundary —` marked enum (see below)
  ///      where older builds have a defensive fallback (e.g. unknown
  ///      AccountType → .asset).
  ///   4. New CKSyncEngine zone introduced.
  ///   5. Any change explicitly tagged "forward-incompatible" in its
  ///      PR description / commit message.
  ///   6. A field on a synced record type marked `// DEPRECATED` in
  ///      `schema.ckdb` (the wire-struct generator drops it; older builds
  ///      still write it). The rename is the trigger; the bump fences off
  ///      the "deprecated field is suddenly invisible" race.
  ///
  /// History (newest first):
  /// - 1: gate introduced alongside the crypto-wallet foundation.
  ///      AccountType.crypto, Account.walletAddress and chainId,
  ///      TransactionLeg.externalId, WalletSyncState. Older builds
  ///      (which also predate the gate) decode AccountType.crypto as
  ///      .asset and lose chain metadata on round-trip; the gate
  ///      protects future downgrades from this build forward.
  ///
  /// `0` is the implicit pre-gate baseline: any profile that exists in
  /// the cloud without a `dataFormatVersion` field reads as `0` and is
  /// trivially compatible with any v1+ build.
  static let current: Int = 1
}
```

**The compatibility predicate lives at the App layer, not on `Profile`.** `Domain/` must not know about build-side constants — the model carries the integer; `SessionManager` does the comparison. Inline at the gate site (and at the picker badge site — two callers, one trivial expression, no helper warranted):

```swift
profile.dataFormatVersion <= DataFormatVersion.current
```

**Sync-boundary enum marker.** Every domain enum whose values cross the sync boundary gets a `// SyncBoundary —` doc-comment line *immediately above* its declaration:

```swift
// SyncBoundary — adding a case requires bumping DataFormatVersion.current.
enum AccountType: String, Codable, Sendable { ... }
```

This marker is the deterministic substrate for the §7 reviewer check (which greps for `SyncBoundary` in the diff context, then narrows to enum-case additions inside marker-tagged enums — see §7 for the exact patterns and false-positive guard). Initial set as of v1: `AccountType`, `Transaction.TransactionType`, `RecurPeriod`, plus any other enum that appears in `CloudKit/schema.ckdb` field types. The marker is added to each in this PR.

Cosmetic / additive changes that older builds preserve correctly (a new field with truly null-as-default semantics, a new index, a new derived cache table) do not require a bump.

### 2. Storage and propagation

#### 2.1. CloudKit schema

Add one column to `RECORD TYPE ProfileRecord` in `CloudKit/schema.ckdb`:

```
dataFormatVersion       INT64 QUERYABLE SORTABLE,
```

Older builds read this field by reflective `record["dataFormatVersion"] as? Int64` lookup; a column they don't know about is silently ignored (no crash). New builds reading a record that pre-dates this column get `nil`, treated as `0`.

`just generate` regenerates `Backends/CloudKit/Sync/Generated/ProfileRecordCloudKitFields.swift`. The generated wire struct's memberwise init is fully `= nil`-defaulted, so existing call sites compile unchanged — but they will silently send `nil` for the new field unless updated. See §2.3.

#### 2.2. `profile-index.sqlite` schema and migration timing

Append migration `v2_data_format_version` to `Backends/GRDB/ProfileIndexSchema.swift`. The full registration (placed after `eraseDatabaseOnSchemaChange` and after the `v1_initial` registration):

```swift
migrator.registerMigration("v2_data_format_version", migrate: addDataFormatVersionColumn)
```

with the migration body:

```swift
private static func addDataFormatVersionColumn(_ database: Database) throws {
  try database.execute(sql: """
    ALTER TABLE profile
      ADD COLUMN data_format_version INTEGER NOT NULL DEFAULT 0;
    """)
}
```

`NOT NULL` with a constant default is permitted by §6 of `DATABASE_SCHEMA_GUIDE.md`. Existing rows backfill to `0`, which (per §1 above) means "pre-gate; trivially compatible with any v1+ build" — preserving the no-false-positives criterion.

Bump `ProfileIndexSchema.version` from `1` to `2` in the same file (the integer is surfaced for open-time integrity checks). Append the new entry to the file-level "Migration history" doc comment:

```
/// Migration history:
/// `v1_initial`             — the `profile` table.
/// `v2_data_format_version` — adds `data_format_version INTEGER NOT NULL DEFAULT 0`.
```

**Migration sequencing.** `profile-index.sqlite` is opened and migrated at app start in `MoolahApp+Setup.swift` (`profileIndexDatabase = try ProfileIndexDatabase.open(...)` runs the migrator before any view appears). `SessionManager` is constructed only after that succeeds. Therefore every call to `session(for:)` reads from a profile-index queue whose migrations have completed; the §3.2 re-read sees the backfilled `0` for any pre-existing row and the gate is consistent on first launch. The implementation must preserve this ordering — do not move the profile-index open to lazy initialisation.

#### 2.3. Plumbing chain — exact files and shapes

`dataFormatVersion: Int` must thread through every layer between CloudKit and the domain model. Every struct/class added below uses a `= 0` default on the new property so existing memberwise constructions keep compiling without a same-PR mass-update:

| Layer | File | Change |
| --- | --- | --- |
| Domain model | `Domain/Models/Profile.swift` | Add `var dataFormatVersion: Int = 0`. |
| GRDB row | `Backends/GRDB/Records/ProfileRow.swift` | Add `var dataFormatVersion: Int = 0`. Add `dataFormatVersion = "data_format_version"` to both `Columns` and `CodingKeys`. (Codable + GRDB will decode-fail on `SELECT *` if absent.) |
| GRDB row mapping | `Backends/GRDB/Records/ProfileRow+Mapping.swift` | Propagate `dataFormatVersion` through `init(domain:)` and `toDomain()`. |
| GRDB ↔ CK mapping | `Backends/GRDB/Sync/ProfileRow+CloudKit.swift` | `toCKRecord`: pass `dataFormatVersion: Int64(row.dataFormatVersion)` to `ProfileRecordCloudKitFields(...)`. `fieldValues(from:)`: read `Int(fields.dataFormatVersion ?? 0)` and populate the returned `ProfileRow`. |
| Legacy SwiftData record | `Backends/CloudKit/Models/ProfileRecord.swift` | Add `var dataFormatVersion: Int = 0`. Propagate through `toProfile()` and `from(profile:)`. |
| Legacy ↔ CK mapping | `Backends/CloudKit/Sync/ProfileRecord+CloudKit.swift` | Same pair of `toCKRecord` / `fieldValues(from:)` updates as the GRDB row. |
| App startup migration | `App/MoolahApp+Setup.swift` (`runProfileIndexMigrationIfNeeded`) | The SwiftData → GRDB migrator already copies `ProfileRecord` rows; ensure `dataFormatVersion` is part of the copied set. |

Without each of these, a profile bumped on this device uploads `dataFormatVersion = nil` (which a remote device reads as `0`), or a profile fetched from a newer device has its `dataFormatVersion` silently reset to `0` on local write. Either case is the silent-downgrade corruption this gate is meant to prevent.

#### 2.4. New repository surface

`GRDBProfileIndexRepository` gains two new methods (used by §3.2 and §2.5):

```swift
/// Async single-profile fetch. Used by the gate site to re-read the
/// profile-index row immediately before the compatibility check, so a
/// stale in-memory snapshot can't bypass the gate.
func profile(forID id: UUID) async throws -> Profile?

/// Synchronous field-only update of `data_format_version`. Used by
/// `ProfileIndexSyncHandler` from the conflict-resolution path so the
/// merged value reaches disk before `buildCKRecord` re-reads the row to
/// reconstruct the upload.
func setDataFormatVersionSync(id: UUID, value: Int) throws
```

Both follow the existing async/sync naming split in the repository (cf. `fetchAll()` async, `fetchAllSync()` sync). `setDataFormatVersionSync` does **not** trigger the `pending_change` queue — it's called from inside the conflict resolver, which then re-queues the save as part of the CKSyncEngine retry path.

#### 2.5. Conflict resolution — `max(local, remote)` on `.serverRecordChanged`

The existing `ProfileIndexSyncHandler.handleSentRecordZoneChanges` updates the local row's `encoded_system_fields` from the server record on `.serverRecordChanged` but does **not** merge field values back into the local row. Re-queuing a save then rebuilds the CKRecord from the local row's stale field values, which would overwrite a *higher* server-side `dataFormatVersion` with a *lower* local value — breaking the monotonic invariant.

Inside `ProfileIndexSyncHandler.handleSentRecordZoneChanges`, after `resolveSystemFields(for: failures)` and *before* re-queuing the save, add a `dataFormatVersion`-specific merge for each `.serverRecordChanged` failure carrying a server record:

```swift
let local = try repository.fetchRowSync(id: profileId)?.dataFormatVersion ?? 0
let remote = (serverRecord["dataFormatVersion"] as? Int64).map(Int.init) ?? 0
let merged = max(local, remote)
if merged != local {
  try repository.setDataFormatVersionSync(id: profileId, value: merged)
}
```

Then re-queue. This makes the field monotonic in *both* write directions:

- **Server-higher case:** the bump from another device wins; local row updates and re-queued upload contains the higher value.
- **Server-lower case:** local is authoritative (a legitimately-reachable state if both devices bumped concurrently and CloudKit picked the other one for the conflict response). Re-queued upload still contains the local value, server eventually accepts it.

In-flight `sentRecordZoneChanges` for the profile-index zone are safe: the only writes the handler performs back into `profile-index.sqlite` are the system-fields blob (idempotent — opaque tag bytes that the next upload uses as base) and now `setDataFormatVersionSync` (which only ever raises). Per-profile `ProfileDataSyncHandler` writes back `encoded_system_fields` blobs into `data.sqlite`; those are also idempotent and continue safely after the per-profile handler is evicted (§4.2) because the eviction precedes any further send-batch dispatch.

Test coverage: see §6 (`ProfileIndexConflictResolutionTests`).

#### 2.6. Implementation checklist

Pre-PR steps the implementer must run (and the reviewer must verify ran):

- [ ] `just generate` — regenerates `ProfileRecordCloudKitFields.swift` after the `schema.ckdb` edit.
- [ ] `just verify-schema` — imports `.ckdb` to the test container's Dev with `--validate` (per `SYNC_GUIDE.md` §11).
- [ ] `just check-schema-additive` — confirms the change is additive (CI gate).
- [ ] `just format` — applies swift-format and SwiftLint --fix.
- [ ] `just test` — full suite passes.

### 3. The bump-on-write

#### 3.1. Where it lives

The bump runs in `SessionManager`, not inside `ProfileSession.setUp()`. `setUp()` knows nothing about the app-scoped `profile-index.sqlite`; only `SessionManager` holds (or has access to) the `GRDBProfileIndexRepository` reference. `SessionManager` gains a stored property `let profileIndexRepository: GRDBProfileIndexRepository` (passed via init from `MoolahApp+Setup.swift`, which already constructs the repository for the profile-index sync wiring).

`SessionManager.session(for:)` today schedules `setUp()` as a fire-and-forget `Task`. The bump must run after a *successful* `setUp()`, so the bottleneck signature changes: `session(for:)` becomes `async` and `await`s `setUp()` before applying the bump. See §4.1 for the full caller migration.

#### 3.2. The bump itself

After `setUp()` succeeds and before `session(for:)` returns `.ready(...)`:

```swift
// Re-read the profile-index row so we don't act on a stale in-memory snapshot.
let current = try await profileIndexRepository.profile(forID: profile.id) ?? profile
guard current.dataFormatVersion < DataFormatVersion.current else {
  return .ready(session)
}

var bumped = current
bumped.dataFormatVersion = DataFormatVersion.current
try await profileIndexRepository.upsert(bumped)   // sync hook fires automatically
session.updateProfile(bumped)                     // keep session.profile consistent
return .ready(session)
```

`Profile` is a `var`-friendly struct, so direct mutation (`var bumped = current; bumped.dataFormatVersion = ...`) — no factory needed.

`session.updateProfile` is a small new method on `ProfileSession`. To support it, `ProfileSession.profile` is changed from `let` to `var`:

```swift
@MainActor
final class ProfileSession: Identifiable {
  var profile: Profile           // was: let
  // ...
  func updateProfile(_ updated: Profile) {
    precondition(updated.id == profile.id, "updateProfile must not change identity")
    self.profile = updated
  }
}
```

The `precondition` is defence-in-depth — `Profile.id` is the session key in `SessionManager.sessions`; an identity swap would orphan the session reference. Existing `session.profile` reads observe the new value through `@Observable`; no callers rely on `profile` being immutable for correctness.

Two invariants this satisfies:

1. **Monotonic.** We only ever raise the number — never lower it. Combined with the §2.5 merge step, the field is monotonic in both write directions.
2. **Migration-gated.** The bump is *after* `setUp()` succeeds, so the published claim is only made once the matching `data.sqlite` is on disk. Acceptance criterion: "first-launch migration that bumps `dataFormatVersion` is gated on a successful build → schema match".

#### 3.3. Failure modes

The bump's `upsert` writes to `profile-index.sqlite`, not `data.sqlite` — these are separate GRDB databases with no cross-database transaction. If migration succeeds but the bump fails (locked DB, disk full), `setUp()` already completed and the data DB is at the new schema; the bump retries on the next `session(for:)` call (which re-runs the bump check against the still-stale profile-index row). This is fine — the test `test_session_bumpIsRetried_whenUpsertFails` asserts the retry behaviour.

The `upsert` queues a `pending_change` and pushes via the existing profile-index CKSyncEngine. No special handling.

### 4. The gate — where it fires and what it blocks

#### 4.1. The contract

`SessionOpenResult` and its companion `IncompatibleProfileInfo` live in their own file `App/SessionOpenResult.swift` (per CODE_GUIDE.md §2 — `SessionManager.swift` already houses its primary type):

```swift
struct IncompatibleProfileInfo: Equatable, Sendable {
  let profileLabel: String
  let profileVersion: Int       // the profile's dataFormatVersion (source of truth for the gate integer)
  let buildVersion: Int         // DataFormatVersion.current at the time the gate fired
}

enum SessionOpenResult {
  case ready(ProfileSession)
  case incompatible(IncompatibleProfileInfo)
}
```

`buildVersion` is the integer gate value. The human-readable app version (`CFBundleShortVersionString`) is sourced separately by the view from `AppVersion.shortVersionString` and is not carried on `IncompatibleProfileInfo`.

`SessionManager.session(for:)` becomes the sole entry point:

```swift
func session(for profile: Profile) async -> SessionOpenResult { ... }
```

The pre-existing synchronous `session(for:)` is removed (no `fatalError`-trapping wrapper). `rebuildSession(for:)` becomes `async` too and returns `SessionOpenResult` (it currently `fatalError`s on a GRDB-open failure; that hard-crash path is replaced by surfacing the throw to the caller as a `SessionOpenResult.incompatible`-like terminal — see below).

The full caller inventory (from `grep -rn 'sessionManager\.session\|sessionManager\.rebuildSession\|SessionManager.*session(for'`):

| Site | Today | After |
| --- | --- | --- |
| `App/ProfileWindowView.swift:40` (`var body`'s computed open) | `let session = sessionManager.session(for: profile)` | Wrapped in a `Task { switch await sessionManager.session(for: profile) { ... } }`. The view stores `@State var sessionResult: SessionOpenResult?` and renders by `switch`ing on it (or shows `ProgressView` while nil). |
| `App/ProfileWindowView.swift:43-44` (`.onChange(of: profile.label)`) | `sessionManager.rebuildSession(for: profile)` | Wrapped in `Task { _ = await sessionManager.rebuildSession(for: profile) }`. |
| `App/ProfileRootView.swift:80` (`updateSession(for:)` async path) | `activeSession = sessionManager.session(for: profile)` | `switch await sessionManager.session(for: profile) { case .ready(let s): activeSession = s; case .incompatible(let info): incompatibleInfo = info }`. |
| `App/ProfileRootView.swift:89` (`rebuildSessionIfNeeded()` synchronous path) | `sessionManager.rebuildSession(for: profile); activeSession = sessionManager.session(for: profile)` | The whole method becomes `func rebuildSessionIfNeeded() { Task { await applyOpenResult(sessionManager.session(for: profile)) } }`, awaiting both calls. |
| `App/SessionRootView.swift` (entry-point routing) | calls `session(for:)` | switches on `SessionOpenResult` (see §5.3). |
| `App/SessionManager.swift` (`rebuildSession(for:)`) | `fatalError` on init failure | `async`, surfaces failures via `SessionOpenResult.incompatible` for the data-format case; for the `try ProfileSession(...)` GRDB-open failure case, the spec keeps the existing crash semantics (out of scope for this gate — disk-full / permissions issues weren't a pre-existing crash because of compatibility). The remaining `fatalError` for unrelated DB-open failures is acceptable — it's the same failure mode as before. |
| `Automation/AppleScript/Commands/ImportProfileCommand.swift` | constructs a session synchronously as part of import | translates `.incompatible` to `AutomationError.operationFailed("Profile is incompatible with this build")`. |
| All test harnesses that use `TestBackend` | profiles always have `dataFormatVersion = 0` | always hit `.ready`; tests that need direct `ProfileSession` access add a `try #require(case .ready(let session) = await sessionManager.session(for: profile))` guard. |

If the gate fires (`.incompatible`), no `ProfileSession` is constructed:

- No per-profile GRDB queue is opened (no migration runs).
- No per-profile zone is registered with `SyncCoordinator` (no `addObserver`, no instrument-remote-change callback).
- CKSyncEngine for that zone never starts. The "doesn't push from the older build into the profile while the gate is active" criterion is satisfied by *absence of the push path*, not by suspending an active engine — simpler and harder to get wrong.

The app-scoped `profile-index.sqlite` and its CKSyncEngine are unaffected. They have to keep running so the user *learns* their build is incompatible — and so a profile that becomes compatible later (after an app update) reflects that automatically.

#### 4.2. Mid-session arrival of a remote bump

`SessionManager` installs a single index observer on `SyncCoordinator` at construction time (added next to the existing wiring in `MoolahApp+Setup.swift`). The observer fires after every `ProfileIndexSyncHandler.applyRemoteChanges` batch and inspects each changed profile.

For each profile whose new `dataFormatVersion` exceeds `DataFormatVersion.current`:

1. **If a session is currently open** (`sessions[profileID] != nil`):
   1. Call `cleanupSync` on the session — cancels `syncReloadTask`, `catalogRefreshTask`, `pragmaOptimizeTask`, etc.; no *new* `pending_change` rows are inserted by the doomed session.
   2. Call a new `SyncCoordinator.removeDataHandler(for profileID: UUID)` — synchronously removes the entry from `dataHandlers` so `SyncCoordinator` no longer routes fetched changes for the per-profile zone to a stale handler. Eviction must happen before any further send-batch dispatch; the route check at delegate entry is sufficient.
   3. Set `incompatibleProfiles[profileID] = info` (a new `private(set) var incompatibleProfiles: [UUID: IncompatibleProfileInfo] = [:]` on `SessionManager`).
   4. `sessions.removeValue(forKey: profileID)`.
2. **If no session is open** (the bump arrived before the user ever opened that profile on this device): just set `incompatibleProfiles[profileID] = info`. The picker badge (§4.3) and the next `session(for:)` call (§3.2 re-read sees the bumped row → returns `.incompatible`) handle the rest.

**Eviction of stale `incompatibleProfiles` entries.** When `session(for:)` returns `.ready` for a given profile id, `incompatibleProfiles.removeValue(forKey: profileID)` runs as part of the same code path. This prevents a split-brain after an app update where `sessions[id]` is non-nil but `incompatibleProfiles[id]` is also non-nil. (After an app update, the user's first `session(for:)` call against a previously-incompatible profile sees a higher `DataFormatVersion.current` and returns `.ready`; the eviction fires and the routing layer naturally falls through to the session view.)

**Narrowed safety claim.** This does *not* prevent in-flight per-profile GRDB writes initiated *before* the teardown decision from completing — the `DatabaseQueue` is released when the session deallocates, after view references release it. The meaningful guarantee is:

> No new CKSyncEngine `pending_change` rows are inserted from this device for the profile after `cleanupSync` fires, and no further fetched changes for the per-profile zone are applied locally.

In-flight user-driven writes that have already reached the GRDB queue complete. They are the user's own data on the user's own device; the failure mode the gate is preventing is *cross-device* corruption (an older build round-tripping a record from a newer build), which the absence of new `pending_change` rows fences off. In-flight `sentRecordZoneChanges` for the per-profile zone that complete after eviction write only opaque `encoded_system_fields` bytes (idempotent) — those writes don't change record content and cannot cause downgrade corruption.

#### 4.3. Picker-side display

In the existing profile-list view, append a small "Update required" indicator on rows where `profile.dataFormatVersion > DataFormatVersion.current` *or* `sessionManager.incompatibleProfiles[profile.id] != nil` (the OR catches profiles whose `profile-index` row hasn't refreshed but whose mid-session bump is already known). Clicking the row still navigates — into the incompatible view rather than a session.

### 5. The UI surface

#### 5.1. Shared helper

New file `Shared/AppVersion.swift`:

```swift
enum AppVersion {
  /// `CFBundleShortVersionString`, or `"?"` if unset (test/preview only).
  static let shortVersionString: String =
    Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
}
```

`AboutView` adopts the same helper in this PR (it currently does the same `Bundle.main` lookup inline). No view body is allowed to read `Bundle.main` directly.

#### 5.2. The view

`Features/IncompatibleProfile/IncompatibleProfileView.swift`:

```swift
struct IncompatibleProfileView: View {
  let info: IncompatibleProfileInfo
  let onCheckForUpdates: () -> Void
  let onSwitchProfile: () -> Void
  var body: some View { ... }
}
```

`IncompatibleProfileInfo` (defined in `App/SessionOpenResult.swift`) is the single carrier — there is no separate "ViewModel" wrapper.

**Layout.** Centred panel, system iconography (`Image(systemName: "arrow.up.circle.fill").foregroundStyle(.tint)`), one heading, one body paragraph, two buttons:

- **Heading:** "Update Moolah to Continue" — `.accessibilityAddTraits(.isHeader)`.
- **Body:** "*\(info.profileLabel)* was last used by a newer version of Moolah. Update the app to open this profile, or switch to another profile."
- **Primary button:** "Check for Updates" — invokes `onCheckForUpdates`. The actual URL-open lives in the routing layer (`SessionRootView` / `ProfileWindowView`) — `NSWorkspace.shared.open` on macOS, `UIApplication.shared.open` on iOS, against a single `AppStoreURL` constant. Until there's a public App Store listing this resolves to GitHub Releases — single constant, swappable later.
- **Secondary button:** "Switch Profile" — invokes `onSwitchProfile`. The closure pops back to the profile picker (existing window route on macOS; navigation pop on iOS).

The view also surfaces `"Profile format v\(info.profileVersion) · This build supports v\(info.buildVersion) (\(AppVersion.shortVersionString))"` as small secondary text. Hidden behind a disclosure on iOS to avoid clutter; visible inline on macOS.

The view is a pure function of its inputs — no async, no error states, no spinners.

#### 5.3. Routing

`SessionRootView` (and any other consumer of `session(for:)`) becomes:

```swift
switch await sessionManager.session(for: profile) {
case .ready(let session):
  ProfileRootView(session: session)
case .incompatible(let info):
  IncompatibleProfileView(
    info: info,
    onCheckForUpdates: { NSWorkspace.shared.open(AppStoreURL.update) },
    onSwitchProfile: { /* pop to picker */ }
  )
}
```

In addition, the routing layer observes `sessionManager.incompatibleProfiles` so the *mid-session* transition (§4.2) flips the view from `ProfileRootView` to `IncompatibleProfileView` without a fresh navigation event.

### 6. Testing

All new tests run under `MoolahTests_iOS` and `MoolahTests_macOS` against `TestBackend` (CloudKitBackend + in-memory SwiftData / GRDB queue).

#### `SessionManagerCompatibilityTests` — the gate itself

- `test_session_returnsReady_whenProfileVersionEqualsBuild`
- `test_session_returnsReady_whenProfileVersionBelowBuild`
- `test_session_returnsReady_whenProfileVersionIsZero` (existing-profile no-false-positive)
- `test_session_returnsIncompatible_whenProfileVersionAboveBuild`
- `test_session_doesNotOpenDatabase_whenIncompatible` (assert no `data.sqlite` in the temp profile dir)
- `test_session_doesNotRegisterWithSyncCoordinator_whenIncompatible`
- `test_session_rereadsProfileFromRepository_beforeGate` — seed the repository with `dataFormatVersion = current + 1` and pass an in-memory `Profile` with `dataFormatVersion = 0`; assert the gate returns `.incompatible`.

#### `DataFormatVersionBumpTests` — the bump path

- `test_session_bumpsProfileVersion_whenBelowCurrent` (open profile at `current - 1` with build at `current` → after `session(for:)` returns `.ready`, `profile-index.sqlite` row reads `current` and a `pending_change` row exists).
- `test_session_doesNotBumpProfileVersion_whenAtOrAboveCurrent`.
- `test_session_doesNotBump_whenMigrationFails` — inject a migration failure via a `ProfileContainerManager` stub whose container() throws; assert the `profile-index` row's version stays at the old value.
- `test_session_bumpIsRetried_whenUpsertFails` — wrap `GRDBProfileIndexRepository` in a stub that throws once on `upsert`; assert the next `session(for:)` invocation succeeds and the `profile-index` row reaches `current`.
- `test_signOutSignIn_reUploadsDataFormatVersion` — after a `.switchAccounts` cycle wipes `profile-index.sqlite` and re-fetches, the next `session(for:)` correctly reads the server's stored version (no spurious downgrade or re-bump).

#### `ProfileIndexConflictResolutionTests` — `max(local, remote)` (§2.5)

- `test_serverRecordChanged_promotesLocalDataFormatVersion_whenServerIsHigher` — local row at `current - 1`, server returns `.serverRecordChanged` with a record at `current`; after resolution, local row reads `current` and re-queued save uploads `current`.
- `test_serverRecordChanged_keepsLocalDataFormatVersion_whenServerIsLower` — local row at `current`, server returns `.serverRecordChanged` with a record at `current - 1`; local is authoritative; re-queued save still uploads `current` (no downgrade).

#### `ProfileIndexCompatibilityRemoteChangeTests` — mid-session arrival

- `test_remoteVersionBumpAboveBuild_tearsDownActiveSession` — open a session at `current`, deliver a remote change setting `current + 1`. Assert:
  - `sessionManager.sessions[id]` becomes `nil`.
  - `cleanupSync` ran on the prior session (observed via a test hook that flips a flag).
  - The per-profile `ProfileDataSyncHandler` is no longer present in `SyncCoordinator.dataHandlers` (`SyncCoordinator` exposes a `dataHandler(forProfile:)` test accessor).
  - `sessionManager.incompatibleProfiles[id]` is populated with the right info.
- `test_remoteVersionBumpAboveBuild_withNoOpenSession_recordsIncompatibleEntryOnly` — never opened the session locally; deliver the remote bump; assert `sessions[id]` stays `nil`, `incompatibleProfiles[id]` is populated, no crash.
- `test_appUpdate_clearsStaleIncompatibleEntry` — start with `incompatibleProfiles[id]` populated and the profile-index row at `current - 1`; bump `DataFormatVersion.current` (test-only override) so the profile is now compatible; call `session(for:)`; assert `.ready` and `incompatibleProfiles[id]` is removed.

#### UI test

One new XCUITest in `MoolahUITests_macOS` using a UI-test seed (`.incompatibleProfile`) that hydrates a profile at `dataFormatVersion = DataFormatVersion.current + 1`:

- `test_incompatibleProfile_showsUpdateRequiredView` — seed → launch → pick the profile → assert the heading and both buttons are present.

Identifiers added to `UITestSupport/UITestIdentifiers.swift`:

- `IncompatibleProfileView_root`
- `IncompatibleProfileView_checkForUpdates`
- `IncompatibleProfileView_switchProfile`

### 7. The `database-schema-review` agent extension

Append a new section to `.claude/agents/database-schema-review.md`, alongside the existing categories:

> ### Forward-incompatibility version bumps (§ DataFormatVersion)
>
> A change to a synced data shape requires bumping `DataFormatVersion.current` in `Domain/Models/DataFormatVersion.swift`. Flag any of the following in the diff that does NOT also bump the constant:
>
> - **Critical:** New `RECORD TYPE` added to `CloudKit/schema.ckdb`.
> - **Critical:** New CKSyncEngine zone introduced (a `CKRecordZone.ID(zoneName:)` literal not previously present).
> - **Critical:** New non-defaulted field added to a synced record type — any `+`-line in `CloudKit/schema.ckdb` that adds a field declaration to an existing `RECORD TYPE`. Exclude fields whose *immediately-preceding diff line* is `+    // DEPRECATED` (those are covered by the deprecation bullet below; they are renames, not net-new fields).
> - **Critical:** New case added to an enum marked `// SyncBoundary —` in its source file. Detection requires two passes: list files containing the marker, then look for new enum cases in those files. False-positive guard: a `+ case` line inside a `switch { }` body (not inside an `enum { ... }` body) must NOT be flagged. The agent must inspect the surrounding context lines to confirm the `+ case` line is inside an enum declaration before raising the finding.
> - **Critical:** A field on a synced record type marked `// DEPRECATED` in `schema.ckdb` (the wire-struct generator drops it; older builds still write it; rubric bullet 6).
>
> Cosmetic / additive changes that older builds preserve correctly do not require a bump and should not be flagged. The doc-comment block on `DataFormatVersion.current` lists the rubric and prior bumps; cite a specific bullet from the rubric in the finding.
>
> Greppable patterns to run (run all from the repo root):
>
> - `git diff main -- CloudKit/schema.ckdb | rg '^\+ +RECORD TYPE'` — new record type.
> - `git diff main -- CloudKit/schema.ckdb | rg '^\+ +// DEPRECATED'` — newly-deprecated field. (The marker is a comment line above the field, not on the field line itself; the parser at `tools/CKDBSchemaGen/Sources/CKDBSchemaGen/Parser.swift:56` matches it via `line.hasPrefix("//") && line.contains("DEPRECATED")`.)
> - `git diff main -- '**/*.swift' | rg '^\+.*CKRecordZone\.ID\(zoneName:'` — new CKSyncEngine zone literal.
> - `rg -l 'SyncBoundary' Domain/` — list files with the marker. Then for each: `git diff main -- <file> | rg '^\+\s+case '` and inspect the diff context to confirm the `+ case` is inside an `enum { ... }` body, not a `switch { }` body.
> - `rg 'static let current\s*=\s*(\d+)' Domain/Models/DataFormatVersion.swift` — read the current value directly (for inspection / report).
> - `git diff main -- Domain/Models/DataFormatVersion.swift | rg '^\+ +static let current'` — confirm the constant was *changed* in this PR. Absence of this match alongside any triggering pattern above is the Critical finding.
>
> Absence of a bump alongside a triggering change is a **Critical** finding because the failure mode is silent data corruption on downgrade.

## Acceptance-criteria mapping

| Issue criterion | Where it's met |
| --- | --- |
| Opening a profile from a newer-format build on an older-format build shows the "update required" UI and does not mutate any data. | §4.1 (no `ProfileSession` constructed) + §5 (`IncompatibleProfileView`). |
| CKSyncEngine doesn't push from the older build into the profile while the gate is active. | §4.1 (zone never registered with `SyncCoordinator`) + §4.2 (mid-session: `cleanupSync` and handler eviction). |
| A profile that's compatible with the running build still opens normally — no false positives. | §2 (existing rows backfill to `0`; `0 ≤ current` is always compatible). |
| Test coverage: open a profile whose `dataFormatVersion` exceeds the build's; assert the gate triggers and no writes occur. | §6 (`SessionManagerCompatibilityTests`). |
| First-launch migration that bumps `dataFormatVersion` is gated on a successful build → schema match. | §3.2 (bump runs only after `setUp()` returns success); §6 (`test_session_doesNotBump_whenMigrationFails`). |

## Out of scope

- **Read-only inspection mode** — explicitly punted. See "Non-goals".
- **Major-version semver** — `Int` is enough; bumping by one per forward-incompatible change keeps the rubric simple.
- **Auto "an update is available" check** — see "Non-goals".
- **A separate "this build is too new for the profile" warning** — symmetric case (build > profile) is already the normal path; the bump-on-write path takes care of raising the profile.
