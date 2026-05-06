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

New file `Domain/Models/DataFormatVersion.swift`:

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
  ///   6. A field on a synced record type marked DEPRECATED in
  ///      `schema.ckdb` (causing the wire-struct generator to drop it)
  ///      where older builds still write a non-nil value newer builds
  ///      rely on. The rename is the trigger; the bump fences off the
  ///      "deprecated field is suddenly invisible" race.
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

**The compatibility predicate lives at the App layer, not on `Profile`.** `Domain/` must not know about build-side constants — the model carries the integer; `SessionManager` does the comparison. Inline at the gate site:

```swift
profile.dataFormatVersion <= DataFormatVersion.current
```

**Sync-boundary enum marker.** Every domain enum whose values cross the sync boundary gets a `// SyncBoundary —` doc comment line immediately above its declaration:

```swift
// SyncBoundary — adding a case requires bumping DataFormatVersion.current.
enum AccountType: String, Codable, Sendable { ... }
```

This is the deterministic substrate for the §7 reviewer check (which greps for `SyncBoundary` in the diff context). Initial set as of v1: `AccountType`, `Transaction.TransactionType`, `RecurPeriod`, plus any other enum that appears in `CloudKit/schema.ckdb` field types. The marker is added to each in this PR.

Cosmetic / additive changes that older builds preserve correctly (a new field with truly null-as-default semantics, a new index, a new derived cache table) do not require a bump.

### 2. Storage and propagation

#### 2.1. CloudKit schema

Add one column to `RECORD TYPE ProfileRecord` in `CloudKit/schema.ckdb`:

```
dataFormatVersion       INT64 QUERYABLE SORTABLE,
```

Older builds read this field by reflective `record["dataFormatVersion"] as? Int64` lookup; a column they don't know about is silently ignored (no crash). New builds reading a record that pre-dates this column get `nil`, treated as `0`.

`just generate` regenerates `Backends/CloudKit/Sync/Generated/ProfileRecordCloudKitFields.swift`. The generated wire struct's memberwise init is fully `= nil`-defaulted, so existing call sites compile unchanged — but they will silently send `nil` for the new field unless updated. See §2.3.

#### 2.2. `profile-index.sqlite` schema

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

#### 2.3. Plumbing chain — exact files and shapes

`dataFormatVersion: Int` must thread through every layer between CloudKit and the domain model. The full list of file changes:

| Layer | File | Change |
| --- | --- | --- |
| Domain model | `Domain/Models/Profile.swift` | Add `var dataFormatVersion: Int = 0`. Defaulted so existing call sites compile unchanged. |
| GRDB row | `Backends/GRDB/Records/ProfileRow.swift` | Add `var dataFormatVersion: Int`. Add `dataFormatVersion = "data_format_version"` to both `Columns` and `CodingKeys`. (Codable + GRDB will decode-fail on `SELECT *` if absent.) |
| GRDB row mapping | `Backends/GRDB/Records/ProfileRow+Mapping.swift` | Propagate `dataFormatVersion` through `init(domain:)` and `toDomain()`. |
| GRDB ↔ CK mapping | `Backends/GRDB/Sync/ProfileRow+CloudKit.swift` | `toCKRecord`: pass `dataFormatVersion: Int64(row.dataFormatVersion)` to `ProfileRecordCloudKitFields(...)`. `fieldValues(from:)`: read `Int(fields.dataFormatVersion ?? 0)` and populate the returned `ProfileRow`. |
| Legacy SwiftData record | `Backends/CloudKit/Models/ProfileRecord.swift` | Add `var dataFormatVersion: Int = 0`. Propagate through `toProfile()` and `from(profile:)`. |
| Legacy ↔ CK mapping | `Backends/CloudKit/Sync/ProfileRecord+CloudKit.swift` | Same pair of `toCKRecord` / `fieldValues(from:)` updates as the GRDB row. |
| App startup migration | `App/MoolahApp+Setup.swift` (`runProfileIndexMigrationIfNeeded`) | The SwiftData → GRDB migrator already copies `ProfileRecord` rows; ensure `dataFormatVersion` is part of the copied set. |

Without each of these, a profile bumped on this device uploads `dataFormatVersion = nil` (which a remote device reads as `0`), or a profile fetched from a newer device has its `dataFormatVersion` silently reset to `0` on local write. Either case is the silent-downgrade corruption this gate is meant to prevent.

#### 2.4. Conflict resolution — `max(local, remote)` on `.serverRecordChanged`

The existing `ProfileIndexSyncHandler.handleSentRecordZoneChanges` updates the local row's `encoded_system_fields` from the server record on `.serverRecordChanged` but does **not** merge field values back into the local row. Re-queuing a save then rebuilds the CKRecord from the local row's stale field values, which would overwrite a *higher* server-side `dataFormatVersion` with a *lower* local value — breaking the monotonic invariant.

Add to `ProfileIndexSyncHandler` (or the existing per-record conflict resolver it delegates to) a `dataFormatVersion`-specific merge: before re-queuing, set the local row's `dataFormatVersion = max(localRow.dataFormatVersion, serverRecord["dataFormatVersion"] as? Int64 ?? 0)`. Then the re-queued save uploads the maximum, and the field is monotonic across both directions.

Test coverage: see §6 (`ProfileIndexConflictResolutionTests`).

#### 2.5. Implementation checklist

Pre-PR steps the implementer must run (and the reviewer must verify ran):

- [ ] `just generate` — regenerates `ProfileRecordCloudKitFields.swift` after the `schema.ckdb` edit.
- [ ] `just verify-schema` — imports `.ckdb` to the test container's Dev with `--validate` (per `SYNC_GUIDE.md` §11).
- [ ] `just check-schema-additive` — confirms the change is additive (CI gate).
- [ ] `just format` — applies swift-format and SwiftLint --fix.
- [ ] `just test` — full suite passes.

### 3. The bump-on-write

#### 3.1. Where it lives

The bump runs in `SessionManager`, not inside `ProfileSession.setUp()`. `setUp()` knows nothing about the app-scoped `profile-index.sqlite`; only `SessionManager` holds the `GRDBProfileIndexRepository` reference.

`SessionManager.session(for:)` today schedules `setUp()` as a fire-and-forget `Task`. The bump must run after a *successful* `setUp()`, so the bottleneck signature changes: `session(for:)` becomes `async` and `await`s `setUp()` before applying the bump. Callers (`ProfileWindowView`, `ProfileRootView`, `ImportProfileCommand`, etc. — see §4.2 for the full list) already exist inside SwiftUI `Task { ... }` or async-context closures and can `await` the open.

#### 3.2. The bump itself

After `setUp()` succeeds and before `session(for:)` returns `.ready(...)`:

```swift
// Re-read the profile-index row so we don't act on a stale in-memory snapshot.
let current = try await profileIndexRepository.profile(forID: profile.id) ?? profile
guard current.dataFormatVersion < DataFormatVersion.current else { return .ready(session) }

var bumped = current
bumped.dataFormatVersion = DataFormatVersion.current
try await profileIndexRepository.upsert(bumped)   // sync hook fires automatically
session.updateProfile(bumped)                     // keep session.profile consistent
return .ready(session)
```

Direct mutation of the `var`-friendly `Profile` struct — no new `with(...)` factory needed. `session.updateProfile` is a small new method on `ProfileSession` that swaps `self.profile = bumped` and notifies any observers (the value is `@Observable` already through the session).

Two invariants this satisfies:

1. **Monotonic.** We only ever raise the number — never lower it. Combined with the §2.4 merge step, the field is monotonic in both write directions.
2. **Migration-gated.** The bump is *after* `setUp()` succeeds, so the published claim is only made once the matching `data.sqlite` is on disk. Acceptance criterion: "first-launch migration that bumps `dataFormatVersion` is gated on a successful build → schema match".

#### 3.3. Failure modes

The bump's `upsert` writes to `profile-index.sqlite`, not `data.sqlite` — these are separate GRDB databases with no cross-database transaction. If migration succeeds but the bump fails (locked DB, disk full), `setUp()` already completed and the data DB is at the new schema; the bump retries on the next `session(for:)` call (which re-runs the bump check against the still-stale profile-index row). This is fine — the test `test_session_bumpIsRetried_whenUpsertFails` asserts the retry behaviour.

The `upsert` queues a `pending_change` and pushes via the existing profile-index CKSyncEngine. No special handling.

### 4. The gate — where it fires and what it blocks

#### 4.1. The contract

`SessionManager.session(for:)` is the sole entry point. The contract changes:

```swift
struct IncompatibleProfileInfo: Equatable, Sendable {
  let profileLabel: String
  let profileVersion: Int
  let buildVersion: Int
}

enum SessionOpenResult {
  case ready(ProfileSession)
  case incompatible(IncompatibleProfileInfo)
}

func session(for profile: Profile) async -> SessionOpenResult { ... }
```

The pre-existing synchronous `session(for:)` is removed (no `fatalError`-trapping wrapper). Every caller migrates to the async form and switches on the result. The full caller inventory (from `grep -rn 'sessionManager\.session\|SessionManager.*session(for'`):

- `App/ProfileWindowView.swift` — switches on the result inside its `body`'s `Task { ... }`.
- `App/ProfileRootView.swift` — `updateSession(for:)` already async; switches on the result.
- `App/SessionRootView.swift` — switches on the result.
- `App/SessionManager.swift` — `rebuildSession(for:)` becomes async; gates on `.ready` (rebuild only fires for already-open sessions, which by definition were `.ready`).
- `Features/Imports/ImportProfileCommand.swift` — translates `.incompatible` to `AutomationError.operationFailed("Profile is incompatible with this build")`.
- All test harnesses that use `TestBackend` — profiles always have `dataFormatVersion = 0`, so they always hit `.ready`. Tests that need direct `ProfileSession` access add a `try #require(session) = .ready(...)` guard.

If the gate fires (`.incompatible`), no `ProfileSession` is constructed:

- No per-profile GRDB queue is opened (no migration runs).
- No per-profile zone is registered with `SyncCoordinator` (no `addObserver`, no instrument-remote-change callback).
- CKSyncEngine for that zone never starts. The "doesn't push from the older build into the profile while the gate is active" criterion is satisfied by *absence of the push path*, not by suspending an active engine — simpler and harder to get wrong.

The app-scoped `profile-index.sqlite` and its CKSyncEngine are unaffected. They have to keep running so the user *learns* their build is incompatible — and so a profile that becomes compatible later (after an app update) reflects that automatically.

#### 4.2. Mid-session arrival of a remote bump

If a profile's `dataFormatVersion` is bumped on another device while this build has the session open, `ProfileIndexSyncHandler.applyRemoteChanges` writes the new value into `profile-index.sqlite` and notifies the existing index observers (`SyncCoordinator.notifyIndexObservers`). We add one `SessionManager`-level observer that, for any profile whose bumped version exceeds `DataFormatVersion.current`:

1. Calls `cleanupSync` on the existing session (cancels `syncReloadTask`, `catalogRefreshTask`, `pragmaOptimizeTask`, etc.) so no *new* `pending_change` rows are inserted by the doomed session.
2. Removes the per-profile `ProfileDataSyncHandler` from `SyncCoordinator.dataHandlers` (a small extension to the existing `cleanupSync` path: see §6 for the assertion). This stops `SyncCoordinator` from delegating future fetched changes for that zone to a stale handler.
3. Sets `incompatibleProfiles[profile.id] = info` on `SessionManager` (a new `private(set) var incompatibleProfiles: [UUID: IncompatibleProfileInfo] = [:]`) — this is the state slot the routing layer observes to flip into the incompatible view.
4. Calls `sessions.removeValue(forKey: profile.id)`.

**Narrowed safety claim.** This does *not* prevent in-flight per-profile GRDB writes initiated *before* the teardown decision from completing — the `DatabaseQueue` is released when the session deallocates, after view references release it. The meaningful guarantee is:

> No new CKSyncEngine `pending_change` rows are inserted from this device for the profile after `cleanupSync` fires, and no further fetched changes for the per-profile zone are applied locally.

In-flight user-driven writes that have already reached the GRDB queue complete. They are the user's own data on the user's own device; the failure mode the gate is preventing is *cross-device* corruption (an older build round-tripping a record from a newer build), which the absence of new `pending_change` rows fences off.

#### 4.3. Picker-side display

In the existing profile-list view, append a small "Update required" indicator on rows where `profile.dataFormatVersion > DataFormatVersion.current`. The compatibility check is inlined at the picker site (same one-liner as the gate — no domain pollution). Clicking the row still navigates — into the incompatible view rather than a session.

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

`IncompatibleProfileInfo` (defined alongside `SessionOpenResult` in `App/SessionManager.swift`) is the single carrier — there is no separate "ViewModel" wrapper.

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
- `test_session_rereadsProfileFromRepository_beforeGate` — the gate uses the freshly-fetched `profile-index` row, not a stale in-memory snapshot.

#### `DataFormatVersionBumpTests` — the bump path

- `test_session_bumpsProfileVersion_whenBelowCurrent` (open profile at `current - 1` with build at `current` → after `session(for:)` returns `.ready`, `profile-index.sqlite` row reads `current` and a `pending_change` row exists).
- `test_session_doesNotBumpProfileVersion_whenAtOrAboveCurrent`.
- `test_session_doesNotBump_whenMigrationFails` — inject a migration failure via a `ProfileContainerManager` stub whose container() throws; assert the `profile-index` row's version stays at the old value.
- `test_session_bumpIsRetried_whenUpsertFails` — wrap `GRDBProfileIndexRepository` in a stub that throws once on `upsert`; assert the next `session(for:)` invocation succeeds and the `profile-index` row reaches `current`.
- `test_signOutSignIn_reUploadsDataFormatVersion` — after a `.switchAccounts` cycle wipes `profile-index.sqlite` and re-fetches, the next `session(for:)` correctly reads the server's stored version (no spurious downgrade or re-bump).

#### `ProfileIndexConflictResolutionTests` — `max(local, remote)` (§2.4)

- `test_serverRecordChanged_promotesLocalDataFormatVersion_whenServerIsHigher` — local row at `current - 1`, server returns `.serverRecordChanged` with a record at `current`; after resolution, local row reads `current` and re-queued save uploads `current`.
- `test_serverRecordChanged_keepsLocalDataFormatVersion_whenLocalIsHigher` — opposite direction (theoretically reachable if a remote device with a stale fetch overwrites; the merge keeps the higher local value).

#### `ProfileIndexCompatibilityRemoteChangeTests` — mid-session arrival

- `test_remoteVersionBumpAboveBuild_tearsDownActiveSession` — open a session at `current`, deliver a remote change setting `current + 1`. Assert:
  - `sessionManager.sessions[id]` becomes `nil`.
  - `cleanupSync` ran on the prior session (observed via a test hook that flips a flag).
  - The per-profile `ProfileDataSyncHandler` is no longer present in `SyncCoordinator.dataHandlers`.
  - `sessionManager.incompatibleProfiles[id]` is populated with the right info.

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
> - **Critical:** New non-defaulted field added to a synced record type — any field where an older build's `nil` decode would mis-classify the record. (Detection: any `+`-line in `CloudKit/schema.ckdb` that adds a field declaration to an existing `RECORD TYPE`, excluding lines that contain `// DEPRECATED`.)
> - **Critical:** New case added to an enum marked `// SyncBoundary —` in its source file. (Detection: `git diff main -- 'Domain/Models/*.swift' 'Domain/**/*.swift'` and look for `+ case` lines in files / contexts that contain the `// SyncBoundary —` marker.)
> - **Critical:** A field on a synced record type marked `// DEPRECATED` in `schema.ckdb` (the wire-struct generator drops it; older builds still write it; rubric bullet 6).
>
> Cosmetic / additive changes that older builds preserve correctly do not require a bump and should not be flagged. The doc-comment block on `DataFormatVersion.current` lists the rubric and prior bumps; cite a specific bullet from the rubric in the finding.
>
> Greppable patterns to run:
>
> - `git diff main -- CloudKit/schema.ckdb | rg '^\+ +RECORD TYPE'` — new record type.
> - `git diff main -- CloudKit/schema.ckdb | rg '^\+ +DEPRECATED'` — newly-deprecated field.
> - `git -C . grep -l 'SyncBoundary' -- 'Domain/**/*.swift'` then `git diff main -- <listed files> | rg '^\+\s+case '` — new enum case in a sync-boundary enum.
> - `rg 'static let current\s*=\s*(\d+)' Domain/Models/DataFormatVersion.swift` — read the current value directly from the file (for inspection).
> - `git diff main -- Domain/Models/DataFormatVersion.swift | rg '^\+ +static let current'` — confirm the constant was *changed* in this PR. Absence of this match alongside a triggering change above is the Critical finding.
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
