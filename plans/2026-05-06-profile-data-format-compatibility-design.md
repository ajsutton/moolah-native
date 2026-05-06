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
  ///   3. New enum case in a domain enum that crosses the sync boundary
  ///      (AccountType, Transaction.TransactionType, RecurPeriod, ...)
  ///      where older builds have a defensive fallback (e.g. unknown
  ///      AccountType → .asset).
  ///   4. New CKSyncEngine zone introduced.
  ///   5. Any change explicitly tagged "forward-incompatible" in its
  ///      PR description / commit message.
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

extension Profile {
  var isCompatibleWithThisBuild: Bool {
    dataFormatVersion <= DataFormatVersion.current
  }
}
```

Cosmetic / additive changes that older builds preserve correctly (a new field with truly null-as-default semantics, a new index, a new derived cache table) do not require a bump.

### 2. Storage and propagation

**CloudKit schema.** Add one column to `RECORD TYPE ProfileRecord` in `CloudKit/schema.ckdb`:

```
dataFormatVersion       INT64 QUERYABLE SORTABLE,
```

Older builds read this field by reflective `record["dataFormatVersion"] as? Int64` lookup; a column they don't know about is silently ignored (no crash). New builds reading a record that pre-dates this column get `nil`, treated as `0`.

`just generate` regenerates `Backends/CloudKit/Sync/Generated/ProfileRecordCloudKitFields.swift` with the new field.

**`profile-index.sqlite` schema.** Append migration `v2_data_format_version` to `Backends/GRDB/ProfileIndexSchema.swift`:

```sql
ALTER TABLE profile
  ADD COLUMN data_format_version INTEGER NOT NULL DEFAULT 0;
```

`NOT NULL` with a constant default is permitted by §6 of `DATABASE_SCHEMA_GUIDE.md`. Existing rows backfill to `0`, which (per §1 above) means "pre-gate; trivially compatible with any v1+ build" — preserving the no-false-positives criterion.

**Domain layer.** `Domain/Models/Profile.swift` gets `var dataFormatVersion: Int = 0`. Defaulted so existing call sites compile unchanged. Value travels through:

- `ProfileRow` (GRDB row) ↔ `Profile` (domain) ↔ `ProfileRecord` (legacy SwiftData) ↔ `ProfileRecordCloudKitFields` (regenerated).
- `GRDBProfileIndexRepository.upsert` writes the column; the remote-changes path reads it back.

### 3. The bump-on-write

Inside the per-profile session bring-up, after `ProfileSession.setUp()` completes successfully:

```swift
if profile.dataFormatVersion < DataFormatVersion.current {
  let bumped = profile.with(dataFormatVersion: DataFormatVersion.current)
  try await profileIndexRepository.upsert(bumped)   // sync hook fires automatically
}
```

Two invariants this satisfies:

1. **Monotonic.** We only ever raise the number — never lower it. A device on an older build sees a higher number on a profile it touched on a newer build, refuses to open, and never writes anything (including a downgrade).
2. **Migration-gated.** The bump is *after* the local schema migration succeeds, so the published claim "this profile is at v\(current)" is only made once the matching `data.sqlite` is actually on disk. (Acceptance criterion: "first-launch migration that bumps `dataFormatVersion` is gated on a successful build → schema match".)

The bump is queued through the existing `GRDBProfileIndexRepository.upsert` → `attachSyncHooks` → `pending_change` row → CKSyncEngine push path. No special handling.

### 4. The gate — where it fires and what it blocks

`SessionManager.session(for:)` is the bottleneck — every code path that opens a profile goes through it. The contract changes:

```swift
enum SessionOpenResult {
  case ready(ProfileSession)
  case incompatible(profile: Profile, profileVersion: Int, buildVersion: Int)
}

func openSession(for profile: Profile) -> SessionOpenResult { ... }
```

If `profile.isCompatibleWithThisBuild` is false, we return `.incompatible(...)` **without constructing a `ProfileSession`**. That means:

- No per-profile GRDB queue is opened (no migration runs).
- No per-profile zone is registered with `SyncCoordinator` (no `addObserver`, no instrument-remote-change callback).
- CKSyncEngine for that zone never starts. The "doesn't push from the older build into the profile while the gate is active" criterion is satisfied by *absence of the push path*, not by suspending an active engine — simpler and harder to get wrong.

The existing `session(for:)` (synchronous, `fatalError` on failure) is retained as a thin wrapper that traps on `.incompatible` for the few internal call sites that still want the old shape — but every UI-facing caller (`ProfileRootView`, `SessionRootView`) switches to `openSession(for:)` and routes both cases.

The app-scoped `profile-index.sqlite` and its CKSyncEngine are unaffected. They have to keep running so the user *learns* their build is incompatible — and so a profile that becomes compatible later (after an app update) reflects that automatically.

**Sync arrival mid-session.** If a profile's `dataFormatVersion` is bumped on another device while this build has the session open, `ProfileIndexSyncHandler` writes the new value into `profile-index.sqlite` and fires its existing observer. We add one piece: when the observer sees the active session's profile version go above `DataFormatVersion.current`, it tears the session down via `SessionManager.removeSession(for:)` (which runs `cleanupSync`) and the routing layer flips to the incompatible view. No partial-write window — `removeSession` is the existing teardown path.

### 5. The UI surface

One new view, one routing change.

**`Features/IncompatibleProfile/IncompatibleProfileView.swift`** — a thin SwiftUI view bound to a value type:

```swift
struct IncompatibleProfileViewModel: Equatable, Sendable {
  let profileLabel: String
  let profileVersion: Int
  let buildVersion: Int
  let buildAppVersion: String   // CFBundleShortVersionString
}

struct IncompatibleProfileView: View {
  let model: IncompatibleProfileViewModel
  var body: some View { ... }
}
```

**Layout.** Centred panel, system iconography (`Image(systemName: "arrow.up.circle.fill").foregroundStyle(.tint)`), one heading, one body paragraph, two buttons:

- **Heading:** "Update Moolah to Continue" — `.accessibilityAddTraits(.isHeader)`.
- **Body:** "*\(profileLabel)* was last used by a newer version of Moolah. Update the app to open this profile, or switch to another profile."
- **Primary button:** "Check for Updates" — opens the App Store product page on macOS (`NSWorkspace.shared.open`) and the same on iOS via `UIApplication.shared.open`. Until there's a public App Store listing this resolves to GitHub Releases — single constant, swappable later.
- **Secondary button:** "Switch Profile" — pops back to the profile picker. On macOS this is the existing window route; on iOS it pops the navigation stack.

The view also surfaces `"Profile format v\(profileVersion) · This build supports v\(buildVersion) (\(buildAppVersion))"` as small secondary text. Hidden behind a disclosure on iOS to avoid clutter; visible inline on macOS.

The view is a pure function of the model — no async, no error states, no spinners.

**Routing.** `SessionRootView` (and any other consumer of `session(for:)`) becomes:

```swift
switch sessionManager.openSession(for: profile) {
case .ready(let session):
  ProfileRootView(session: session)
case .incompatible(let profile, let pv, let bv):
  IncompatibleProfileView(model: .init(
    profileLabel: profile.label,
    profileVersion: pv,
    buildVersion: bv,
    buildAppVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
  ))
}
```

**Profile picker badge.** In the existing profile-list view, append a small "Update required" indicator on rows where `profile.isCompatibleWithThisBuild` is false. Clicking the row still navigates — into the incompatible view rather than the session.

### 6. Testing

All new tests run under `MoolahTests_iOS` and `MoolahTests_macOS` against `TestBackend` (CloudKitBackend + in-memory SwiftData / GRDB queue).

**`SessionManagerCompatibilityTests`** — the gate itself:

- `test_openSession_returnsReady_whenProfileVersionEqualsBuild`
- `test_openSession_returnsReady_whenProfileVersionBelowBuild`
- `test_openSession_returnsReady_whenProfileVersionIsZero` (existing-profile no-false-positive)
- `test_openSession_returnsIncompatible_whenProfileVersionAboveBuild`
- `test_openSession_doesNotOpenDatabase_whenIncompatible` (assert no `data.sqlite` in the temp profile dir)
- `test_openSession_doesNotRegisterWithSyncCoordinator_whenIncompatible`

**`DataFormatVersionBumpTests`** — the bump path:

- `test_setUp_bumpsProfileVersion_whenBelowCurrent` (open profile at `current - 1` with build at `current` → after `setUp()`, `profile-index.sqlite` row reads `current` and a `pending_change` row exists)
- `test_setUp_doesNotBumpProfileVersion_whenAtOrAboveCurrent`
- `test_setUp_doesNotBump_whenMigrationFails` — inject a migration failure and assert the version stays at the old value (the gate-on-success criterion).

**`ProfileIndexCompatibilityRemoteChangeTests`** — mid-session arrival:

- `test_remoteVersionBumpAboveBuild_tearsDownActiveSession` (open a session at `current`, deliver a remote change setting `current + 1`, assert `sessions[id]` becomes nil and `cleanupSync` ran on the prior session).

**UI test.** One new XCUITest in `MoolahUITests_macOS` using a UI-test seed (`.incompatibleProfile`) that hydrates a profile at `dataFormatVersion = DataFormatVersion.current + 1`:

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
> - **Critical:** New non-defaulted field added to a synced record type — any field where an older build's `nil` decode would mis-classify the record.
> - **Critical:** New case added to a domain enum that crosses the sync boundary (`AccountType`, `Transaction.TransactionType`, `RecurPeriod`, …) where older builds have a defensive fallback (e.g. unknown `AccountType` → `.asset`).
>
> Cosmetic / additive changes that older builds preserve correctly do not require a bump and should not be flagged. The doc-comment block on `DataFormatVersion.current` lists the rubric and prior bumps; cite a specific bullet from the rubric in the finding.
>
> Greppable patterns to run:
>
> - `git diff main -- CloudKit/schema.ckdb | rg '^\+ {4}RECORD TYPE'` — new record type.
> - `git diff main -- 'Domain/Models/*.swift' | rg '^\+ +case '` — new enum case in domain models (filter to enums known to cross the sync boundary).
> - `git diff main -- Domain/Models/DataFormatVersion.swift | rg '^\+ +static let current'` — confirm the bump is present.

Absence of a bump alongside a triggering change is a **Critical** finding because the failure mode is silent data corruption on downgrade.

## Acceptance-criteria mapping

| Issue criterion | Where it's met |
| --- | --- |
| Opening a profile from a newer-format build on an older-format build shows the "update required" UI and does not mutate any data. | Section 4 (no `ProfileSession` constructed) + Section 5 (`IncompatibleProfileView`). |
| CKSyncEngine doesn't push from the older build into the profile while the gate is active. | Section 4 (zone never registered with `SyncCoordinator`). |
| A profile that's compatible with the running build still opens normally — no false positives. | Section 2 (existing rows backfill to `0`; `0 ≤ current` is always compatible). |
| Test coverage: open a profile whose `dataFormatVersion` exceeds the build's; assert the gate triggers and no writes occur. | Section 6 (`SessionManagerCompatibilityTests`). |
| First-launch migration that bumps `dataFormatVersion` is gated on a successful build → schema match. | Section 3 (bump runs after `setUp()` succeeds; `DataFormatVersionBumpTests.test_setUp_doesNotBump_whenMigrationFails`). |

## Out of scope

- **Read-only inspection mode** — explicitly punted. See "Non-goals".
- **Major-version semver** — `Int` is enough; bumping by one per forward-incompatible change keeps the rubric simple.
- **Auto "an update is available" check** — see "Non-goals".
- **A separate "this build is too new for the profile" warning** — symmetric case (build > profile) is already the normal path; the bump-on-write path takes care of raising the profile.
