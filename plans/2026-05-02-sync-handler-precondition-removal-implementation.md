# Sync Handler Precondition Removal — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `SyncCoordinator` self-sufficient when constructing per-profile sync handlers so the trap in [#619](https://github.com/ajsutton/moolah-native/issues/619) becomes architecturally impossible. Drops the `setProfileGRDBRepositories` registration surface (and the `SyncCoordinatorError.profileNotRegistered` shim PR #620 introduced) and switches `SwiftDataToGRDBMigrator` to insert-or-ignore so it stops clobbering sync-applied rows now that sync apply for un-sessionized profiles is legal.

**Architecture:** `SyncCoordinator` owns its own per-profile `ProfileGRDBRepositories` instance, constructed lazily on first event from `containerManager.database(for:)` (the cached, process-wide GRDB queue). The session keeps its own instance through `CloudKitBackend` (real hooks for outbound queueing); the coordinator's instance has no-op hooks. Both write to the same `DatabaseQueue`, so SQLite serialises everything. The apply path's synchronous `applyRemoteChangesSync` entry points already bypass `onRecordChanged`/`onRecordDeleted`, so no echo loop and no double-queueing.

**Tech Stack:** Swift 6, GRDB (existing repository surface — no new SQL), Swift Testing (`import Testing`, `@Test`, `@Suite`, `#expect`), `xcodegen` (auto-picks up new files under `MoolahTests/`).

**Reference design:** [`plans/2026-05-02-sync-handler-precondition-removal-design.md`](2026-05-02-sync-handler-precondition-removal-design.md) — §3 design, §4 test plan, §6 considered alternatives.

---

## Setup

The worktree already exists at `/Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/fix-issue-619` on branch `fix/sync-handler-precondition-removal`, branched off `origin/main` with `--no-track`. The design-doc commit (`9a681de2`) is already on the branch.

All subsequent commands run from the worktree:
`/Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/fix-issue-619`.

- [ ] **Step 1: Verify clean baseline.**

```bash
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/fix-issue-619 status
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/fix-issue-619 log --oneline -3
```

Expected:
- `status`: clean tree on `fix/sync-handler-precondition-removal`.
- `log`: top commit is the design-doc commit; below it is the `mq: integrate PR #620 (fix/sync-startup-race)` merge.

---

# Slice 1 — Self-sufficient handler construction

Lands the new construction path and its test. After this slice, sync apply for un-sessionized profiles is functional — the bug is fixed. Subsequent slices are cleanup.

## Task 1: Failing test — apply path works without registration

**Files:**
- Test: `MoolahTests/Sync/SyncCoordinatorRegistrationFreeTests.swift` (new)

- [ ] **Step 1: Create the test file.**

```swift
import CloudKit
import Foundation
import GRDB
import SwiftData
import Testing

@testable import Moolah

/// Regression tests for issue #619: a sync event for a profile whose
/// `ProfileSession` is not open must apply successfully. Before the fix,
/// `SyncCoordinator.handlerForProfileZone` threw
/// `SyncCoordinatorError.profileNotRegistered` and the apply path
/// trapped via `preconditionFailure`. After the fix, the coordinator
/// constructs the per-profile GRDB repositories on demand from
/// `containerManager.database(for:)`.
@Suite("SyncCoordinator — registration-free apply")
@MainActor
struct SyncCoordinatorRegistrationFreeTests {
  @Test("handlerForProfileZone constructs a handler when no bundle is registered")
  func handlerConstructedWithoutRegistration() throws {
    let manager = try ProfileContainerManager.forTesting()
    let coordinator = SyncCoordinator(containerManager: manager)
    let profileId = UUID()
    let zoneID = CKRecordZone.ID(
      zoneName: "profile-\(profileId.uuidString)",
      ownerName: CKCurrentUserDefaultName)

    let handler = try coordinator.handlerForProfileZone(profileId: profileId, zoneID: zoneID)

    #expect(handler.profileId == profileId)
    #expect(handler.zoneID == zoneID)
  }

  @Test("a second call returns the cached handler")
  func handlerCachedAcrossCalls() throws {
    let manager = try ProfileContainerManager.forTesting()
    let coordinator = SyncCoordinator(containerManager: manager)
    let profileId = UUID()
    let zoneID = CKRecordZone.ID(
      zoneName: "profile-\(profileId.uuidString)",
      ownerName: CKCurrentUserDefaultName)

    let first = try coordinator.handlerForProfileZone(profileId: profileId, zoneID: zoneID)
    let second = try coordinator.handlerForProfileZone(profileId: profileId, zoneID: zoneID)

    #expect(first === second)
  }
}
```

- [ ] **Step 2: Run the test and confirm it fails.**

```bash
mkdir -p /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/fix-issue-619/.agent-tmp
just --justfile /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/fix-issue-619/justfile -d /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/fix-issue-619 generate
just --justfile /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/fix-issue-619/justfile -d /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/fix-issue-619 test-mac SyncCoordinatorRegistrationFreeTests 2>&1 | tee /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/fix-issue-619/.agent-tmp/test-output.txt
```

Expected: `handlerConstructedWithoutRegistration` fails with `SyncCoordinatorError.profileNotRegistered`. `handlerCachedAcrossCalls` fails for the same reason.

- [ ] **Step 3: Commit the failing test.**

```bash
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/fix-issue-619 add MoolahTests/Sync/SyncCoordinatorRegistrationFreeTests.swift
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/fix-issue-619 commit -m "$(cat <<'EOF'
test(sync): pin registration-free handler construction (failing)

Regression test for #619 — handlerForProfileZone must succeed when no
ProfileSession has registered a bundle. Currently fails with
SyncCoordinatorError.profileNotRegistered; will pass once the
coordinator builds its own ProfileGRDBRepositories from containerManager.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

## Task 2: Make the handler self-sufficient

**Files:**
- Modify: `Backends/CloudKit/Sync/ProfileGRDBRepositories.swift` (add a `forApply(database:)` static factory + a private no-op conversion service)
- Modify: `Backends/CloudKit/Sync/SyncCoordinator+HandlerAccess.swift` (`handlerForProfileZone` body)

The repositories' inits ask for a `defaultInstrument` and a `conversionService`. Both parameters are read-side only — the apply path writes Row objects via `applyRemoteChangesSync` and never invokes them. `Instrument.defaultTestInstrument` and `FixedConversionService` (used in `ProfileDataSyncHandlerTestSupport.makeBundle`) are test-only. We add an apply-only factory with production-safe placeholders next to the type that already documents the apply-only contract.

- [ ] **Step 1: Add `ProfileGRDBRepositories.forApply(database:)` plus a private no-op conversion service.**

Append to `Backends/CloudKit/Sync/ProfileGRDBRepositories.swift`:

```swift
extension ProfileGRDBRepositories {
  /// Builds a bundle suitable for the sync apply path: every per-type
  /// repository targets `database`, hooks are no-ops, and the read-side
  /// `defaultInstrument` / `conversionService` parameters carry inert
  /// placeholders. The apply path writes Row objects via
  /// `applyRemoteChangesSync` and never invokes either placeholder; the
  /// session-side bundle owned by `CloudKitBackend` continues to carry
  /// real values for user-mutation paths.
  static func forApply(database: any GRDB.DatabaseWriter) -> ProfileGRDBRepositories {
    // USD is a stable, locale-independent fiat that satisfies
    // `Instrument.fiat(code:)`'s `isoCurrencies` lookup. The choice is
    // arbitrary — only the type matters for the apply path.
    let placeholderInstrument = Instrument.fiat(code: "USD")
    return ProfileGRDBRepositories(
      csvImportProfiles: GRDBCSVImportProfileRepository(database: database),
      importRules: GRDBImportRuleRepository(database: database),
      instruments: GRDBInstrumentRegistryRepository(database: database),
      categories: GRDBCategoryRepository(database: database),
      accounts: GRDBAccountRepository(database: database),
      earmarks: GRDBEarmarkRepository(
        database: database, defaultInstrument: placeholderInstrument),
      earmarkBudgetItems: GRDBEarmarkBudgetItemRepository(database: database),
      investmentValues: GRDBInvestmentRepository(
        database: database, defaultInstrument: placeholderInstrument),
      transactions: GRDBTransactionRepository(
        database: database,
        defaultInstrument: placeholderInstrument,
        conversionService: ApplyPathConversionService()),
      transactionLegs: GRDBTransactionLegRepository(database: database))
  }
}

/// Placeholder `InstrumentConversionService` for the apply-path bundle.
/// Reachable only from `ProfileGRDBRepositories.forApply(database:)`;
/// every method traps because the apply path never reads through the
/// conversion service. If a future code change starts invoking it from
/// the apply path, the trap is preferable to silent zero-conversion.
private struct ApplyPathConversionService: InstrumentConversionService, Sendable {
  func convert(
    _ quantity: Decimal,
    from: Instrument,
    to: Instrument,
    on date: Date
  ) async throws -> Decimal {
    preconditionFailure(
      "ApplyPathConversionService.convert called — apply path never converts")
  }

  func convertAmount(
    _ amount: InstrumentAmount,
    to instrument: Instrument,
    on date: Date
  ) async throws -> InstrumentAmount {
    preconditionFailure(
      "ApplyPathConversionService.convertAmount called — apply path never converts")
  }
}
```

If `ProfileGRDBRepositories.swift` does not already `import GRDB` / `import Foundation`, add the imports needed by the new code (the existing file imports `Foundation` only — add `import GRDB`).

- [ ] **Step 2: Update `handlerForProfileZone` to use the factory as a fallback.**

In `Backends/CloudKit/Sync/SyncCoordinator+HandlerAccess.swift`, replace the existing body of `handlerForProfileZone` (the `if let registered … else if let factory … else throw` ladder, lines 44–69 in the current file) with:

```swift
  func handlerForProfileZone(
    profileId: UUID, zoneID: CKRecordZone.ID
  ) throws -> ProfileDataSyncHandler {
    if let existing = dataHandlers[profileId] {
      return existing
    }
    let container = try containerManager.container(for: profileId)
    let grdbRepositories = try resolveGRDBRepositories(for: profileId)
    let onInstrumentRemoteChange = instrumentRemoteChangeCallbacks[profileId] ?? {}
    let handler = ProfileDataSyncHandler(
      profileId: profileId,
      zoneID: zoneID,
      modelContainer: container,
      grdbRepositories: grdbRepositories,
      onInstrumentRemoteChange: onInstrumentRemoteChange)
    dataHandlers[profileId] = handler
    return handler
  }

  /// Returns the per-profile GRDB repository bundle. Prefers a bundle
  /// registered by `ProfileSession.registerWithSyncCoordinator` (so the
  /// session and the coordinator share an instance during normal app
  /// lifetime), then a test-injected factory, then a freshly-built
  /// apply-path bundle backed by `containerManager.database(for:)`.
  /// The last branch is what allows sync apply for un-sessionized
  /// profiles — see issue #619.
  private func resolveGRDBRepositories(for profileId: UUID) throws -> ProfileGRDBRepositories {
    if let registered = profileGRDBRepositories[profileId] {
      return registered
    }
    if let factory = fallbackGRDBRepositoriesFactory {
      let bundle = try factory(profileId)
      profileGRDBRepositories[profileId] = bundle
      return bundle
    }
    let database = try containerManager.database(for: profileId)
    let bundle = ProfileGRDBRepositories.forApply(database: database)
    profileGRDBRepositories[profileId] = bundle
    return bundle
  }
```

- [ ] **Step 3: Run the regression tests and confirm they pass.**

```bash
just --justfile /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/fix-issue-619/justfile -d /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/fix-issue-619 test-mac SyncCoordinatorRegistrationFreeTests 2>&1 | tee /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/fix-issue-619/.agent-tmp/test-output.txt
```

Expected: both tests pass. No other tests touched yet.

- [ ] **Step 4: Run the full SyncCoordinator suite to confirm nothing regressed.**

```bash
just --justfile /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/fix-issue-619/justfile -d /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/fix-issue-619 test-mac SyncCoordinator 2>&1 | tee /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/fix-issue-619/.agent-tmp/test-output.txt
grep -i 'failed\|error:' /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/fix-issue-619/.agent-tmp/test-output.txt || echo "no failures"
```

Expected: `no failures`. Existing tests that injected `fallbackGRDBRepositoriesFactory` continue to work because the factory branch in `resolveGRDBRepositories` is untouched.

- [ ] **Step 5: Format and commit.**

```bash
just --justfile /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/fix-issue-619/justfile -d /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/fix-issue-619 format
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/fix-issue-619 add Backends/CloudKit/Sync/ProfileGRDBRepositories.swift Backends/CloudKit/Sync/SyncCoordinator+HandlerAccess.swift
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/fix-issue-619 commit -m "$(cat <<'EOF'
fix(sync): make handlerForProfileZone self-sufficient (#619)

When no ProfileSession has registered a bundle and no test fallback
factory is injected, build a fresh ProfileGRDBRepositories via the new
forApply(database:) factory backed by containerManager.database(for:).
The factory's hooks are no-ops because the apply path's
applyRemoteChangesSync entry points bypass them; the session-side
instance retains real hooks for user mutations. The conversion service
parameter carries an ApplyPathConversionService that traps if invoked
— defence-in-depth against a future read through the apply bundle.

This eliminates the trap that fired when sync events arrived for an
un-sessionized profile (multi-profile background apply, pre-render
race, encrypted reset on an unopened profile). The
SyncCoordinatorError.profileNotRegistered case is now unreachable from
the production wiring and gets removed in a follow-up commit.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

## Task 3: Add an end-to-end apply-without-session test

**Files:**
- Modify: `MoolahTests/Sync/SyncCoordinatorRegistrationFreeTests.swift`

- [ ] **Step 1: Add a test that drives the full apply path for a profile that has no session.**

Append to the suite created in Task 1:

```swift
  @Test("applyFetchedRecordZoneChanges writes rows for an un-sessionized profile")
  func applyWritesRowsWithoutSession() async throws {
    let manager = try ProfileContainerManager.forTesting()
    let coordinator = SyncCoordinator(containerManager: manager)
    let profileId = UUID()
    try await manager.profileIndexRepository.upsert(
      Profile(
        id: profileId, label: "Background", currencyCode: "AUD",
        financialYearStartMonth: 7))
    let zoneID = CKRecordZone.ID(
      zoneName: "profile-\(profileId.uuidString)",
      ownerName: CKCurrentUserDefaultName)

    let accountId = UUID()
    let record = CKRecord(
      recordType: AccountRow.recordType,
      recordID: CKRecord.ID(
        recordName: AccountRow.recordName(for: accountId),
        zoneID: zoneID))
    record["id"] = accountId.uuidString as CKRecordValue
    record["name"] = "Synced from another device" as CKRecordValue
    record["instrumentId"] = "AUD" as CKRecordValue
    record["position"] = 0 as CKRecordValue
    record["isHidden"] = 0 as CKRecordValue
    record["type"] = "checking" as CKRecordValue

    // Drive the apply path directly — no ProfileSession has been
    // constructed, so this would have trapped before the fix.
    let handler = try coordinator.handlerForProfileZone(profileId: profileId, zoneID: zoneID)
    let result = handler.applyRemoteChanges(
      saved: [record], deleted: [], preExtractedSystemFields: [])

    if case .saveFailed(let description) = result {
      Issue.record("apply failed: \(description)")
    }
    let database = try manager.database(for: profileId)
    let stored = try await database.read { db in
      try AccountRow.fetchOne(db, key: accountId)
    }
    #expect(stored?.name == "Synced from another device")
  }
```

If the field set on the test `CKRecord` doesn't match the live `AccountRecord` shape (record types in `Backends/CloudKit/Sync/Generated/`), inspect a real `AccountRow.toCKRecord(in:)` call from `Backends/CloudKit/Sync/Generated/AccountRecord+CloudKit.swift` and mirror its key set. The point of the test is "row reaches GRDB," not exhaustive field coverage, so any minimal valid record body is fine.

- [ ] **Step 2: Run the new test.**

```bash
just --justfile /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/fix-issue-619/justfile -d /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/fix-issue-619 test-mac SyncCoordinatorRegistrationFreeTests 2>&1 | tee /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/fix-issue-619/.agent-tmp/test-output.txt
```

Expected: `applyWritesRowsWithoutSession` passes.

- [ ] **Step 3: Commit.**

```bash
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/fix-issue-619 add MoolahTests/Sync/SyncCoordinatorRegistrationFreeTests.swift
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/fix-issue-619 commit -m "$(cat <<'EOF'
test(sync): cover end-to-end apply for un-sessionized profile (#619)

Drives applyRemoteChanges directly with a synthetic CKRecord and asserts
the row lands in GRDB. Pinpoints the multi-profile background-apply
case from the issue.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

# Slice 2 — Drop the registration surface

The handler now constructs itself. The registration storage, the test fallback factory, the `SyncCoordinatorError.profileNotRegistered` case, and the apply-path's `preconditionFailure` are all dead weight. Remove them.

## Task 4: Drop the apply-path precondition split

**Files:**
- Modify: `Backends/CloudKit/Sync/SyncCoordinator+RecordChanges.swift` (`applyFetchedProfileDataChanges`, lines 134–171)

- [ ] **Step 1: Replace the handler-resolution block.**

Replace the `do { return try handlerForProfileZone… } catch SyncCoordinatorError.profileNotRegistered … catch { … }` ladder with a single `try?`:

```swift
    let handler: ProfileDataSyncHandler? = await MainActor.run {
      do {
        return try handlerForProfileZone(profileId: profileId, zoneID: zoneID)
      } catch {
        logger.error("Failed to get handler for profile \(profileId): \(error, privacy: .public)")
        return nil
      }
    }
    guard let handler else { return }
```

The remaining catch-and-skip exists for genuinely transient errors from `containerManager.container(for:)` / `containerManager.database(for:)` (e.g. disk pressure). Those are recoverable: CKSyncEngine retries on the next launch, the records remain in iCloud. No `preconditionFailure` here.

- [ ] **Step 2: Run the apply-path tests.**

```bash
just --justfile /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/fix-issue-619/justfile -d /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/fix-issue-619 test-mac SyncCoordinator 2>&1 | tee /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/fix-issue-619/.agent-tmp/test-output.txt
grep -i 'failed\|error:' /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/fix-issue-619/.agent-tmp/test-output.txt || echo "no failures"
```

Expected: `no failures`.

- [ ] **Step 3: Format and commit.**

```bash
just --justfile /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/fix-issue-619/justfile -d /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/fix-issue-619 format
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/fix-issue-619 add Backends/CloudKit/Sync/SyncCoordinator+RecordChanges.swift
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/fix-issue-619 commit -m "$(cat <<'EOF'
fix(sync): drop preconditionFailure from apply-path handler resolution

The profileNotRegistered case can no longer fire — the coordinator
constructs its own bundle. Catch-and-skip on transient
containerManager errors is preserved.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

## Task 5: Stop wiring the registration from `ProfileSession`

**Files:**
- Modify: `App/ProfileSession.swift` (`registerWithSyncCoordinator`, line ~212; `cleanupSync`, line ~272)
- Modify: `App/ProfileSession+SyncWiring.swift` (delete the `wireRepositorySync` and `registerGRDBRepositoriesForSync` functions; keep the file because `StoreReloadPlan` and `storesToReload(for:)` live in it)

- [ ] **Step 1: Delete the call to `wireRepositorySync(coordinator:)` from `registerWithSyncCoordinator`.**

In `App/ProfileSession.swift`, remove the line `wireRepositorySync(coordinator: coordinator)` from the body of `registerWithSyncCoordinator(_:)`. The remaining body installs the observer and the instrument-change callback (still session-scoped — correct).

- [ ] **Step 2: Delete the call to `coordinator.removeProfileGRDBRepositories(profileId:)` from `cleanupSync(coordinator:)`.**

In the same file, remove the single line `coordinator.removeProfileGRDBRepositories(profileId: profile.id)` from `cleanupSync`.

- [ ] **Step 3: Delete `wireRepositorySync` and `registerGRDBRepositoriesForSync` from `App/ProfileSession+SyncWiring.swift`.**

Open the file, remove the two functions and the surrounding doc comments. Leave `StoreReloadPlan` and the `storesToReload(for:)` static method intact.

- [ ] **Step 4: Verify the project still builds.**

```bash
just --justfile /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/fix-issue-619/justfile -d /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/fix-issue-619 build-mac 2>&1 | tee /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/fix-issue-619/.agent-tmp/build-output.txt
grep -i 'error:' /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/fix-issue-619/.agent-tmp/build-output.txt || echo "build clean"
```

Expected: `build clean`. Compile errors here likely mean a test or extension was reaching into the deleted functions; fix at the call site.

- [ ] **Step 5: Format and commit.**

```bash
just --justfile /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/fix-issue-619/justfile -d /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/fix-issue-619 format
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/fix-issue-619 add App/ProfileSession.swift App/ProfileSession+SyncWiring.swift
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/fix-issue-619 commit -m "$(cat <<'EOF'
refactor(sync): stop wiring per-profile GRDB bundle from ProfileSession

The coordinator now builds its own bundle when one isn't already
cached, so the session-side registration is dead weight. The instrument
remote-change callback registration stays — its session-scoped
lifecycle is correct (no session = no live UI subscribers).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

## Task 6: Update tests + benchmarks to drop `fallbackGRDBRepositoriesFactory`

**Files:**
- Modify: `MoolahTests/Sync/SyncCoordinatorTestsMore.swift`
- Modify: `MoolahTests/Sync/SyncCoordinatorTestsExtra.swift`
- Modify: `MoolahTests/Sync/SyncCoordinatorBackfillFlagTests.swift`
- Modify: `MoolahBenchmarks/SyncUploadBenchmarks.swift`
- Modify: `MoolahBenchmarks/SyncDownloadBenchmarks.swift`

Existing tests that pass `fallbackGRDBRepositoriesFactory:` to `SyncCoordinator(...)` are about to be broken (the parameter goes away in Task 7). We can simplify them now: drop the factory argument; the coordinator will construct its own bundle from the in-memory `ProfileContainerManager`.

Two of these tests rely on `mirrorContainerToDatabase` to copy SwiftData seeds into GRDB. Where they do, replace the factory injection with an explicit `try ProfileDataSyncHandlerTestSupport.mirrorContainerToDatabase(...)` call before driving the coordinator.

- [ ] **Step 1: `SyncCoordinatorTestsMore.swift` — drop the factory in `profileDataHandlerCreatedOnDemand` and `queueAllRecordsAfterImportMarksBackfillComplete`; mirror seeds explicitly where needed.**

For each `SyncCoordinator(containerManager: manager, fallbackGRDBRepositoriesFactory: …)` constructor in this file, change to `SyncCoordinator(containerManager: manager)`. If the test seeds SwiftData via `manager.container(for: profileId)` and expects those rows to surface through the coordinator's GRDB-backed handler, insert `try ProfileDataSyncHandlerTestSupport.mirrorContainerToDatabase(container: container, database: database)` after the SwiftData inserts and before the coordinator call (the helper still exists; it's a harmless explicit copy).

- [ ] **Step 2: Delete `handlerForProfileZoneThrowsWhenUnregistered` (lines 107–121).**

The test exercises the case the fix removes. Replace it with a one-liner test asserting that `handlerForProfileZone` does *not* throw when invoked without registration — but Task 1's `handlerConstructedWithoutRegistration` already covers that, so just delete this test outright.

- [ ] **Step 3: Update `queueUnsyncedRecordsSkipsUnregisteredProfile` (lines 123–138).**

The test pinned the outbound safe-skip behaviour. After the fix, the outbound path no longer needs to skip — every profile in the index gets a handler. Rename the test to `queueUnsyncedRecordsForAnyProfileInIndex`, change the assertion to `#expect(queued.isEmpty)` *only if there are no records to queue*, and adjust the body to assert the call returns successfully (no throw, no precondition):

```swift
  @Test("queueUnsyncedRecordsForAllProfiles works for any profile in the index")
  func queueUnsyncedRecordsForAnyProfileInIndex() async throws {
    let manager = try ProfileContainerManager.forTesting()
    let coordinator = SyncCoordinator(containerManager: manager)
    let profileId = UUID()
    try await manager.profileIndexRepository.upsert(
      Profile(
        id: profileId, label: "Idle", currencyCode: "AUD",
        financialYearStartMonth: 7))

    // No rows seeded; the call must succeed and produce nothing.
    let queued = await coordinator.queueUnsyncedRecordsForAllProfiles()
    #expect(queued.isEmpty)
  }
```

- [ ] **Step 4: `SyncCoordinatorTestsExtra.swift` — drop the factory at every call site.**

Repeat the Step 1 mechanical change for every `SyncCoordinator(containerManager: manager, fallbackGRDBRepositoriesFactory: …)` constructor. If a test relies on SwiftData-seeded rows surfacing through the coordinator, insert an explicit `mirrorContainerToDatabase` call.

- [ ] **Step 5: `SyncCoordinatorBackfillFlagTests.swift` — drop the factory at every call site.**

Same mechanical change. The three constructors at lines 30, 67, and 102 all use `inMemoryFallbackFactory` for type-only purposes (no seeded data); just remove the argument.

- [ ] **Step 6: `MoolahBenchmarks/SyncUploadBenchmarks.swift` and `SyncDownloadBenchmarks.swift` — drop the bundle injection.**

Each benchmark constructs a `ProfileGRDBRepositories` value and passes it to the coordinator via the factory. Replace with `SyncCoordinator(containerManager: manager)`; delete the local `bundle` variable.

- [ ] **Step 7: Run the full SyncCoordinator suite + benchmarks build.**

```bash
just --justfile /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/fix-issue-619/justfile -d /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/fix-issue-619 test-mac SyncCoordinator 2>&1 | tee /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/fix-issue-619/.agent-tmp/test-output.txt
grep -i 'failed\|error:' /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/fix-issue-619/.agent-tmp/test-output.txt || echo "no failures"
just --justfile /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/fix-issue-619/justfile -d /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/fix-issue-619 build-mac 2>&1 | tee /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/fix-issue-619/.agent-tmp/build-output.txt
grep -i 'error:' /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/fix-issue-619/.agent-tmp/build-output.txt || echo "build clean"
```

Expected: `no failures` and `build clean`.

- [ ] **Step 8: Format and commit.**

```bash
just --justfile /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/fix-issue-619/justfile -d /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/fix-issue-619 format
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/fix-issue-619 add MoolahTests/Sync/ MoolahBenchmarks/
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/fix-issue-619 commit -m "$(cat <<'EOF'
test(sync): stop injecting fallbackGRDBRepositoriesFactory

The coordinator now constructs its own bundle, so tests just pass a
ProfileContainerManager. SwiftData-seeded tests call
mirrorContainerToDatabase explicitly. Drops the
handlerForProfileZoneThrowsWhenUnregistered case (no longer reachable)
and renames the outbound-skip test to reflect the new semantics.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

## Task 7: Delete the registration storage and the error case

**Files:**
- Modify: `Backends/CloudKit/Sync/SyncCoordinator+HandlerAccess.swift`
- Modify: `Backends/CloudKit/Sync/SyncCoordinator.swift` (the `profileGRDBRepositories` and `fallbackGRDBRepositoriesFactory` properties + init parameter)
- Modify: `MoolahTests/Support/ProfileDataSyncHandlerTestSupport.swift` (delete `inMemoryFallbackFactory` and `managerBackedFallbackFactory`)

- [ ] **Step 1: In `SyncCoordinator+HandlerAccess.swift`, delete `setProfileGRDBRepositories`, `removeProfileGRDBRepositories`, and the `enum SyncCoordinatorError`.**

Delete the entire `enum SyncCoordinatorError` declaration at the top of the file (lines 5–19). Delete the two functions (`setProfileGRDBRepositories`, lines ~71–95; `removeProfileGRDBRepositories`, lines ~97–101). The `setInstrumentRemoteChangeCallback` / `removeInstrumentRemoteChangeCallback` pair stays.

- [ ] **Step 2: Decide whether to keep the factory parameter.**

Re-grep for any test still injecting the factory after Task 6:

```bash
grep -rn "fallbackGRDBRepositoriesFactory" /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/fix-issue-619 --include="*.swift" | grep -v plans/ | grep -v "SyncCoordinator+HandlerAccess.swift" | grep -v "SyncCoordinator.swift"
```

If the result is empty, the factory has no callers; delete it (proceed to Step 3). If anything matches, follow Steps 3a/3b to keep the factory but remove the registration storage.

- [ ] **Step 3: Simplify `resolveGRDBRepositories(for:)`.**

3a. **Factory has no callers (preferred — emptier diff downstream):** Replace the body with the direct factory call:

```swift
  private func resolveGRDBRepositories(for profileId: UUID) throws -> ProfileGRDBRepositories {
    if let cached = cachedGRDBRepositories[profileId] {
      return cached
    }
    let database = try containerManager.database(for: profileId)
    let bundle = ProfileGRDBRepositories.forApply(database: database)
    cachedGRDBRepositories[profileId] = bundle
    return bundle
  }
```

3b. **Factory still has callers:** Keep the factory branch; just drop the registration branch:

```swift
  private func resolveGRDBRepositories(for profileId: UUID) throws -> ProfileGRDBRepositories {
    if let cached = cachedGRDBRepositories[profileId] {
      return cached
    }
    if let factory = fallbackGRDBRepositoriesFactory {
      let bundle = try factory(profileId)
      cachedGRDBRepositories[profileId] = bundle
      return bundle
    }
    let database = try containerManager.database(for: profileId)
    let bundle = ProfileGRDBRepositories.forApply(database: database)
    cachedGRDBRepositories[profileId] = bundle
    return bundle
  }
```

Either way, the `cachedGRDBRepositories` storage replaces `profileGRDBRepositories` (rename for clarity — it's now purely a cache, not a registration).

- [ ] **Step 4: In `SyncCoordinator.swift`, rename `profileGRDBRepositories` to `cachedGRDBRepositories` and update its doc comment.**

Find the `var profileGRDBRepositories: [UUID: ProfileGRDBRepositories] = [:]` declaration (line ~300 in the file) plus the doc comment that calls it the registration storage. Rename to `cachedGRDBRepositories` and rewrite the comment to describe its new purpose: a per-profile cache for the auto-constructed apply-path bundle (or the test-injected factory's output, if the factory still exists).

- [ ] **Step 5: Drop `fallbackGRDBRepositoriesFactory` if Step 2's grep was empty.**

5a. **Empty grep:** delete the `let fallbackGRDBRepositoriesFactory: …` stored property and the corresponding `init` parameter in `SyncCoordinator.swift`. In `MoolahTests/Support/ProfileDataSyncHandlerTestSupport.swift`, delete `inMemoryFallbackFactory` (lines ~226–229) and `managerBackedFallbackFactory(manager:)` (lines ~239–255). Static helpers `makeBundle`, `mirrorContainerToDatabase`, `makeHandler`, `makeHandlerWithDatabase` stay — handler-direct tests use them.

5b. **Non-empty grep:** keep the property, the init parameter, and both test helpers. (This is the unlikely fallback if Task 6 missed a call site.)

- [ ] **Step 6: Run the full test suite.**

```bash
just --justfile /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/fix-issue-619/justfile -d /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/fix-issue-619 test-mac 2>&1 | tee /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/fix-issue-619/.agent-tmp/test-output.txt
grep -i 'failed\|error:' /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/fix-issue-619/.agent-tmp/test-output.txt || echo "no failures"
```

Expected: `no failures`.

- [ ] **Step 7: Format and commit.**

```bash
just --justfile /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/fix-issue-619/justfile -d /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/fix-issue-619 format
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/fix-issue-619 add Backends/CloudKit/Sync/SyncCoordinator+HandlerAccess.swift Backends/CloudKit/Sync/SyncCoordinator.swift MoolahTests/Support/ProfileDataSyncHandlerTestSupport.swift
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/fix-issue-619 commit -m "$(cat <<'EOF'
refactor(sync): delete the GRDB-bundle registration surface

setProfileGRDBRepositories, removeProfileGRDBRepositories,
SyncCoordinatorError.profileNotRegistered, and (when no test still
needs it) fallbackGRDBRepositoriesFactory + the test factory helpers.
profileGRDBRepositories storage is renamed to cachedGRDBRepositories
to reflect its new role: a per-profile cache for the auto-constructed
bundle, not a registration.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

# Slice 3 — Migrator: stop clobbering sync-applied rows

`SwiftDataToGRDBMigrator` upserts SwiftData rows into GRDB. With Slice 1 in place, sync apply for an unopened profile can write to GRDB before the migrator runs; the migrator's upsert then overwrites those rows with the older SwiftData version. Switch every per-type migrator to `INSERT ON CONFLICT DO NOTHING`. Per-type "complete" flags still latch, idempotency preserved.

## Task 8: Failing test — migrator preserves existing GRDB rows

**Files:**
- Test: `MoolahTests/Sync/SwiftDataToGRDBMigratorPreserveTests.swift` (new)

The migrator runs against a SwiftData container with persisted rows. We pre-seed GRDB with a sentinel row carrying a different `encodedSystemFields` blob, run the migrator, and assert the sentinel survives.

- [ ] **Step 1: Create the test file.**

```swift
import Foundation
import GRDB
import SwiftData
import Testing

@testable import Moolah

@Suite("SwiftDataToGRDBMigrator — preserve")
@MainActor
struct SwiftDataToGRDBMigratorPreserveTests {
  /// Per-type pinned: the migrator does not overwrite a GRDB row that
  /// sync wrote first (newer truth). The flag still latches.
  @Test("migrator does not clobber a GRDB row that already exists")
  func migratorPreservesExistingGRDBRow() async throws {
    let containerManager = try ProfileContainerManager.forTesting()
    let profileId = UUID()
    let container = try containerManager.container(for: profileId)
    let database = try containerManager.database(for: profileId)
    let defaults = UserDefaults(
      suiteName: "migrator-preserve-\(UUID().uuidString)")!

    // Seed SwiftData with one CategoryRecord (any type with a v3 flag works;
    // CategoryRecord is the simplest schema in the v3 bundle).
    let context = ModelContext(container)
    let categoryId = UUID()
    let swiftDataRecord = CategoryRecord(
      id: categoryId,
      name: "From SwiftData",
      systemKind: nil,
      sortOrder: 0,
      encodedSystemFields: Data([0x01, 0x02, 0x03]))
    context.insert(swiftDataRecord)
    try context.save()

    // Pre-seed GRDB with a *different* row for the same id (simulating
    // the sync-applied row).
    try await database.write { db in
      try CategoryRow(
        id: categoryId,
        recordName: CategoryRow.recordName(for: categoryId),
        name: "From CloudKit",
        systemKind: nil,
        sortOrder: 0,
        encodedSystemFields: Data([0xAA, 0xBB, 0xCC])
      ).insert(db)
    }

    try await SwiftDataToGRDBMigrator().migrateIfNeeded(
      modelContainer: container, database: database, defaults: defaults)

    let stored = try await database.read { db in
      try CategoryRow.fetchOne(db, key: categoryId)
    }
    #expect(stored?.name == "From CloudKit")
    #expect(stored?.encodedSystemFields == Data([0xAA, 0xBB, 0xCC]))
    #expect(defaults.bool(forKey: SwiftDataToGRDBMigrator.categoriesFlag))
  }

  /// Sanity: empty GRDB still gets seeded from SwiftData.
  @Test("migrator still seeds empty GRDB tables")
  func migratorSeedsEmptyGRDB() async throws {
    let containerManager = try ProfileContainerManager.forTesting()
    let profileId = UUID()
    let container = try containerManager.container(for: profileId)
    let database = try containerManager.database(for: profileId)
    let defaults = UserDefaults(
      suiteName: "migrator-seed-\(UUID().uuidString)")!

    let context = ModelContext(container)
    let categoryId = UUID()
    context.insert(CategoryRecord(
      id: categoryId,
      name: "Seed me",
      systemKind: nil,
      sortOrder: 0,
      encodedSystemFields: Data()))
    try context.save()

    try await SwiftDataToGRDBMigrator().migrateIfNeeded(
      modelContainer: container, database: database, defaults: defaults)

    let stored = try await database.read { db in
      try CategoryRow.fetchOne(db, key: categoryId)
    }
    #expect(stored?.name == "Seed me")
    #expect(defaults.bool(forKey: SwiftDataToGRDBMigrator.categoriesFlag))
  }
}
```

If the `CategoryRecord` initialiser shape doesn't match the project's actual `CategoryRecord` (check `Backends/CloudKit/Sync/Generated/CategoryRecord.swift` for the persisted-model fields), adjust accordingly. The test is otherwise generic — any v3 record type works because every per-type migrator uses the same `upsert` pattern.

- [ ] **Step 2: Run the test and confirm it fails.**

```bash
just --justfile /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/fix-issue-619/justfile -d /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/fix-issue-619 test-mac SwiftDataToGRDBMigratorPreserveTests 2>&1 | tee /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/fix-issue-619/.agent-tmp/test-output.txt
```

Expected: `migratorPreservesExistingGRDBRow` fails (the upsert wins; stored row is "From SwiftData"). `migratorSeedsEmptyGRDB` passes already.

- [ ] **Step 3: Commit the failing test.**

```bash
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/fix-issue-619 add MoolahTests/Sync/SwiftDataToGRDBMigratorPreserveTests.swift
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/fix-issue-619 commit -m "$(cat <<'EOF'
test(migrator): pin preserve-existing-rows behaviour (failing)

Once SyncCoordinator can apply for un-sessionized profiles, the
migrator must stop clobbering sync-applied rows. Currently fails:
upsert overwrites the GRDB row with the older SwiftData copy.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

## Task 9: Switch every per-type migrator to insert-or-ignore

**Files:**
- Modify: `Backends/GRDB/Migration/SwiftDataToGRDBMigrator.swift` (CSVImportProfile, ImportRule per-type migrators — `try row.upsert(database)` lines)
- Modify: `Backends/GRDB/Migration/SwiftDataToGRDBMigrator+ProfileIndex.swift`
- Modify: `Backends/GRDB/Migration/SwiftDataToGRDBMigrator+CoreFinancialGraph.swift`
- Modify: `Backends/GRDB/Migration/SwiftDataToGRDBMigrator+Earmarks.swift`
- Modify: `Backends/GRDB/Migration/SwiftDataToGRDBMigrator+Transactions.swift`

Every per-type migrator's write loop currently has the shape:

```swift
try await database.write { database in
  for row in mappedRows {
    try row.upsert(database)
  }
}
```

GRDB's persistence protocols (`PersistableRecord`) provide an `insert(_:onConflict:)` overload; the closest equivalent is `try row.insert(database, onConflict: .ignore)`. Verify the exact spelling against an existing call site or the GRDB reference; the call site we are replacing already uses GRDB types so the dependency is in scope.

- [ ] **Step 1: Confirm GRDB's insert-or-ignore spelling in this codebase.**

```bash
grep -rn "onConflict:" /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/fix-issue-619/Backends/GRDB --include="*.swift" | head -5
```

If you see `.ignore` in any existing call (e.g. a repository, another migrator, a row helper), use the same form. If GRDB exposes the overload as `try row.insert(db, onConflict: .ignore)`, that's the call to use. If it instead expects an SQL-level statement (`INSERT OR IGNORE INTO …`), use `try db.execute(literal: "INSERT OR IGNORE INTO …")` with the row's `databaseDictionary`. Pick whichever is idiomatic for the rest of `Backends/GRDB`.

- [ ] **Step 2: For every `try row.upsert(database)` call site inside a `migrate*IfNeeded` function across the five files, replace with the equivalent insert-or-ignore call.**

The mechanical pattern: only the line inside `for row in mappedRows { … }` changes. Don't touch the surrounding loop, the `database.write` block, the `committed` flag, or the `defer { … }` flag-set.

For `SwiftDataToGRDBMigrator.swift`, that's two sites (CSVImportProfiles around line 200, ImportRules around line 259).

For `SwiftDataToGRDBMigrator+CoreFinancialGraph.swift`, identify each per-type migrator (instruments, categories, accounts, earmarks, earmarkBudgetItems, investmentValues, transactions, transactionLegs) and apply the change inside each.

For `SwiftDataToGRDBMigrator+Earmarks.swift`, `+Transactions.swift`, `+ProfileIndex.swift`: same.

The doc comment block at the top of `SwiftDataToGRDBMigrator.swift` describes the rationale ("`upsert` rather than `insert` so a crash *between* the transaction commit and the `defaults.set(...)` call (the unavoidable gap) re-running on next launch is harmless"). Update that paragraph to describe the new rationale: "insert-or-ignore so a partial migration is idempotent on re-run AND so a sync-applied row written before the migration runs is not clobbered by an older SwiftData copy."

- [ ] **Step 3: Run the migrator preserve tests + the existing migrator tests.**

```bash
just --justfile /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/fix-issue-619/justfile -d /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/fix-issue-619 test-mac SwiftDataToGRDBMigrator 2>&1 | tee /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/fix-issue-619/.agent-tmp/test-output.txt
grep -i 'failed\|error:' /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/fix-issue-619/.agent-tmp/test-output.txt || echo "no failures"
```

Expected: `no failures`. The new preserve test passes; the seed-empty test still passes; existing migrator tests pass.

- [ ] **Step 4: Format and commit.**

```bash
just --justfile /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/fix-issue-619/justfile -d /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/fix-issue-619 format
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/fix-issue-619 add Backends/GRDB/Migration/
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/fix-issue-619 commit -m "$(cat <<'EOF'
fix(migrator): switch SwiftData→GRDB writes to insert-or-ignore (#619)

With sync apply now legal for un-sessionized profiles, the migrator's
upsert could overwrite a sync-applied row with an older SwiftData copy.
Insert-or-ignore preserves whichever row exists in GRDB and still
latches the per-type "complete" flag so subsequent launches no-op.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

# Slice 4 — Wrap up

## Task 10: Encrypted-reset regression test

**Files:**
- Modify: `MoolahTests/Sync/SyncCoordinatorRegistrationFreeTests.swift`

`handleEncryptedDataReset` (`SyncCoordinator+Zones.swift:222`) used to silently skip `clearAllSystemFields()` when no session was registered. With Slice 1 the handler is always available; pin the new behaviour.

- [ ] **Step 1: Add the test.**

Append to the suite:

```swift
  @Test("encrypted-data-reset clears system fields and re-queues records without session")
  func encryptedResetWithoutSession() async throws {
    let manager = try ProfileContainerManager.forTesting()
    let coordinator = SyncCoordinator(containerManager: manager)
    let profileId = UUID()
    try await manager.profileIndexRepository.upsert(
      Profile(
        id: profileId, label: "Reset", currencyCode: "AUD",
        financialYearStartMonth: 7))
    let zoneID = CKRecordZone.ID(
      zoneName: "profile-\(profileId.uuidString)",
      ownerName: CKCurrentUserDefaultName)

    // Seed a row directly in GRDB with a non-nil encodedSystemFields.
    let database = try manager.database(for: profileId)
    let categoryId = UUID()
    try await database.write { db in
      try CategoryRow(
        id: categoryId,
        recordName: CategoryRow.recordName(for: categoryId),
        name: "Reset me",
        systemKind: nil,
        sortOrder: 0,
        encodedSystemFields: Data([0xDE, 0xAD, 0xBE, 0xEF])
      ).insert(db)
    }

    coordinator.handleEncryptedDataReset(zoneID, zoneType: .profileData(profileId))

    let stored = try await database.read { db in
      try CategoryRow.fetchOne(db, key: categoryId)
    }
    #expect(stored?.encodedSystemFields == nil)
  }
```

- [ ] **Step 2: Run it.**

```bash
just --justfile /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/fix-issue-619/justfile -d /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/fix-issue-619 test-mac SyncCoordinatorRegistrationFreeTests 2>&1 | tee /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/fix-issue-619/.agent-tmp/test-output.txt
```

Expected: passes (the handler resolves now that the precondition is gone).

- [ ] **Step 3: Commit.**

```bash
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/fix-issue-619 add MoolahTests/Sync/SyncCoordinatorRegistrationFreeTests.swift
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/fix-issue-619 commit -m "$(cat <<'EOF'
test(sync): cover encrypted-data-reset for un-sessionized profile (#619)

The second symptom from #619: handleEncryptedDataReset used to silently
skip clearAllSystemFields when no session was registered. Pin the new
behaviour — system fields cleared regardless.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

## Task 11: Decide whether to keep PR #620's migration-gate

**Files:**
- Modify (or no-op): `Backends/CloudKit/Sync/SyncCoordinator+Lifecycle.swift`, `App/MoolahApp+Setup.swift`, `App/MoolahApp.swift`

The design doc §3.6 keeps `startAfter(profileIndexMigration:)` because it provides a separate observability property (consistent `ProfileStore.profiles` before the engine probes zones). Re-confirm this judgement now that the trap is gone:

- [ ] **Step 1: Audit whether anything else still depends on the gate.**

```bash
grep -rn "startAfter(profileIndexMigration\|launchTask\b" /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/fix-issue-619 --include="*.swift" | head
```

If the only uses are `MoolahApp+Setup.swift` (the call site) and `SyncCoordinator+Lifecycle.swift` (the implementation), the gate is purely "wait for migration before starting the engine."

- [ ] **Step 2: Keep the gate as-is.**

The migration-gate is preserved. Its purpose post-fix is observability/UI consistency — `ProfileStore.profiles` is populated before progress UI begins reporting. No code change in this task; it's a deliberate decision to leave the gate in place.

If a future audit decides to remove the gate, this is the right time to do it (one PR, with the trap-fix). For this PR we leave it; the cost is one Task and one extra `await`.

- [ ] **Step 3: No commit if no change.**

## Task 12: Pre-PR checks

- [ ] **Step 1: Run the full test suite (mac + iOS).**

```bash
just --justfile /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/fix-issue-619/justfile -d /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/fix-issue-619 test 2>&1 | tee /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/fix-issue-619/.agent-tmp/test-output.txt
grep -i 'failed\|error:' /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/fix-issue-619/.agent-tmp/test-output.txt || echo "no failures"
```

Expected: `no failures`.

- [ ] **Step 2: Format-check.**

```bash
just --justfile /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/fix-issue-619/justfile -d /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/fix-issue-619 format-check
```

Expected: clean exit. Any violation: fix the underlying code per memory `feedback_swiftlint_fix_not_baseline.md` (split / rename / use `#require`); never bump the baseline.

- [ ] **Step 3: TODO validation.**

```bash
just --justfile /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/fix-issue-619/justfile -d /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/fix-issue-619 validate-todos
```

Expected: clean.

- [ ] **Step 4: Run review agents.**

Run the `code-review`, `concurrency-review`, and `sync-review` agents over the diff. Apply every Critical / Important / Minor finding per memory `feedback_apply_all_review_findings.md`. If a finding is genuinely out of scope, ask before deferring (memory `feedback_apply_all_review_findings.md`).

```bash
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/fix-issue-619 diff origin/main --stat
```

For each agent: invoke via Claude Code's `@agent-name`, paste the diff context, apply findings inline, re-run tests, commit.

- [ ] **Step 5: Delete `.agent-tmp/` artefacts.**

```bash
rm -rf /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/fix-issue-619/.agent-tmp
```

## Task 13: Push branch and open PR

- [ ] **Step 1: Push.**

CLAUDE.md requires `<src>:<dst>` form — the worktree was created with `--no-track`, so without an explicit destination ref the push could resolve to a stale upstream:

```bash
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/fix-issue-619 push origin fix/sync-handler-precondition-removal:fix/sync-handler-precondition-removal
```

- [ ] **Step 2: Open the PR.**

```bash
gh pr create --title "fix(sync): remove handler-registration precondition (closes #619)" --body "$(cat <<'EOF'
## Summary

Closes [#619](https://github.com/ajsutton/moolah-native/issues/619). Removes the `setProfileGRDBRepositories` registration mechanism so `SyncCoordinator.handlerForProfileZone` is self-sufficient — given a profile id from a CKSyncEngine event, it constructs its own GRDB repository bundle from `containerManager.database(for:)`. The trap that fired for un-sessionized profiles becomes architecturally impossible.

Also switches `SwiftDataToGRDBMigrator` to insert-or-ignore so it stops clobbering sync-applied rows now that sync apply for un-sessionized profiles is legal (latent bug masked today by the trap).

### Architectural change

- `SyncCoordinator` constructs a `ProfileGRDBRepositories` lazily from the cached `containerManager.database(for:)` queue. Hooks are no-ops; `applyRemoteChangesSync` already bypasses them, so a no-op-hooks instance is functionally equivalent.
- The session keeps its own bundle (real hooks for outbound queueing) through `CloudKitBackend`. Two-instance pattern; both write through the same `DatabaseQueue` so SQLite serialises everything.
- `SyncCoordinatorError.profileNotRegistered`, `setProfileGRDBRepositories`, `removeProfileGRDBRepositories`, `fallbackGRDBRepositoriesFactory`, `wireRepositorySync` — all deleted.
- `SwiftDataToGRDBMigrator` per-type writes use `INSERT … ON CONFLICT DO NOTHING` so a sync-applied row that arrived first is not overwritten with an older SwiftData copy. Per-type "complete" flags continue to latch — idempotency preserved.

### What is NOT changing

- `instrumentRemoteChangeCallbacks` registration is unchanged (session-scoped is correct: no session = no live UI subscribers).
- PR #620's `startAfter(profileIndexMigration:)` gate stays — preserves consistent `ProfileStore.profiles` before the engine probes zones.

### Reference

- Design: `plans/2026-05-02-sync-handler-precondition-removal-design.md`
- Implementation plan: `plans/2026-05-02-sync-handler-precondition-removal-implementation.md`

## Test plan

- [x] `just test` (mac + iOS) passes
- [x] `just format-check` clean (no baseline changes)
- [x] `just validate-todos` clean
- [x] `code-review`, `concurrency-review`, `sync-review` agents — all findings applied
- [x] New tests:
  - `SyncCoordinatorRegistrationFreeTests` — handler construction, caching, end-to-end apply, encrypted-reset, all without a session
  - `SwiftDataToGRDBMigratorPreserveTests` — preserve existing GRDB row + still seed empty GRDB
- [ ] Manual: launch the Mac release build with the iPhone-driven Trust Shares record pending in iCloud — verify no crash and the record applies even without opening the affected profile

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

- [ ] **Step 3: Add the PR to the merge queue.**

Per memory `feedback_prs_to_merge_queue.md`, every PR opened goes through the merge-queue skill, not manual merge. Hand the PR number off to the `merge-queue` skill (or to its controller script `~/.claude/skills/merge-queue/scripts/merge-queue-ctl.sh`) once CI is green.

---

## Self-review notes

Spec coverage check (cross-referenced against design doc §3 and §4):

| Spec section | Covered by |
|---|---|
| §3.1 Self-sufficient handler construction | Tasks 1–3 |
| §3.2 Delete the registration surface | Tasks 4–7 |
| §3.3 Two-instance audit (no concurrency / consistency issue) | Demonstrated by Task 3's end-to-end test running entirely off the new path |
| §3.4 Lifecycle simplification | Task 5 |
| §3.5 Migrator: stop clobbering sync-applied rows | Tasks 8–9 |
| §3.6 What stays in PR #620 | Task 11 |
| §4 New tests | Tasks 1, 3, 8, 10 |
| §4 Removal of test scaffolding | Tasks 6–7 |
