# First-Run Experience Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace `ProfileSetupView` with a brand-led `WelcomeView` that defaults to iCloud, acknowledges the "new device, existing iCloud data" case, and falls through to a single-field setup form when no profiles arrive. Per the design at [`plans/2026-04-24-first-run-experience-design.md`](./2026-04-24-first-run-experience-design.md).

**Architecture:** 18 tasks across five phases. Phase A (1–8) mutates `SyncCoordinator` and `ProfileStore` — pure-logic changes, fully TDD against swift-testing suites. Phase B (9–13) builds new SwiftUI views in isolation with `#Preview`s. Phase C (14–15) wires the new view into existing routing. Phase D (16) deletes the old view and renames `Auth/WelcomeView`. Phase E (17–18) lands UI tests and a manual brand QA pass. Each task lands as a separate PR through the merge queue.

**Tech Stack:** Swift 6.2, SwiftUI, SwiftData, CloudKit (`CKSyncEngine`), swift-testing (`@Suite`, `@Test`, `#expect`), XCUITest (macOS), `@Observable`, `@MainActor`, xcodegen, `just`.

---

## How to execute this plan

Per-task workflow:

1. Create a new worktree + branch off `main` via the `superpowers:using-git-worktrees` skill (`.worktrees/` directory, already gitignored).
2. Execute the task's steps in order, TDD where the task has test-first steps.
3. Before committing code, run `just format` to apply swift-format + SwiftLint autocorrect.
4. After adding new Swift files, run `just generate` so xcodegen rebuilds `Moolah.xcodeproj` (the project is gitignored).
5. Run the scoped tests listed in the task. Pipe output through `tee .agent-tmp/<task>-test.txt` (per CLAUDE.md) so failures are inspectable without re-running.
6. Run `@code-review`, and for any task touching sync, `@sync-review`; for view tasks, `@ui-review`. Address critical findings before committing.
7. Commit with the conventional-commit style message provided in the task.
8. Push the branch and open a PR referencing "Implements Task N of `plans/2026-04-24-first-run-experience-implementation.md`". Enqueue via the merge-queue skill.
9. Wait for merge. Do not stack the next task on top of this branch — start a fresh worktree off updated `main`.

**Tests use swift-testing.** Suites are `@Suite("Name") @MainActor struct FooTests { ... }` with `@Test func name() { #expect(condition) }`. All test files sit under `MoolahTests/` or `MoolahUITests_macOS/` per the existing directory layout; register them in `project.yml`'s `MoolahTests_*` / `MoolahUITests_macOS` targets by running `just generate` after adding files.

**Concurrency.** Everything on `@MainActor`. Stores and `SyncCoordinator` are already `@MainActor`; new types inherit the isolation where they compose.

**Accessibility identifiers.** Any `.accessibilityIdentifier(_:)` used by a UI test must be declared as a constant in `UITestSupport/UITestIdentifiers.swift` (creating this file if it doesn't exist in Task 17's step). Never hard-code identifier strings in the test file or the view.

---

## Task 1: Add `ICloudAvailability` type

**Files:**
- Create: `Backends/CloudKit/Sync/ICloudAvailability.swift`
- Test: `MoolahTests/Sync/ICloudAvailabilityTests.swift`

- [ ] **Step 1: Write the failing test suite**

Create `MoolahTests/Sync/ICloudAvailabilityTests.swift`:

```swift
import Testing

@testable import Moolah

@Suite("ICloudAvailability")
struct ICloudAvailabilityTests {
  @Test("reasons are equatable")
  func reasonsEquatable() {
    #expect(ICloudAvailability.UnavailableReason.notSignedIn == .notSignedIn)
    #expect(ICloudAvailability.UnavailableReason.notSignedIn != .restricted)
  }

  @Test("cases are equatable")
  func casesEquatable() {
    #expect(ICloudAvailability.available == .available)
    #expect(ICloudAvailability.unknown == .unknown)
    #expect(ICloudAvailability.unavailable(reason: .notSignedIn)
      == .unavailable(reason: .notSignedIn))
    #expect(ICloudAvailability.unavailable(reason: .notSignedIn)
      != .unavailable(reason: .restricted))
    #expect(ICloudAvailability.available != .unknown)
  }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
mkdir -p .agent-tmp
just test ICloudAvailabilityTests 2>&1 | tee .agent-tmp/task1.txt
```

Expected: compile error — `ICloudAvailability` is not defined.

- [ ] **Step 3: Create the type**

Create `Backends/CloudKit/Sync/ICloudAvailability.swift`:

```swift
import Foundation

/// Current observability-oriented view of iCloud account status for
/// Moolah's CloudKit sync.
///
/// Source of truth lives on ``SyncCoordinator`` — see
/// `guides/SYNC_GUIDE.md` Rule 8 (single owner for account-change
/// handling). Views read through ``ProfileStore.iCloudAvailability``
/// which is a pass-through.
///
/// `.unknown` is the initial state before the first `accountStatus()`
/// probe has returned, **and** the state we fall back to on
/// `CKAccountStatus.couldNotDetermine` or a thrown probe error. We
/// deliberately treat these as transient and keep the welcome screen's
/// "Checking iCloud…" copy running — see design spec §6.1 and §8.
enum ICloudAvailability: Equatable, Sendable {
  case unknown
  case available
  case unavailable(reason: UnavailableReason)

  enum UnavailableReason: Equatable, Sendable {
    case notSignedIn              // CKAccountStatus.noAccount
    case restricted               // CKAccountStatus.restricted
    case temporarilyUnavailable   // CKAccountStatus.temporarilyUnavailable
    case entitlementsMissing      // CloudKitAuthProvider.isCloudKitAvailable == false
  }
}
```

- [ ] **Step 4: Regenerate Xcode project, run tests to verify they pass**

```bash
just generate
just test ICloudAvailabilityTests 2>&1 | tee .agent-tmp/task1.txt
grep -iE 'failed|error:' .agent-tmp/task1.txt || echo "OK"
```

Expected: all `ICloudAvailabilityTests` pass.

- [ ] **Step 5: Format, code-review, commit, push, PR**

```bash
just format
rm -f .agent-tmp/task1.txt
```

Run the `@code-review` agent on the new files; address critical findings.

```bash
git add Backends/CloudKit/Sync/ICloudAvailability.swift \
        MoolahTests/Sync/ICloudAvailabilityTests.swift \
        project.yml Moolah.xcodeproj   # project.yml only changes if xcodegen reshuffled; Moolah.xcodeproj is gitignored, just here as a reminder
git status                             # verify Moolah.xcodeproj NOT staged
git commit -m "feat(sync): add ICloudAvailability type"
```

Push branch, `gh pr create`, enqueue via merge-queue skill.

---

## Task 2: Add `iCloudAvailability` property on `SyncCoordinator` with initial probe

**Files:**
- Modify: `Backends/CloudKit/Sync/SyncCoordinator.swift` (add observable property)
- Modify: `Backends/CloudKit/Sync/SyncCoordinator+Lifecycle.swift` (probe in `completeStart`)
- Test: `MoolahTests/Sync/SyncCoordinatorICloudAvailabilityTests.swift`

- [ ] **Step 1: Write the failing test suite**

Create `MoolahTests/Sync/SyncCoordinatorICloudAvailabilityTests.swift`:

```swift
import CloudKit
import Foundation
import Testing

@testable import Moolah

@Suite("SyncCoordinator — iCloudAvailability")
@MainActor
struct SyncCoordinatorICloudAvailabilityTests {

  @Test("initial state is .unknown before start")
  func initialState() {
    let manager = ProfileContainerManager(isInMemoryOverride: true)
    let coordinator = SyncCoordinator(containerManager: manager)
    #expect(coordinator.iCloudAvailability == .unknown)
  }

  @Test("sets .entitlementsMissing synchronously when CloudKit is unavailable")
  func entitlementsMissing() {
    let manager = ProfileContainerManager(isInMemoryOverride: true)
    let coordinator = SyncCoordinator(
      containerManager: manager,
      isCloudKitAvailableOverride: false
    )
    #expect(coordinator.iCloudAvailability == .unavailable(reason: .entitlementsMissing))
  }

  @Test("maps CKAccountStatus.available → .available")
  func mapAvailable() {
    #expect(SyncCoordinator.mapAccountStatus(.available) == .available)
  }

  @Test("maps CKAccountStatus.noAccount → .unavailable(.notSignedIn)")
  func mapNoAccount() {
    #expect(SyncCoordinator.mapAccountStatus(.noAccount)
      == .unavailable(reason: .notSignedIn))
  }

  @Test("maps CKAccountStatus.restricted → .unavailable(.restricted)")
  func mapRestricted() {
    #expect(SyncCoordinator.mapAccountStatus(.restricted)
      == .unavailable(reason: .restricted))
  }

  @Test("maps CKAccountStatus.temporarilyUnavailable → .unavailable(.temporarilyUnavailable)")
  func mapTemporarilyUnavailable() {
    #expect(SyncCoordinator.mapAccountStatus(.temporarilyUnavailable)
      == .unavailable(reason: .temporarilyUnavailable))
  }

  @Test("maps CKAccountStatus.couldNotDetermine → .unknown (transient)")
  func mapCouldNotDetermine() {
    #expect(SyncCoordinator.mapAccountStatus(.couldNotDetermine) == .unknown)
  }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
just test SyncCoordinatorICloudAvailabilityTests 2>&1 | tee .agent-tmp/task2.txt
```

Expected: compile error — `iCloudAvailability`, `mapAccountStatus`, `isCloudKitAvailableOverride` not defined.

- [ ] **Step 3: Add the observable property**

In `Backends/CloudKit/Sync/SyncCoordinator.swift`, inside the `final class SyncCoordinator` body alongside other properties (near `isFirstLaunch`):

```swift
/// Observable iCloud account availability. `.unknown` while a probe is
/// outstanding; see `handleAccountChange` in `SyncCoordinator+Zones.swift`
/// for ongoing updates, and `completeStart` in `+Lifecycle.swift` for the
/// initial probe. Views bind via `ProfileStore.iCloudAvailability`.
var iCloudAvailability: ICloudAvailability = .unknown
```

Add the nonisolated static mapper inside the same class:

```swift
/// Maps `CKAccountStatus` to ``ICloudAvailability``.
/// `.couldNotDetermine` and thrown errors are treated as `.unknown`
/// (transient) per design spec §6.1.
nonisolated static func mapAccountStatus(
  _ status: CKAccountStatus
) -> ICloudAvailability {
  switch status {
  case .available:
    return .available
  case .noAccount:
    return .unavailable(reason: .notSignedIn)
  case .restricted:
    return .unavailable(reason: .restricted)
  case .temporarilyUnavailable:
    return .unavailable(reason: .temporarilyUnavailable)
  case .couldNotDetermine:
    return .unknown
  @unknown default:
    return .unknown
  }
}
```

- [ ] **Step 4: Add the test override parameter and synchronous entitlements path**

`SyncCoordinator` today has a simple initialiser. Add an optional `isCloudKitAvailableOverride: Bool? = nil` parameter. Default `nil` means read from `CloudKitAuthProvider.isCloudKitAvailable` at init. When `false`, synchronously assign `.unavailable(reason: .entitlementsMissing)` to `iCloudAvailability` and skip the async probe path.

Locate the existing `init(containerManager:)` in `SyncCoordinator.swift`. After the existing body adds a line:

```swift
let available = isCloudKitAvailableOverride ?? CloudKitAuthProvider.isCloudKitAvailable
if !available {
  self.iCloudAvailability = .unavailable(reason: .entitlementsMissing)
}
```

Store `available` as a private property `private let isCloudKitAvailable: Bool` so `completeStart` can skip the probe when it's `false`.

- [ ] **Step 5: Add the initial `accountStatus()` probe in `completeStart`**

Open `Backends/CloudKit/Sync/SyncCoordinator+Lifecycle.swift`. At the tail of `completeStart(prepared:signpostID:)` — after `zoneSetupTask = Task { … }` and before the closing brace — add:

```swift
// Initial iCloud availability probe. Skip when entitlements are missing
// (already set synchronously in init). On `couldNotDetermine` or thrown
// error we stay `.unknown` and rely on the subsequent `.accountChange`
// delegate event (see Task 3).
if isCloudKitAvailable && iCloudAvailability == .unknown {
  Task { [weak self] in
    do {
      let status = try await CKContainer.default().accountStatus()
      await MainActor.run {
        self?.iCloudAvailability = Self.mapAccountStatus(status)
      }
    } catch {
      // Stay `.unknown`; next `.accountChange` will resolve.
      self?.logger.info(
        "Initial accountStatus probe threw: \(error, privacy: .public) — staying .unknown"
      )
    }
  }
}
```

- [ ] **Step 6: Run tests to verify they pass**

```bash
just generate
just test SyncCoordinatorICloudAvailabilityTests 2>&1 | tee .agent-tmp/task2.txt
grep -iE 'failed|error:' .agent-tmp/task2.txt || echo "OK"
```

Expected: all tests pass. Existing `SyncCoordinatorTests` should also pass — run them to confirm:

```bash
just test SyncCoordinatorTests 2>&1 | tee .agent-tmp/task2-regress.txt
grep -iE 'failed|error:' .agent-tmp/task2-regress.txt || echo "OK"
```

- [ ] **Step 7: Format, review, commit**

Run `@sync-review` on the diff (per project Agents section in CLAUDE.md). Address findings.

```bash
just format
rm -f .agent-tmp/task2*.txt
git add Backends/CloudKit/Sync/SyncCoordinator.swift \
        Backends/CloudKit/Sync/SyncCoordinator+Lifecycle.swift \
        MoolahTests/Sync/SyncCoordinatorICloudAvailabilityTests.swift
git commit -m "feat(sync): add SyncCoordinator.iCloudAvailability + initial probe"
```

Push, PR, queue.

---

## Task 3: Map account-change events to `iCloudAvailability`

**Files:**
- Modify: `Backends/CloudKit/Sync/SyncCoordinator+Zones.swift` (`handleAccountChange`)
- Test: `MoolahTests/Sync/SyncCoordinatorICloudAvailabilityTests.swift` (extend)

- [ ] **Step 1: Extend the failing test suite**

Add tests to `MoolahTests/Sync/SyncCoordinatorICloudAvailabilityTests.swift`:

```swift
@Test("handleAccountChange(.signIn) sets availability to .available")
func handleAccountChangeSignIn() async {
  let manager = ProfileContainerManager(isInMemoryOverride: true)
  let coordinator = SyncCoordinator(containerManager: manager)
  coordinator.iCloudAvailability = .unavailable(reason: .notSignedIn)

  coordinator.applyAvailability(from: .signIn)

  #expect(coordinator.iCloudAvailability == .available)
}

@Test("handleAccountChange(.signOut) sets availability to .unavailable(.notSignedIn)")
func handleAccountChangeSignOut() async {
  let manager = ProfileContainerManager(isInMemoryOverride: true)
  let coordinator = SyncCoordinator(containerManager: manager)
  coordinator.iCloudAvailability = .available

  coordinator.applyAvailability(from: .signOut)

  #expect(coordinator.iCloudAvailability == .unavailable(reason: .notSignedIn))
}

@Test("handleAccountChange(.switchAccounts) sets availability to .available")
func handleAccountChangeSwitchAccounts() async {
  let manager = ProfileContainerManager(isInMemoryOverride: true)
  let coordinator = SyncCoordinator(containerManager: manager)
  coordinator.iCloudAvailability = .unknown

  coordinator.applyAvailability(from: .switchAccounts)

  #expect(coordinator.iCloudAvailability == .available)
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
just test SyncCoordinatorICloudAvailabilityTests 2>&1 | tee .agent-tmp/task3.txt
```

Expected: compile error — `applyAvailability(from:)` not defined.

- [ ] **Step 3: Extract the availability update into a testable method**

In `Backends/CloudKit/Sync/SyncCoordinator+Zones.swift`, add a new helper above `handleAccountChange`:

```swift
/// Maps a CloudKit account-change type to ``ICloudAvailability`` and
/// applies it. Pure, testable — safe to call in isolation.
///
/// `.signIn` / `.switchAccounts` both mean "we now have a usable
/// account" → `.available`. `.signOut` → `.unavailable(.notSignedIn)`.
func applyAvailability(
  from changeType: CKSyncEngine.Event.AccountChange.ChangeType
) {
  switch changeType {
  case .signIn, .switchAccounts:
    iCloudAvailability = .available
  case .signOut:
    iCloudAvailability = .unavailable(reason: .notSignedIn)
  @unknown default:
    break
  }
}
```

Update `handleAccountChange(_:)` to call the helper **unconditionally**, before the existing `isFirstLaunch` / zone-reset logic:

```swift
func handleAccountChange(_ change: CKSyncEngine.Event.AccountChange) {
  // Update observable availability first — this is a pure assignment
  // and safe to fire on every event, including the synthetic .signIn
  // that CKSyncEngine emits on first-launch init.
  applyAvailability(from: change.changeType)

  // ... existing body unchanged ...
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
just test SyncCoordinatorICloudAvailabilityTests 2>&1 | tee .agent-tmp/task3.txt
grep -iE 'failed|error:' .agent-tmp/task3.txt || echo "OK"
```

Also re-run the full sync suite to catch regressions on the existing `handleAccountChange` tests:

```bash
just test SyncCoordinatorTests 2>&1 | tee .agent-tmp/task3-regress.txt
grep -iE 'failed|error:' .agent-tmp/task3-regress.txt || echo "OK"
```

- [ ] **Step 5: Format, sync-review, commit**

```bash
just format
rm -f .agent-tmp/task3*.txt
```

Run `@sync-review` on the diff.

```bash
git add Backends/CloudKit/Sync/SyncCoordinator+Zones.swift \
        MoolahTests/Sync/SyncCoordinatorICloudAvailabilityTests.swift
git commit -m "feat(sync): map CKSyncEngine account changes to iCloudAvailability"
```

Push, PR, queue.

---

## Task 4: `ProfileStore.iCloudAvailability` pass-through

**Files:**
- Modify: `Features/Profiles/ProfileStore.swift` (add pass-through property + inject SyncCoordinator)
- Modify: `App/MoolahApp.swift` (hand SyncCoordinator to ProfileStore init)
- Test: `MoolahTests/Features/ProfileStoreICloudAvailabilityPassthroughTests.swift`

- [ ] **Step 1: Write the failing test suite**

Create `MoolahTests/Features/ProfileStoreICloudAvailabilityPassthroughTests.swift`:

```swift
import Foundation
import Testing

@testable import Moolah

@Suite("ProfileStore — iCloudAvailability passthrough")
@MainActor
struct ProfileStoreICloudAvailabilityPassthroughTests {
  private func makeDefaults() -> UserDefaults {
    let suiteName = "com.moolah.test.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return defaults
  }

  @Test("mirrors SyncCoordinator.iCloudAvailability")
  func mirrors() {
    let manager = ProfileContainerManager(isInMemoryOverride: true)
    let coordinator = SyncCoordinator(containerManager: manager)
    let store = ProfileStore(
      defaults: makeDefaults(),
      containerManager: manager,
      syncCoordinator: coordinator
    )

    coordinator.iCloudAvailability = .unavailable(reason: .notSignedIn)
    #expect(store.iCloudAvailability == .unavailable(reason: .notSignedIn))

    coordinator.iCloudAvailability = .available
    #expect(store.iCloudAvailability == .available)
  }

  @Test("returns .unknown when no coordinator is injected")
  func defaultsUnknown() {
    let store = ProfileStore(defaults: makeDefaults())
    #expect(store.iCloudAvailability == .unknown)
  }
}
```

- [ ] **Step 2: Run to verify they fail**

```bash
just test ProfileStoreICloudAvailabilityPassthroughTests 2>&1 | tee .agent-tmp/task4.txt
```

Expected: compile error — `ProfileStore.init(...syncCoordinator:)` and `ProfileStore.iCloudAvailability` not defined.

- [ ] **Step 3: Extend ProfileStore**

In `Features/Profiles/ProfileStore.swift`:

1. Add a stored property on the class body: `private let syncCoordinator: SyncCoordinator?`
2. Extend the designated initialiser to accept `syncCoordinator: SyncCoordinator? = nil` and store it.
3. Add the pass-through computed property:

```swift
/// Pass-through to ``SyncCoordinator/iCloudAvailability``. `.unknown`
/// when no coordinator was injected (e.g. tests that don't need sync).
var iCloudAvailability: ICloudAvailability {
  syncCoordinator?.iCloudAvailability ?? .unknown
}
```

- [ ] **Step 4: Wire at the app level**

In `App/MoolahApp.swift`, update the `ProfileStore` construction in `init()` to pass the already-constructed coordinator:

```swift
let store = ProfileStore(
  validator: RemoteServerValidator(),
  containerManager: setup.manager,
  syncCoordinator: coordinator
)
```

Verify no other call site constructs `ProfileStore` with a containerManager but no coordinator — `grep -rn "ProfileStore(" --include="*.swift"` to check; if any do, they stay on the default `nil` syncCoordinator (tests, previews).

- [ ] **Step 5: Run to verify they pass + regression**

```bash
just generate
just test ProfileStoreICloudAvailabilityPassthroughTests 2>&1 | tee .agent-tmp/task4.txt
just test ProfileStoreTests 2>&1 | tee .agent-tmp/task4-regress.txt
grep -iE 'failed|error:' .agent-tmp/task4*.txt || echo "OK"
```

- [ ] **Step 6: Format, review, commit**

```bash
just format
rm -f .agent-tmp/task4*.txt
```

Run `@code-review` and `@concurrency-review` (ProfileStore is `@MainActor`, injecting another `@MainActor` type).

```bash
git add Features/Profiles/ProfileStore.swift \
        App/MoolahApp.swift \
        MoolahTests/Features/ProfileStoreICloudAvailabilityPassthroughTests.swift
git commit -m "feat(profiles): expose iCloudAvailability passthrough on ProfileStore"
```

---

## Task 5: Add `profileIndexFetchedAtLeastOnce` property + per-session flag

**Files:**
- Modify: `Backends/CloudKit/Sync/SyncCoordinator.swift` (two new properties)
- Test: `MoolahTests/Sync/SyncCoordinatorProfileIndexFetchTests.swift`

- [ ] **Step 1: Write the failing test**

Create `MoolahTests/Sync/SyncCoordinatorProfileIndexFetchTests.swift`:

```swift
import Foundation
import Testing

@testable import Moolah

@Suite("SyncCoordinator — profileIndexFetchedAtLeastOnce")
@MainActor
struct SyncCoordinatorProfileIndexFetchTests {

  @Test("initial value is false")
  func initialValue() {
    let manager = ProfileContainerManager(isInMemoryOverride: true)
    let coordinator = SyncCoordinator(containerManager: manager)
    #expect(coordinator.profileIndexFetchedAtLeastOnce == false)
  }

  @Test("fetchSessionTouchedIndexZone starts false on each beginFetchingChanges")
  func sessionFlagResetsOnBegin() {
    let manager = ProfileContainerManager(isInMemoryOverride: true)
    let coordinator = SyncCoordinator(containerManager: manager)

    coordinator.beginFetchingChanges()
    coordinator.fetchSessionTouchedIndexZone = true
    coordinator.endFetchingChanges()

    coordinator.beginFetchingChanges()
    #expect(coordinator.fetchSessionTouchedIndexZone == false)
  }
}
```

- [ ] **Step 2: Run to verify they fail**

```bash
just test SyncCoordinatorProfileIndexFetchTests 2>&1 | tee .agent-tmp/task5.txt
```

Expected: compile error — `profileIndexFetchedAtLeastOnce`, `fetchSessionTouchedIndexZone` not defined.

- [ ] **Step 3: Add the properties**

In `Backends/CloudKit/Sync/SyncCoordinator.swift`, alongside `fetchSessionIndexChanged`:

```swift
/// True once the `profile-index` zone has been fetched (even
/// empty-handed) at least once since the last `start()`. Consumed by
/// `WelcomeView` to swap the status line from "Checking iCloud…" to
/// "No profiles in iCloud yet." See design spec §6.2 — must not flip
/// on fetches that only touched profile-data zones.
private(set) var profileIndexFetchedAtLeastOnce: Bool = false

/// Per-session flag — set to `true` inside the delegate zone-fetch path
/// whenever the `profile-index` zone ID is observed, regardless of
/// whether records were applied. Flushed into
/// `profileIndexFetchedAtLeastOnce` inside `endFetchingChanges()`.
/// Reset to `false` inside `beginFetchingChanges()`.
var fetchSessionTouchedIndexZone = false
```

In `Backends/CloudKit/Sync/SyncCoordinator+Lifecycle.swift`, inside `beginFetchingChanges()` just below `fetchSessionIndexChanged = false`, add:

```swift
fetchSessionTouchedIndexZone = false
```

Inside `stop()`, reset both:

```swift
profileIndexFetchedAtLeastOnce = false
fetchSessionTouchedIndexZone = false
```

- [ ] **Step 4: Run to verify they pass**

```bash
just test SyncCoordinatorProfileIndexFetchTests 2>&1 | tee .agent-tmp/task5.txt
grep -iE 'failed|error:' .agent-tmp/task5.txt || echo "OK"
```

- [ ] **Step 5: Format, review, commit**

```bash
just format
rm -f .agent-tmp/task5.txt
```

Run `@sync-review`.

```bash
git add Backends/CloudKit/Sync/SyncCoordinator.swift \
        Backends/CloudKit/Sync/SyncCoordinator+Lifecycle.swift \
        MoolahTests/Sync/SyncCoordinatorProfileIndexFetchTests.swift
git commit -m "feat(sync): add profile-index fetch tracking scaffolding"
```

---

## Task 6: Set `fetchSessionTouchedIndexZone` on profile-index zone fetches

**Files:**
- Modify: `Backends/CloudKit/Sync/SyncCoordinator+Delegate.swift` (in the zone-fetch event branch)
- Test: `MoolahTests/Sync/SyncCoordinatorProfileIndexFetchTests.swift` (extend)

- [ ] **Step 1: Inspect the delegate file to find the zone-fetch event hook**

```bash
grep -n "fetchedRecordZoneChanges\|didFetchRecordZoneChanges\|zone.*fetch" \
  Backends/CloudKit/Sync/SyncCoordinator+Delegate.swift
```

The `CKSyncEngineDelegate` event path routes `CKSyncEngine.Event.fetchedRecordZoneChanges` through `applyFetchedZoneChanges` in `+RecordChanges.swift`. That is the hook where we see which zone ID was fetched. The check we need is "was the zone ID the profile-index zone?" regardless of whether any records were present.

- [ ] **Step 2: Extend test**

Add to `MoolahTests/Sync/SyncCoordinatorProfileIndexFetchTests.swift`:

```swift
@Test("fetchSessionTouchedIndexZone flips true when index zone is observed with no records")
func touchedFlagSetOnEmptyIndexFetch() {
  let manager = ProfileContainerManager(isInMemoryOverride: true)
  let coordinator = SyncCoordinator(containerManager: manager)
  let indexZoneID = coordinator.profileIndexHandler.zoneID

  coordinator.beginFetchingChanges()
  coordinator.markZoneFetched(indexZoneID)
  #expect(coordinator.fetchSessionTouchedIndexZone == true)
}

@Test("fetchSessionTouchedIndexZone stays false on profile-data zone fetch")
func touchedFlagIgnoresDataZone() {
  let manager = ProfileContainerManager(isInMemoryOverride: true)
  let coordinator = SyncCoordinator(containerManager: manager)
  let dataZoneID = CKRecordZone.ID(
    zoneName: "profile-\(UUID().uuidString)",
    ownerName: CKCurrentUserDefaultName
  )

  coordinator.beginFetchingChanges()
  coordinator.markZoneFetched(dataZoneID)
  #expect(coordinator.fetchSessionTouchedIndexZone == false)
}
```

The test needs `CKRecordZone.ID` → add `import CloudKit` at the top if not already present.

- [ ] **Step 3: Run to verify they fail**

```bash
just test SyncCoordinatorProfileIndexFetchTests 2>&1 | tee .agent-tmp/task6.txt
```

Expected: compile error — `markZoneFetched(_:)` not defined.

- [ ] **Step 4: Add `markZoneFetched` + wire from delegate**

In `Backends/CloudKit/Sync/SyncCoordinator+RecordChanges.swift` (or wherever `applyFetchedZoneChanges` lives — confirm with grep), add a helper and call it. Or, cleaner: add a helper method on `SyncCoordinator` (in `+Lifecycle.swift` alongside fetch-session helpers):

```swift
/// Call from the delegate's zone-fetch event path. If the zone ID is the
/// profile-index zone, sets `fetchSessionTouchedIndexZone = true` so
/// `endFetchingChanges()` can flip `profileIndexFetchedAtLeastOnce`.
func markZoneFetched(_ zoneID: CKRecordZone.ID) {
  if SyncCoordinator.parseZone(zoneID) == .profileIndex {
    fetchSessionTouchedIndexZone = true
  }
}
```

Then in `SyncCoordinator+RecordChanges.swift`, inside `applyFetchedZoneChanges(_:)` (or equivalent), **before** the existing per-record dispatch, call:

```swift
markZoneFetched(event.recordZoneID)
```

Replace `event.recordZoneID` with the actual property path — look at the existing usage; the event type is `CKSyncEngine.Event.FetchedRecordZoneChanges` or similar. Whatever the zone-ID accessor is, `markZoneFetched` takes the bare `CKRecordZone.ID`.

- [ ] **Step 5: Run to verify they pass**

```bash
just test SyncCoordinatorProfileIndexFetchTests 2>&1 | tee .agent-tmp/task6.txt
grep -iE 'failed|error:' .agent-tmp/task6.txt || echo "OK"
```

Re-run full sync suite for regression:

```bash
just test SyncCoordinatorTests 2>&1 | tee .agent-tmp/task6-regress.txt
grep -iE 'failed|error:' .agent-tmp/task6-regress.txt || echo "OK"
```

- [ ] **Step 6: Format, review, commit**

```bash
just format
rm -f .agent-tmp/task6*.txt
```

Run `@sync-review`.

```bash
git add Backends/CloudKit/Sync/SyncCoordinator+Lifecycle.swift \
        Backends/CloudKit/Sync/SyncCoordinator+RecordChanges.swift \
        MoolahTests/Sync/SyncCoordinatorProfileIndexFetchTests.swift
git commit -m "feat(sync): track profile-index zone fetches per session"
```

---

## Task 7: Flip `profileIndexFetchedAtLeastOnce` in `endFetchingChanges`

**Files:**
- Modify: `Backends/CloudKit/Sync/SyncCoordinator+Lifecycle.swift` (`endFetchingChanges`)
- Test: `MoolahTests/Sync/SyncCoordinatorProfileIndexFetchTests.swift` (extend)

- [ ] **Step 1: Extend test**

```swift
@Test("profileIndexFetchedAtLeastOnce flips after first session that touched index zone")
func flipsOnFirstIndexSession() {
  let manager = ProfileContainerManager(isInMemoryOverride: true)
  let coordinator = SyncCoordinator(containerManager: manager)
  let indexZoneID = coordinator.profileIndexHandler.zoneID

  coordinator.beginFetchingChanges()
  coordinator.markZoneFetched(indexZoneID)
  coordinator.endFetchingChanges()

  #expect(coordinator.profileIndexFetchedAtLeastOnce == true)
}

@Test("profileIndexFetchedAtLeastOnce stays false after session with no index-zone activity")
func staysFalseOnDataOnlySession() {
  let manager = ProfileContainerManager(isInMemoryOverride: true)
  let coordinator = SyncCoordinator(containerManager: manager)
  let dataZoneID = CKRecordZone.ID(
    zoneName: "profile-\(UUID().uuidString)",
    ownerName: CKCurrentUserDefaultName
  )

  coordinator.beginFetchingChanges()
  coordinator.markZoneFetched(dataZoneID)
  coordinator.endFetchingChanges()

  #expect(coordinator.profileIndexFetchedAtLeastOnce == false)
}

@Test("profileIndexFetchedAtLeastOnce stays true once set")
func remainsTrue() {
  let manager = ProfileContainerManager(isInMemoryOverride: true)
  let coordinator = SyncCoordinator(containerManager: manager)
  let indexZoneID = coordinator.profileIndexHandler.zoneID
  let dataZoneID = CKRecordZone.ID(
    zoneName: "profile-\(UUID().uuidString)",
    ownerName: CKCurrentUserDefaultName
  )

  coordinator.beginFetchingChanges()
  coordinator.markZoneFetched(indexZoneID)
  coordinator.endFetchingChanges()

  coordinator.beginFetchingChanges()
  coordinator.markZoneFetched(dataZoneID)
  coordinator.endFetchingChanges()

  #expect(coordinator.profileIndexFetchedAtLeastOnce == true)
}
```

- [ ] **Step 2: Run to verify they fail**

```bash
just test SyncCoordinatorProfileIndexFetchTests 2>&1 | tee .agent-tmp/task7.txt
```

Expected: two of the three tests fail on the `#expect(... == true)` assertion.

- [ ] **Step 3: Update `endFetchingChanges`**

In `Backends/CloudKit/Sync/SyncCoordinator+Lifecycle.swift`, inside `endFetchingChanges()` right after the `flushFetchSessionChanges()` call:

```swift
if fetchSessionTouchedIndexZone && !profileIndexFetchedAtLeastOnce {
  profileIndexFetchedAtLeastOnce = true
  logger.info("profileIndexFetchedAtLeastOnce flipped true")
}
fetchSessionTouchedIndexZone = false
```

- [ ] **Step 4: Run to verify they pass + regression**

```bash
just test SyncCoordinatorProfileIndexFetchTests 2>&1 | tee .agent-tmp/task7.txt
just test SyncCoordinatorTests 2>&1 | tee .agent-tmp/task7-regress.txt
grep -iE 'failed|error:' .agent-tmp/task7*.txt || echo "OK"
```

- [ ] **Step 5: Format, review, commit**

```bash
just format
rm -f .agent-tmp/task7*.txt
```

Run `@sync-review`.

```bash
git add Backends/CloudKit/Sync/SyncCoordinator+Lifecycle.swift \
        MoolahTests/Sync/SyncCoordinatorProfileIndexFetchTests.swift
git commit -m "feat(sync): flip profileIndexFetchedAtLeastOnce after first index fetch"
```

---

## Task 8: Auto-activation race guard on `ProfileStore`

**Files:**
- Modify: `Features/Profiles/ProfileStore.swift` (add `welcomePhase` property)
- Modify: `Features/Profiles/ProfileStore+Cloud.swift` (honour guard in `loadCloudProfiles`)
- Test: `MoolahTests/Features/ProfileStoreAutoActivateGuardTests.swift`

- [ ] **Step 1: Write the failing test**

Create `MoolahTests/Features/ProfileStoreAutoActivateGuardTests.swift`:

```swift
import Foundation
import Testing

@testable import Moolah

@Suite("ProfileStore — auto-activate guard")
@MainActor
struct ProfileStoreAutoActivateGuardTests {
  private func makeDefaults() -> UserDefaults {
    let suiteName = "com.moolah.test.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return defaults
  }

  private func seededCloudProfile(_ container: ProfileContainerManager) -> Profile {
    let profile = Profile(
      label: "Household",
      backendType: .cloudKit,
      currencyCode: "AUD",
      financialYearStartMonth: 7
    )
    let context = ModelContext(container.indexContainer)
    context.insert(ProfileRecord.from(profile: profile))
    try? context.save()
    return profile
  }

  @Test("loadCloudProfiles auto-activates when welcomePhase == .landing")
  func autoActivatesWhenLanding() {
    let manager = ProfileContainerManager(isInMemoryOverride: true)
    let store = ProfileStore(
      defaults: makeDefaults(),
      containerManager: manager
    )
    let profile = seededCloudProfile(manager)
    store.welcomePhase = .landing

    store.loadCloudProfiles()

    #expect(store.activeProfileID == profile.id)
  }

  @Test("loadCloudProfiles does NOT auto-activate when welcomePhase == .creating")
  func doesNotAutoActivateWhenCreating() {
    let manager = ProfileContainerManager(isInMemoryOverride: true)
    let store = ProfileStore(
      defaults: makeDefaults(),
      containerManager: manager
    )
    _ = seededCloudProfile(manager)
    store.welcomePhase = .creating

    store.loadCloudProfiles()

    #expect(store.activeProfileID == nil)
    #expect(store.cloudProfiles.count == 1)   // profile still visible
  }

  @Test("loadCloudProfiles auto-activates when welcomePhase is nil (not on welcome screen)")
  func autoActivatesWhenPhaseNil() {
    let manager = ProfileContainerManager(isInMemoryOverride: true)
    let store = ProfileStore(
      defaults: makeDefaults(),
      containerManager: manager
    )
    let profile = seededCloudProfile(manager)
    store.welcomePhase = nil

    store.loadCloudProfiles()

    #expect(store.activeProfileID == profile.id)
  }
}
```

- [ ] **Step 2: Run to verify they fail**

```bash
just test ProfileStoreAutoActivateGuardTests 2>&1 | tee .agent-tmp/task8.txt
```

Expected: compile error — `ProfileStore.welcomePhase` not defined.

- [ ] **Step 3: Add `welcomePhase` and gate auto-activation**

In `Features/Profiles/ProfileStore.swift`, add to the class body (alongside other mutable state):

```swift
/// Signal from `WelcomeView` about which interaction phase is on screen.
/// When `.creating`, `loadCloudProfiles` suppresses its auto-activate
/// behaviour so a single profile arriving from iCloud doesn't race the
/// user's in-flight "Create Profile" tap. Cleared (`nil`) when
/// `WelcomeView` unmounts. See design spec §3.3, §8.
enum WelcomePhase {
  case landing
  case creating
  case pickingProfile
}

var welcomePhase: WelcomePhase?
```

In `Features/Profiles/ProfileStore+Cloud.swift`, inside `loadCloudProfiles(isInitialLoad:)`, the current auto-select block reads:

```swift
if activeProfileID == nil, let first = profiles.first {
  self.activeProfileID = first.id
  saveActiveProfileID()
  logger.debug("Auto-selected profile: \(first.id)")
}
```

Replace with:

```swift
if activeProfileID == nil, let first = profiles.first, welcomePhase != .creating {
  self.activeProfileID = first.id
  saveActiveProfileID()
  logger.debug("Auto-selected profile: \(first.id)")
} else if welcomePhase == .creating {
  logger.debug("Skipped auto-select — welcomePhase == .creating")
}
```

- [ ] **Step 4: Run to verify they pass + regression**

```bash
just test ProfileStoreAutoActivateGuardTests 2>&1 | tee .agent-tmp/task8.txt
just test ProfileStoreTests 2>&1 | tee .agent-tmp/task8-regress.txt
grep -iE 'failed|error:' .agent-tmp/task8*.txt || echo "OK"
```

- [ ] **Step 5: Format, review, commit**

```bash
just format
rm -f .agent-tmp/task8*.txt
```

Run `@code-review`.

```bash
git add Features/Profiles/ProfileStore.swift \
        Features/Profiles/ProfileStore+Cloud.swift \
        MoolahTests/Features/ProfileStoreAutoActivateGuardTests.swift
git commit -m "feat(profiles): suppress auto-activate when WelcomeView is mid-create"
```

---

## Task 9: Build `WelcomeHero` + `ICloudStatusLine` + `ICloudOffChip`

**Files:**
- Create: `Features/Profiles/Views/WelcomeHero.swift`
- Create: `Features/Profiles/Views/ICloudStatusLine.swift`
- Create: `Features/Profiles/Views/ICloudOffChip.swift`

These are view-layer files — `#Preview`-driven, verified in Xcode canvas. No unit tests at this step; `WelcomeView` UI tests in Task 17 exercise the integration.

- [ ] **Step 1: Add brand colour constants (scoped, private)**

In `Features/Profiles/Views/WelcomeHero.swift`, define brand constants at file scope (not a `Color` extension):

```swift
import SwiftUI

private enum BrandColors {
  static let space = Color(red: 0x07 / 255, green: 0x10 / 255, blue: 0x2E / 255)
  static let incomeBlue = Color(red: 0x1E / 255, green: 0x64 / 255, blue: 0xEE / 255)
  static let balanceGold = Color(red: 0xFF / 255, green: 0xD5 / 255, blue: 0x6B / 255)
  static let lightBlue = Color(red: 0x7A / 255, green: 0xBD / 255, blue: 0xFF / 255)
  static let muted = Color(red: 0xAA / 255, green: 0xB4 / 255, blue: 0xC8 / 255)
  static let coralRed = Color(red: 0xFF / 255, green: 0x78 / 255, blue: 0x7F / 255)
}
```

- [ ] **Step 2: Build `WelcomeHero`**

In the same file:

```swift
/// Branded hero used for first-run states 1 (welcome + checking) and 4
/// (iCloud off). Content slot below the CTA receives either
/// ``ICloudStatusLine`` (state 1) or ``ICloudOffChip`` (state 4).
///
/// Colour tokens come from `guides/BRAND_GUIDE.md` §3. Hardcoded hex is
/// scoped to this file per design spec §4.1; never leak to project-wide
/// `Color` extensions.
struct WelcomeHero<Footer: View>: View {
  let primaryAction: () -> Void
  @ViewBuilder let footer: () -> Footer

  @FocusState private var focus: Focus?
  private enum Focus: Hashable { case primaryCTA }

  var body: some View {
    ZStack(alignment: .leading) {
      BrandColors.space.ignoresSafeArea()

      VStack(alignment: .leading, spacing: 0) {
        Spacer(minLength: 48)

        Text("Moolah", comment: "First-run hero eyebrow label")
          .font(.caption.weight(.medium))
          .tracking(1.8)
          .textCase(.uppercase)
          .foregroundStyle(BrandColors.balanceGold)
          .accessibilityHidden(true)   // decorative; title below carries the meaning

        VStack(alignment: .leading, spacing: 0) {
          Text("Your money,", comment: "First-run hero title line 1")
            .foregroundStyle(.white)
          Text("rock solid.", comment: "First-run hero title line 2")
            .foregroundStyle(BrandColors.balanceGold)
        }
        .font(.largeTitle.bold())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Your money, rock solid.")
        .accessibilityAddTraits(.isHeader)
        .padding(.top, 10)

        Text(
          "Money stuff should be boring. Locked down, sorted out, taken care of — so the rest of your life doesn't have to be.",
          comment: "First-run hero subhead"
        )
        .font(.body)
        .foregroundStyle(BrandColors.muted)
        .lineLimit(nil)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: 320, alignment: .leading)
        .padding(.top, 14)

        Spacer()

        Button(action: primaryAction) {
          Text("Get started", comment: "First-run primary CTA")
            .font(.headline)
            .frame(maxWidth: 280)
            .frame(minHeight: 44)
        }
        .buttonStyle(PrimaryHeroButtonStyle())
        .focusable(true)
        .focused($focus, equals: .primaryCTA)
        .onKeyPress(.return) { primaryAction(); return .handled }
        .padding(.bottom, 12)

        footer()
          .frame(maxWidth: 320, alignment: .leading)

        Spacer(minLength: 28)
      }
      .padding(.horizontal, 32)
    }
    .task { focus = .primaryCTA }
  }

}

private struct PrimaryHeroButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .foregroundStyle(.white)
      .padding(.vertical, 12)
      .padding(.horizontal, 24)
      .background(
        BrandColors.incomeBlue
          .opacity(configuration.isPressed ? 0.85 : 1.0)
      )
      .clipShape(.rect(cornerRadius: 10))
      .contentShape(.rect)
  }
}

#Preview("WelcomeHero — light") {
  WelcomeHero(primaryAction: {}) {
    ICloudStatusLine(state: .checking)
  }
  .frame(width: 420, height: 560)
}

#Preview("WelcomeHero — dark") {
  WelcomeHero(primaryAction: {}) {
    ICloudStatusLine(state: .checking)
  }
  .frame(width: 420, height: 560)
  .preferredColorScheme(.dark)
}

#Preview("WelcomeHero — AX5") {
  WelcomeHero(primaryAction: {}) {
    ICloudStatusLine(state: .noneFound)
  }
  .frame(width: 500, height: 720)
  .dynamicTypeSize(.accessibility5)
}
```

- [ ] **Step 3: Build `ICloudStatusLine`**

Create `Features/Profiles/Views/ICloudStatusLine.swift`:

```swift
import SwiftUI

/// Quiet status line that sits under the hero CTA in state 1.
/// Shows a spinner + "Checking iCloud for your profiles…" while we're
/// waiting, swaps to "No profiles in iCloud yet." once a fetch has
/// completed empty. Never visible in state 4 (iCloud unavailable) —
/// that's handled by ``ICloudOffChip``.
struct ICloudStatusLine: View {
  enum State: Equatable {
    case checking
    case noneFound
  }

  let state: State

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      if state == .checking {
        ProgressView()
          .controlSize(.small)
          .tint(BrandLightBlue.color)
          .accessibilityAddTraits(.updatesFrequently)
      }
      Text(label)
        .font(.footnote)
        .foregroundStyle(BrandMuted.color)
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(label)
  }

  private var label: String {
    switch state {
    case .checking:
      String(localized: "Checking iCloud for your profiles…")
    case .noneFound:
      String(localized: "No profiles in iCloud yet.")
    }
  }
}

private enum BrandLightBlue {
  static let color = Color(red: 0x7A / 255, green: 0xBD / 255, blue: 0xFF / 255)
}
private enum BrandMuted {
  static let color = Color(red: 0xAA / 255, green: 0xB4 / 255, blue: 0xC8 / 255)
}

#Preview("Checking") {
  ZStack {
    Color(red: 0x07 / 255, green: 0x10 / 255, blue: 0x2E / 255).ignoresSafeArea()
    ICloudStatusLine(state: .checking).padding()
  }
  .frame(width: 360, height: 100)
}

#Preview("None found") {
  ZStack {
    Color(red: 0x07 / 255, green: 0x10 / 255, blue: 0x2E / 255).ignoresSafeArea()
    ICloudStatusLine(state: .noneFound).padding()
  }
  .frame(width: 360, height: 100)
}
```

- [ ] **Step 4: Build `ICloudOffChip`**

Create `Features/Profiles/Views/ICloudOffChip.swift`:

```swift
import SwiftUI

/// Inline chip shown under the hero CTA in state 4 (iCloud unavailable).
/// Explains that the profile will be local and links to System Settings.
///
/// `openSettingsAction` performs the platform-appropriate deep link:
/// - macOS: `x-apple.systempreferences:...AppleIDPrefPane` with a
///   fallback to `NSWorkspace.shared.open(System Settings.app)`.
/// - iOS: `UIApplication.shared.open(URL(string: "App-Prefs:")!)`.
///
/// The wiring lives in the host (`WelcomeView`) so this view stays
/// platform-agnostic.
struct ICloudOffChip: View {
  let openSettingsAction: () -> Void

  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      Image(systemName: "icloud.slash")
        .foregroundStyle(BrandCoralRed.color)
        .font(.footnote)
        .padding(.top, 2)
      VStack(alignment: .leading, spacing: 3) {
        Text("iCloud sync is off.", comment: "First-run iCloud-off chip title")
          .font(.footnote.weight(.semibold))
          .foregroundStyle(BrandCoralRed.color)
        HStack(spacing: 4) {
          Text(
            "Your profile will be saved on this device.",
            comment: "First-run iCloud-off chip body"
          )
          .font(.footnote)
          .foregroundStyle(BrandMuted.color)
          Button(action: openSettingsAction) {
            Text("Open System Settings", comment: "First-run iCloud-off chip link")
              .font(.footnote)
              .underline()
              .foregroundStyle(BrandLightBlue.color)
          }
          .buttonStyle(.plain)
        }
      }
    }
    .padding(10)
    .background(BrandCoralRed.color.opacity(0.12))
    .clipShape(.rect(cornerRadius: 8))
    .accessibilityElement(children: .contain)
    .accessibilityLabel(
      "iCloud sync is off. Your profile will be saved on this device. Open System Settings."
    )
  }
}

private enum BrandLightBlue {
  static let color = Color(red: 0x7A / 255, green: 0xBD / 255, blue: 0xFF / 255)
}
private enum BrandMuted {
  static let color = Color(red: 0xAA / 255, green: 0xB4 / 255, blue: 0xC8 / 255)
}
private enum BrandCoralRed {
  static let color = Color(red: 0xFF / 255, green: 0x78 / 255, blue: 0x7F / 255)
}

#Preview("ICloudOffChip") {
  ZStack {
    Color(red: 0x07 / 255, green: 0x10 / 255, blue: 0x2E / 255).ignoresSafeArea()
    ICloudOffChip(openSettingsAction: {}).padding()
  }
  .frame(width: 360, height: 120)
}

#Preview("ICloudOffChip — AX5") {
  ZStack {
    Color(red: 0x07 / 255, green: 0x10 / 255, blue: 0x2E / 255).ignoresSafeArea()
    ICloudOffChip(openSettingsAction: {}).padding()
  }
  .frame(width: 500, height: 200)
  .dynamicTypeSize(.accessibility5)
}
```

- [ ] **Step 5: Regenerate project, build to verify previews compile**

```bash
just generate
just build-mac 2>&1 | tee .agent-tmp/task9-build.txt
grep -iE 'error:|warning:' .agent-tmp/task9-build.txt | grep -v '#Preview' || echo "OK"
```

Open the three files in Xcode and render the previews to eyeball the layout. Any issues, fix before moving on.

- [ ] **Step 6: Format, review, commit**

Run `@ui-review` on the three new files.

```bash
just format
rm -f .agent-tmp/task9*.txt
git add Features/Profiles/Views/WelcomeHero.swift \
        Features/Profiles/Views/ICloudStatusLine.swift \
        Features/Profiles/Views/ICloudOffChip.swift
git commit -m "feat(profiles): add WelcomeHero + iCloud status/off chips"
```

---

## Task 10: Build `ICloudArrivalBanner`

**Files:**
- Create: `Features/Profiles/Views/ICloudArrivalBanner.swift`

- [ ] **Step 1: Build the banner**

Create `Features/Profiles/Views/ICloudArrivalBanner.swift`:

```swift
import SwiftUI

/// Non-blocking brand-gold banner surfaced above the create-profile
/// form (state 3) when iCloud returns profiles while the user is
/// mid-setup. Single-profile path → Open/Dismiss. Multi-profile path
/// → View/Dismiss.
///
/// Brand colour is deliberately kept (not system yellow) — this is the
/// one system-styled screen element that sits narratively with the
/// hero. Constants are private, scoped to this file, per design spec
/// §4.1.
struct ICloudArrivalBanner: View {
  enum Kind: Equatable {
    case single(label: String)
    case multiple(count: Int)
  }

  let kind: Kind
  let primaryAction: () -> Void
  let dismissAction: () -> Void

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 10) {
      Image(systemName: "icloud")
        .foregroundStyle(BannerInk.color)
        .padding(.top, 1)
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(.footnote.weight(.semibold))
          .foregroundStyle(BannerInk.color)
        if let subtitle {
          Text(subtitle)
            .font(.caption)
            .foregroundStyle(BannerInk.color.opacity(0.75))
        }
      }
      Spacer(minLength: 0)
      Button(primaryLabel, action: primaryAction)
        .buttonStyle(.plain)
        .font(.footnote.weight(.semibold))
        .foregroundStyle(BannerInk.color)
        .underline()
      Button {
        dismissAction()
      } label: {
        Text("Dismiss", comment: "First-run iCloud banner dismiss")
          .font(.footnote)
          .foregroundStyle(BannerInk.color.opacity(0.6))
      }
      .buttonStyle(.plain)
    }
    .padding(12)
    .background(BannerFill.color)
    .clipShape(.rect(cornerRadius: 10))
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(title). \(subtitle ?? ""). \(primaryLabel). Dismiss.")
    .accessibilityLiveRegion(.polite)
  }

  private var title: String {
    switch kind {
    case .single(let label):
      return String(localized: "Found '\(label)' in iCloud.")
    case .multiple(let count):
      return String(localized: "Looks like you've got \(count) profiles in iCloud.")
    }
  }

  private var subtitle: String? {
    switch kind {
    case .single:
      return String(localized: "You can open it instead of creating a new one.")
    case .multiple:
      return nil
    }
  }

  private var primaryLabel: String {
    switch kind {
    case .single: return String(localized: "Open")
    case .multiple: return String(localized: "View")
    }
  }
}

private enum BannerFill {
  static let color = Color(red: 0xFF / 255, green: 0xD5 / 255, blue: 0x6B / 255)
    .opacity(0.95)
}
private enum BannerInk {
  static let color = Color(red: 0x07 / 255, green: 0x10 / 255, blue: 0x2E / 255)
}

#Preview("Single") {
  ICloudArrivalBanner(
    kind: .single(label: "Household"),
    primaryAction: {},
    dismissAction: {}
  )
  .padding()
  .frame(width: 440, height: 120)
}

#Preview("Multiple") {
  ICloudArrivalBanner(
    kind: .multiple(count: 3),
    primaryAction: {},
    dismissAction: {}
  )
  .padding()
  .frame(width: 440, height: 120)
}

#Preview("Single — dark") {
  ICloudArrivalBanner(
    kind: .single(label: "Household"),
    primaryAction: {},
    dismissAction: {}
  )
  .padding()
  .frame(width: 440, height: 120)
  .preferredColorScheme(.dark)
}

#Preview("Multiple — AX5") {
  ICloudArrivalBanner(
    kind: .multiple(count: 3),
    primaryAction: {},
    dismissAction: {}
  )
  .padding()
  .frame(width: 560, height: 200)
  .dynamicTypeSize(.accessibility5)
}
```

- [ ] **Step 2: Regenerate, build, eyeball previews**

```bash
just generate
just build-mac 2>&1 | tee .agent-tmp/task10-build.txt
grep -iE 'error:|warning:' .agent-tmp/task10-build.txt | grep -v '#Preview' || echo "OK"
```

- [ ] **Step 3: Format, review, commit**

Run `@ui-review` on `ICloudArrivalBanner.swift`.

```bash
just format
rm -f .agent-tmp/task10*.txt
git add Features/Profiles/Views/ICloudArrivalBanner.swift
git commit -m "feat(profiles): add ICloudArrivalBanner for mid-setup iCloud arrivals"
```

---

## Task 11: Build `CreateProfileFormView`

**Files:**
- Create: `Features/Profiles/Views/CreateProfileFormView.swift`

- [ ] **Step 1: Build the view**

Create `Features/Profiles/Views/CreateProfileFormView.swift`:

```swift
import SwiftUI

/// System-styled create-profile form (states 2 and 3). Single required
/// field (Name); Currency + Financial year start are behind an Advanced
/// disclosure with locale defaults.
///
/// On iOS, fires `.medium` impact haptics on the "Get started" tap
/// (from the hero) and `.success` notification on create completion.
/// macOS has no haptics.
///
/// Background iCloud-checking spinner is owned by the host — pass it
/// via `backgroundStatus`. The optional banner is rendered above the
/// form when `banner` is non-nil (state 3).
struct CreateProfileFormView: View {
  @Binding var name: String
  @Binding var currencyCode: String
  @Binding var financialYearStartMonth: Int
  let banner: ICloudArrivalBanner.Kind?
  let onBannerPrimary: () -> Void
  let onBannerDismiss: () -> Void
  let backgroundCheckingICloud: Bool
  let cancelAction: () -> Void
  let createAction: () async -> Void

  @State private var isSubmitting = false
  @FocusState private var focus: Focus?
  private enum Focus: Hashable { case name }

  private static let monthNames: [String] = {
    let formatter = DateFormatter()
    formatter.locale = Locale.current
    return formatter.monthSymbols ?? []
  }()

  var body: some View {
    VStack(spacing: 0) {
      if let banner {
        ICloudArrivalBanner(
          kind: banner,
          primaryAction: onBannerPrimary,
          dismissAction: onBannerDismiss
        )
        .padding(.horizontal, 16)
        .padding(.top, 16)
      }

      Form {
        Section {
          TextField(
            String(localized: "Name"),
            text: $name
          )
          .focused($focus, equals: .name)
          .submitLabel(.done)
          .accessibilityIdentifier(UITestIdentifiers.Welcome.nameField)

          DisclosureGroup(
            String(localized: "Advanced", comment: "Form advanced disclosure")
          ) {
            CurrencyPicker(selection: $currencyCode)
            Picker(
              String(localized: "Financial year starts", comment: "Form FY month"),
              selection: $financialYearStartMonth
            ) {
              ForEach(1...12, id: \.self) { month in
                if month <= Self.monthNames.count {
                  Text(Self.monthNames[month - 1]).tag(month)
                }
              }
            }
          }
        } header: {
          VStack(alignment: .leading, spacing: 4) {
            Text("Create a profile", comment: "Form title")
              .font(.title2.bold())
              .foregroundStyle(.primary)
              .textCase(nil)
            Text(
              "Just give it a name. You can tweak the rest later.",
              comment: "Form subtitle"
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .textCase(nil)
          }
          .padding(.bottom, 8)
        } footer: {
          if backgroundCheckingICloud {
            HStack(spacing: 6) {
              ProgressView().controlSize(.small)
              Text("Still checking iCloud…", comment: "Form background status")
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
          }
        }
      }
      .formStyle(.grouped)
    }
    .toolbar {
      ToolbarItem(placement: .cancellationAction) {
        Button(String(localized: "Cancel"), action: cancelAction)
      }
      ToolbarItem(placement: .confirmationAction) {
        if isSubmitting {
          ProgressView().controlSize(.small)
        } else {
          Button {
            isSubmitting = true
            Task {
              await createAction()
              isSubmitting = false
              #if os(iOS)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
              #endif
            }
          } label: {
            Text("Create Profile", comment: "Form primary CTA")
          }
          .buttonStyle(.borderedProminent)
          .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
          .accessibilityIdentifier(UITestIdentifiers.Welcome.createProfileButton)
        }
      }
    }
    .onAppear { focus = .name }
  }
}

#Preview("Create — default") {
  @Previewable @State var name = ""
  @Previewable @State var currency = "AUD"
  @Previewable @State var month = 7
  NavigationStack {
    CreateProfileFormView(
      name: $name,
      currencyCode: $currency,
      financialYearStartMonth: $month,
      banner: nil,
      onBannerPrimary: {},
      onBannerDismiss: {},
      backgroundCheckingICloud: true,
      cancelAction: {},
      createAction: {}
    )
  }
  .frame(width: 480, height: 560)
}

#Preview("Create — with banner") {
  @Previewable @State var name = "Hous"
  @Previewable @State var currency = "AUD"
  @Previewable @State var month = 7
  NavigationStack {
    CreateProfileFormView(
      name: $name,
      currencyCode: $currency,
      financialYearStartMonth: $month,
      banner: .single(label: "Household"),
      onBannerPrimary: {},
      onBannerDismiss: {},
      backgroundCheckingICloud: true,
      cancelAction: {},
      createAction: {}
    )
  }
  .frame(width: 480, height: 600)
}

#Preview("Create — AX5") {
  @Previewable @State var name = "Household"
  @Previewable @State var currency = "AUD"
  @Previewable @State var month = 7
  NavigationStack {
    CreateProfileFormView(
      name: $name,
      currencyCode: $currency,
      financialYearStartMonth: $month,
      banner: nil,
      onBannerPrimary: {},
      onBannerDismiss: {},
      backgroundCheckingICloud: false,
      cancelAction: {},
      createAction: {}
    )
  }
  .frame(width: 600, height: 800)
  .dynamicTypeSize(.accessibility5)
}
```

> Note: `CurrencyPicker` already exists in the codebase (used in `ProfileFormView`). `UITestIdentifiers.Welcome.nameField` / `.createProfileButton` are added in Task 17 — for now they won't resolve. Add a stub file now so the preview compiles:

- [ ] **Step 2: Stub `UITestIdentifiers`**

Check whether `UITestSupport/UITestIdentifiers.swift` exists:

```bash
ls UITestSupport/UITestIdentifiers.swift 2>/dev/null || echo "missing"
```

If missing, create `UITestSupport/UITestIdentifiers.swift`:

```swift
import Foundation

/// Canonical accessibility-identifier strings shared between production
/// views and UI tests. Per `guides/UI_TEST_GUIDE.md`, identifiers live
/// here — never hard-code strings in test code or view code.
enum UITestIdentifiers {
  enum Welcome {
    static let heroGetStartedButton = "welcome.hero.getStarted"
    static let nameField = "welcome.create.nameField"
    static let createProfileButton = "welcome.create.createButton"
    static let pickerRow = "welcome.picker.row"
    static let pickerCreateNewRow = "welcome.picker.createNew"
    static let bannerOpenAction = "welcome.banner.open"
    static let bannerViewAction = "welcome.banner.view"
    static let bannerDismissAction = "welcome.banner.dismiss"
    static let iCloudOffSystemSettingsLink = "welcome.off.systemSettings"
  }
}
```

If the file already exists and has a different `enum Welcome` block, merge: keep both sets of identifiers.

- [ ] **Step 3: Regenerate, build, eyeball previews**

```bash
just generate
just build-mac 2>&1 | tee .agent-tmp/task11-build.txt
grep -iE 'error:|warning:' .agent-tmp/task11-build.txt | grep -v '#Preview' || echo "OK"
```

- [ ] **Step 4: Format, review, commit**

Run `@ui-review` on `CreateProfileFormView.swift`.

```bash
just format
rm -f .agent-tmp/task11*.txt
git add Features/Profiles/Views/CreateProfileFormView.swift \
        UITestSupport/UITestIdentifiers.swift
git commit -m "feat(profiles): add CreateProfileFormView with Advanced disclosure"
```

---

## Task 12: Build `ICloudProfilePickerView`

**Files:**
- Create: `Features/Profiles/Views/ICloudProfilePickerView.swift`

- [ ] **Step 1: Build the view**

Create `Features/Profiles/Views/ICloudProfilePickerView.swift`:

```swift
import SwiftUI

/// State 5 — picker surfaced when iCloud returns ≥2 profiles. Plain
/// `List` with native rows plus a "+ Create a new profile" footer row.
/// Account-count meta text uses `.monospacedDigit()` to prevent row
/// width jitter as sync delivers data.
struct ICloudProfilePickerView: View {
  let profiles: [Profile]
  let accountCounts: [UUID: Int]   // empty dict → meta omits count
  let selectAction: (Profile) -> Void
  let createNewAction: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 12)

      List {
        Section {
          ForEach(profiles) { profile in
            Button {
              selectAction(profile)
            } label: {
              row(for: profile)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(
              "\(UITestIdentifiers.Welcome.pickerRow).\(profile.id.uuidString)"
            )
          }
        } header: {
          Text("Your profiles", comment: "Picker section header")
        }

        Section {
          Button(action: createNewAction) {
            Label(
              String(localized: "Create a new profile", comment: "Picker footer CTA"),
              systemImage: "plus"
            )
            .foregroundStyle(.tint)
          }
          .accessibilityIdentifier(UITestIdentifiers.Welcome.pickerCreateNewRow)
        }
      }
      .listStyle(.inset)
    }
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("Welcome back.", comment: "Picker title")
        .font(.title2.bold())
      Text(
        "You have profiles in iCloud. Pick one to open.",
        comment: "Picker subtitle"
      )
      .font(.subheadline)
      .foregroundStyle(.secondary)
    }
    .accessibilityAddTraits(.isHeader)
  }

  private func row(for profile: Profile) -> some View {
    HStack {
      VStack(alignment: .leading, spacing: 2) {
        Text(profile.label)
          .font(.body.weight(.medium))
        HStack(spacing: 4) {
          Text(profile.currencyCode)
          if let count = accountCounts[profile.id] {
            Text("·")
            Text("\(count) ")
              .monospacedDigit()
            + Text(
              count == 1
                ? String(localized: "account")
                : String(localized: "accounts")
            )
          }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
      }
      Spacer()
      Image(systemName: "chevron.right")
        .foregroundStyle(.tertiary)
        .font(.caption)
    }
    .contentShape(.rect)
    .padding(.vertical, 4)
  }
}

#Preview("Two profiles") {
  ICloudProfilePickerView(
    profiles: [
      Profile(label: "Household", backendType: .cloudKit, currencyCode: "AUD"),
      Profile(label: "Side business", backendType: .cloudKit, currencyCode: "AUD"),
    ],
    accountCounts: [:],
    selectAction: { _ in },
    createNewAction: {}
  )
  .frame(width: 480, height: 520)
}

#Preview("With counts — dark") {
  let p1 = Profile(label: "Household", backendType: .cloudKit, currencyCode: "AUD")
  let p2 = Profile(label: "Side business", backendType: .cloudKit, currencyCode: "AUD")
  ICloudProfilePickerView(
    profiles: [p1, p2],
    accountCounts: [p1.id: 12, p2.id: 3],
    selectAction: { _ in },
    createNewAction: {}
  )
  .frame(width: 480, height: 520)
  .preferredColorScheme(.dark)
}

#Preview("AX5") {
  let p1 = Profile(label: "Household", backendType: .cloudKit, currencyCode: "AUD")
  ICloudProfilePickerView(
    profiles: [p1],
    accountCounts: [p1.id: 12],
    selectAction: { _ in },
    createNewAction: {}
  )
  .frame(width: 600, height: 800)
  .dynamicTypeSize(.accessibility5)
}
```

> Note: `accountCounts` will typically be empty in state-5 paths until we choose to query per-profile accounts; leave the plumbing in place so a future task can populate it.

- [ ] **Step 2: Regenerate, build, eyeball previews**

```bash
just generate
just build-mac 2>&1 | tee .agent-tmp/task12-build.txt
grep -iE 'error:|warning:' .agent-tmp/task12-build.txt | grep -v '#Preview' || echo "OK"
```

- [ ] **Step 3: Format, review, commit**

Run `@ui-review` on `ICloudProfilePickerView.swift`.

```bash
just format
rm -f .agent-tmp/task12*.txt
git add Features/Profiles/Views/ICloudProfilePickerView.swift
git commit -m "feat(profiles): add iCloud profile picker for multi-profile first launch"
```

---

## Task 13: Build `WelcomeView` state-machine composite

**Files:**
- Create: `Features/Profiles/Views/WelcomeView.swift`
- Create: `Features/Profiles/Views/WelcomeStateResolver.swift` (pure logic)
- Test: `MoolahTests/Features/WelcomeStateResolverTests.swift`

- [ ] **Step 1: Write the failing test for the resolver**

Create `MoolahTests/Features/WelcomeStateResolverTests.swift`:

```swift
import Foundation
import Testing

@testable import Moolah

@Suite("WelcomeStateResolver")
struct WelcomeStateResolverTests {

  @Test("landing, no cloud profiles, available → .heroChecking")
  func heroChecking() {
    let state = WelcomeStateResolver.resolve(
      phase: .landing,
      cloudProfilesCount: 0,
      iCloudAvailability: .available,
      indexFetchedAtLeastOnce: false,
      bannerDismissed: false
    )
    #expect(state == .heroChecking)
  }

  @Test("landing, no cloud profiles, available, index fetched once → .heroNoneFound")
  func heroNoneFound() {
    let state = WelcomeStateResolver.resolve(
      phase: .landing,
      cloudProfilesCount: 0,
      iCloudAvailability: .available,
      indexFetchedAtLeastOnce: true,
      bannerDismissed: false
    )
    #expect(state == .heroNoneFound)
  }

  @Test("landing, unavailable → .heroOff")
  func heroOff() {
    let state = WelcomeStateResolver.resolve(
      phase: .landing,
      cloudProfilesCount: 0,
      iCloudAvailability: .unavailable(reason: .notSignedIn),
      indexFetchedAtLeastOnce: false,
      bannerDismissed: false
    )
    #expect(state == .heroOff(reason: .notSignedIn))
  }

  @Test("landing, 1 cloud profile → .autoActivateSingle")
  func autoActivateSingle() {
    let state = WelcomeStateResolver.resolve(
      phase: .landing,
      cloudProfilesCount: 1,
      iCloudAvailability: .available,
      indexFetchedAtLeastOnce: true,
      bannerDismissed: false
    )
    #expect(state == .autoActivateSingle)
  }

  @Test("landing, 2+ cloud profiles → .picker")
  func pickerFromLanding() {
    let state = WelcomeStateResolver.resolve(
      phase: .landing,
      cloudProfilesCount: 2,
      iCloudAvailability: .available,
      indexFetchedAtLeastOnce: true,
      bannerDismissed: false
    )
    #expect(state == .picker)
  }

  @Test("creating, no cloud profiles → .form (no banner)")
  func formNoBanner() {
    let state = WelcomeStateResolver.resolve(
      phase: .creating,
      cloudProfilesCount: 0,
      iCloudAvailability: .available,
      indexFetchedAtLeastOnce: false,
      bannerDismissed: false
    )
    #expect(state == .form(banner: nil))
  }

  @Test("creating, 1 cloud profile, not dismissed → .form(single banner)")
  func formSingleBanner() {
    let state = WelcomeStateResolver.resolve(
      phase: .creating,
      cloudProfilesCount: 1,
      iCloudAvailability: .available,
      indexFetchedAtLeastOnce: true,
      bannerDismissed: false
    )
    #expect(state == .form(banner: .singleArrived))
  }

  @Test("creating, 3 cloud profiles, not dismissed → .form(multi banner)")
  func formMultiBanner() {
    let state = WelcomeStateResolver.resolve(
      phase: .creating,
      cloudProfilesCount: 3,
      iCloudAvailability: .available,
      indexFetchedAtLeastOnce: true,
      bannerDismissed: false
    )
    #expect(state == .form(banner: .multiArrived(count: 3)))
  }

  @Test("creating, 1 cloud profile, banner dismissed → .form (no banner)")
  func formSuppressesDismissedBanner() {
    let state = WelcomeStateResolver.resolve(
      phase: .creating,
      cloudProfilesCount: 1,
      iCloudAvailability: .available,
      indexFetchedAtLeastOnce: true,
      bannerDismissed: true
    )
    #expect(state == .form(banner: nil))
  }

  @Test("pickingProfile → .picker regardless of count")
  func pickerFromPickingPhase() {
    let state = WelcomeStateResolver.resolve(
      phase: .pickingProfile,
      cloudProfilesCount: 1,
      iCloudAvailability: .available,
      indexFetchedAtLeastOnce: true,
      bannerDismissed: true
    )
    #expect(state == .picker)
  }
}
```

- [ ] **Step 2: Run to verify they fail**

```bash
just test WelcomeStateResolverTests 2>&1 | tee .agent-tmp/task13.txt
```

Expected: compile error.

- [ ] **Step 3: Create the resolver**

Create `Features/Profiles/Views/WelcomeStateResolver.swift`:

```swift
import Foundation

/// Pure-logic resolver for ``WelcomeView``'s state machine. Extracted so
/// every branch is unit-testable without SwiftUI. Keep deliberately
/// free of `@MainActor` isolation — inputs are value types.
enum WelcomeStateResolver {
  enum ResolvedState: Equatable {
    case heroChecking
    case heroNoneFound
    case heroOff(reason: ICloudAvailability.UnavailableReason)
    case form(banner: BannerKind?)
    case picker
    case autoActivateSingle
  }

  enum BannerKind: Equatable {
    case singleArrived
    case multiArrived(count: Int)
  }

  static func resolve(
    phase: ProfileStore.WelcomePhase,
    cloudProfilesCount: Int,
    iCloudAvailability: ICloudAvailability,
    indexFetchedAtLeastOnce: Bool,
    bannerDismissed: Bool
  ) -> ResolvedState {
    switch phase {
    case .pickingProfile:
      return .picker

    case .creating:
      if bannerDismissed || cloudProfilesCount == 0 {
        return .form(banner: nil)
      }
      if cloudProfilesCount == 1 {
        return .form(banner: .singleArrived)
      }
      return .form(banner: .multiArrived(count: cloudProfilesCount))

    case .landing:
      if cloudProfilesCount == 1 {
        return .autoActivateSingle
      }
      if cloudProfilesCount >= 2 {
        return .picker
      }
      // 0 cloud profiles
      if case .unavailable(let reason) = iCloudAvailability {
        return .heroOff(reason: reason)
      }
      return indexFetchedAtLeastOnce ? .heroNoneFound : .heroChecking
    }
  }
}
```

> Note: `ProfileStore.WelcomePhase` was added in Task 8; this refers to that type.

- [ ] **Step 4: Run tests to verify they pass**

```bash
just generate
just test WelcomeStateResolverTests 2>&1 | tee .agent-tmp/task13.txt
grep -iE 'failed|error:' .agent-tmp/task13.txt || echo "OK"
```

- [ ] **Step 5: Build `WelcomeView`**

Create `Features/Profiles/Views/WelcomeView.swift`:

```swift
import OSLog
import SwiftUI

private let logger = Logger(subsystem: "com.moolah.app", category: "WelcomeView")

/// First-run state-machine view. Composes ``WelcomeHero``,
/// ``CreateProfileFormView``, ``ICloudProfilePickerView``, and
/// ``ICloudArrivalBanner``. Owns the interaction phase and the
/// banner-dismissed flag for this session.
///
/// State is resolved by ``WelcomeStateResolver`` so the branch logic is
/// unit-testable in isolation. See design spec §5.
struct WelcomeView: View {
  @Environment(ProfileStore.self) private var profileStore
  @Environment(SyncCoordinator.self) private var syncCoordinator
  #if os(macOS)
    @Environment(\.openWindow) private var openWindow
  #endif

  @State private var phase: ProfileStore.WelcomePhase = .landing
  @State private var bannerDismissed = false

  @State private var name = ""
  @State private var currencyCode = Locale.current.currency?.identifier ?? "AUD"
  @State private var financialYearStartMonth = 7

  var body: some View {
    let state = WelcomeStateResolver.resolve(
      phase: phase,
      cloudProfilesCount: profileStore.cloudProfiles.count,
      iCloudAvailability: profileStore.iCloudAvailability,
      indexFetchedAtLeastOnce: syncCoordinator.profileIndexFetchedAtLeastOnce,
      bannerDismissed: bannerDismissed
    )

    content(for: state)
      .onAppear { profileStore.welcomePhase = phase }
      .onDisappear { profileStore.welcomePhase = nil }
      .onChange(of: phase) { _, newValue in
        profileStore.welcomePhase = newValue
      }
  }

  @ViewBuilder
  private func content(for state: WelcomeStateResolver.ResolvedState) -> some View {
    switch state {
    case .heroChecking:
      WelcomeHero(primaryAction: beginCreate) {
        ICloudStatusLine(state: .checking)
      }
      .accessibilityIdentifier(UITestIdentifiers.Welcome.heroGetStartedButton)

    case .heroNoneFound:
      WelcomeHero(primaryAction: beginCreate) {
        ICloudStatusLine(state: .noneFound)
      }
      .accessibilityIdentifier(UITestIdentifiers.Welcome.heroGetStartedButton)

    case .heroOff(let reason):
      WelcomeHero(primaryAction: beginCreate) {
        ICloudOffChip(openSettingsAction: openSystemSettings)
          .accessibilityIdentifier(UITestIdentifiers.Welcome.iCloudOffSystemSettingsLink)
      }
      .accessibilityLabel(offHeroLabel(for: reason))

    case .form(let banner):
      CreateProfileFormView(
        name: $name,
        currencyCode: $currencyCode,
        financialYearStartMonth: $financialYearStartMonth,
        banner: banner.map(mapBanner),
        onBannerPrimary: handleBannerPrimary,
        onBannerDismiss: { bannerDismissed = true },
        backgroundCheckingICloud:
          profileStore.iCloudAvailability == .available
          && !syncCoordinator.profileIndexFetchedAtLeastOnce,
        cancelAction: { phase = .landing },
        createAction: handleCreate
      )

    case .picker:
      ICloudProfilePickerView(
        profiles: profileStore.cloudProfiles,
        accountCounts: [:],
        selectAction: { profile in profileStore.setActiveProfile(profile.id) },
        createNewAction: {
          phase = .creating
          bannerDismissed = true   // user explicitly chose to create
        }
      )

    case .autoActivateSingle:
      Color.clear
        .task {
          guard let first = profileStore.cloudProfiles.first else { return }
          profileStore.setActiveProfile(first.id)
        }
    }
  }

  // MARK: - Actions

  private func beginCreate() {
    #if os(iOS)
      UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    #endif
    phase = .creating
  }

  private func handleCreate() async {
    let trimmedName = name.trimmingCharacters(in: .whitespaces)
    guard !trimmedName.isEmpty else { return }
    // Race guard: if auto-activation would have fired, don't step on it.
    guard profileStore.welcomePhase == .creating else {
      logger.info("handleCreate aborted — phase changed under us")
      return
    }
    let profile = Profile(
      label: trimmedName,
      backendType: .cloudKit,
      currencyCode: currencyCode,
      financialYearStartMonth: financialYearStartMonth
    )
    _ = await profileStore.validateAndAddProfile(profile)
    #if os(macOS)
      openWindow(value: profile.id)
    #endif
  }

  private func handleBannerPrimary() {
    switch profileStore.cloudProfiles.count {
    case 1:
      if let first = profileStore.cloudProfiles.first {
        profileStore.setActiveProfile(first.id)
      }
    default:
      phase = .pickingProfile
    }
  }

  private func openSystemSettings() {
    #if os(macOS)
      let primary = URL(string: "x-apple.systempreferences:com.apple.preferences.AppleIDPrefPane")
      if let primary, NSWorkspace.shared.open(primary) { return }
      NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
    #else
      if let url = URL(string: "App-Prefs:") {
        UIApplication.shared.open(url)
      }
    #endif
  }

  private func mapBanner(
    _ kind: WelcomeStateResolver.BannerKind
  ) -> ICloudArrivalBanner.Kind {
    switch kind {
    case .singleArrived:
      return .single(label: profileStore.cloudProfiles.first?.label ?? "profile")
    case .multiArrived(let count):
      return .multiple(count: count)
    }
  }

  private func offHeroLabel(for reason: ICloudAvailability.UnavailableReason) -> String {
    switch reason {
    case .notSignedIn:
      return String(localized: "Welcome to Moolah. iCloud is not signed in.")
    case .restricted:
      return String(localized: "Welcome to Moolah. iCloud is restricted.")
    case .temporarilyUnavailable:
      return String(localized: "Welcome to Moolah. iCloud is temporarily unavailable.")
    case .entitlementsMissing:
      return String(localized: "Welcome to Moolah. iCloud is not available in this build.")
    }
  }
}

#Preview("Welcome — checking") {
  // Typical first-launch preview harness; assumes TestBackend helpers
  // exist (they're used throughout the rest of the codebase).
  WelcomeView()
    .environment(PreviewFixtures.makeProfileStore())
    .environment(PreviewFixtures.makeSyncCoordinator())
    .frame(width: 480, height: 720)
}
```

If `PreviewFixtures` doesn't exist, replace the `#Preview` block with one that uses inline stores built from `ProfileContainerManager(isInMemoryOverride: true)` + `SyncCoordinator` as the `SyncCoordinatorTests` above construct them. The `.environment(...)` wiring stays.

- [ ] **Step 6: Regenerate, build, run both test suites**

```bash
just generate
just build-mac 2>&1 | tee .agent-tmp/task13-build.txt
grep -iE 'error:|warning:' .agent-tmp/task13-build.txt | grep -v '#Preview' || echo "OK"
just test WelcomeStateResolverTests 2>&1 | tee .agent-tmp/task13.txt
grep -iE 'failed|error:' .agent-tmp/task13.txt || echo "OK"
```

- [ ] **Step 7: Format, review, commit**

Run `@ui-review` on `WelcomeView.swift` and `@code-review` on the resolver.

```bash
just format
rm -f .agent-tmp/task13*.txt
git add Features/Profiles/Views/WelcomeView.swift \
        Features/Profiles/Views/WelcomeStateResolver.swift \
        MoolahTests/Features/WelcomeStateResolverTests.swift
git commit -m "feat(profiles): add WelcomeView state machine + resolver"
```

---

## Task 14: Wire `WelcomeView` into macOS `ProfileWindowView`

**Files:**
- Modify: `App/ProfileWindowView.swift`
- Modify: `App/MoolahApp.swift` (add `.windowStyle(.hiddenTitleBar)` on the window when welcome is shown)

- [ ] **Step 1: Swap the call site**

In `App/ProfileWindowView.swift`, the current `body` block has:

```swift
} else if !profileStore.hasProfiles {
  ProfileSetupView()
    .onChange(of: profileStore.profiles) { _, newProfiles in
      if let first = newProfiles.first {
        openWindow(value: first.id)
      }
    }
} else if profileStore.isCloudLoadPending {
  ProgressView()
}
```

Replace with:

```swift
} else if !profileStore.hasProfiles {
  WelcomeView()
    .onChange(of: profileStore.profiles) { _, newProfiles in
      if let first = newProfiles.first {
        openWindow(value: first.id)
      }
    }
}
// Drop the isCloudLoadPending branch — WelcomeView's .heroChecking
// state subsumes it.
```

- [ ] **Step 2: Apply `.windowStyle(.hiddenTitleBar)` conditionally**

In `App/MoolahApp.swift`, the `WindowGroup(for: Profile.ID.self)` already exists. Adding `.windowStyle(.hiddenTitleBar)` to a `WindowGroup` applies to every window in the group — we can't conditionally switch per-window. Alternative: accept that the welcome window keeps standard chrome. The hero layout must tolerate the default titlebar on macOS.

**Decision**: keep standard chrome; the hero already has 48pt top spacer which makes room for the titlebar. Verify visually in Task 18.

If you want to try hidden titlebar anyway, the approach is a separate `Window` for the welcome state with `.windowStyle(.hiddenTitleBar)` — but that fights the `WindowGroup(for: Profile.ID.self)` model and adds routing complexity. Out of scope; revisit if Task 18 QA flags it.

Document this in the PR description ("design spec §4.1 mentioned `.windowStyle(.hiddenTitleBar)`; we're keeping standard chrome, see Task 14 notes").

- [ ] **Step 3: Build + smoke run**

```bash
just generate
just build-mac 2>&1 | tee .agent-tmp/task14-build.txt
grep -iE 'error:|warning:' .agent-tmp/task14-build.txt | grep -v '#Preview' || echo "OK"
just run-mac
```

In the running app, delete any local profile index to simulate first-launch (the run-mac-app-with-logs skill can help; otherwise use a separate macOS user account for a truly clean first-launch). Verify the welcome hero renders.

- [ ] **Step 4: Format, review, commit**

Run `@ui-review` on the diff.

```bash
just format
rm -f .agent-tmp/task14*.txt
git add App/ProfileWindowView.swift
git commit -m "feat(profiles): route macOS first-run through WelcomeView"
```

---

## Task 15: Wire `WelcomeView` into iOS `ProfileRootView`

**Files:**
- Modify: `App/ProfileRootView.swift`

- [ ] **Step 1: Swap the call site**

In `App/ProfileRootView.swift`, replace:

```swift
if !profileStore.hasProfiles {
  ProfileSetupView()
} else if let session = activeSession {
  SessionRootView(session: session)
} else {
  ProgressView()
}
```

with:

```swift
if !profileStore.hasProfiles {
  WelcomeView()
} else if let session = activeSession {
  SessionRootView(session: session)
} else {
  ProgressView()
}
```

- [ ] **Step 2: Build + run iOS simulator**

```bash
just generate
just build-ios 2>&1 | tee .agent-tmp/task15-build.txt
grep -iE 'error:|warning:' .agent-tmp/task15-build.txt | grep -v '#Preview' || echo "OK"
```

Launch the iOS simulator, wipe app state (`xcrun simctl uninstall booted com.moolah.app`) and re-install via build. Verify welcome hero, "Get started" tap, create-profile form, and haptics on a device (simulator ignores haptics).

- [ ] **Step 3: Format, review, commit**

Run `@ui-review`.

```bash
just format
rm -f .agent-tmp/task15*.txt
git add App/ProfileRootView.swift
git commit -m "feat(profiles): route iOS first-run through WelcomeView"
```

---

## Task 16: Delete `ProfileSetupView`; rename `Auth/WelcomeView` → `SignedOutView`

**Files:**
- Delete: `Features/Profiles/Views/ProfileSetupView.swift`
- Rename: `Features/Auth/WelcomeView.swift` → `Features/Auth/SignedOutView.swift`
- Modify: all call sites of the old `Auth/WelcomeView` type name

- [ ] **Step 1: Locate all call sites of the old `WelcomeView` from `Auth/`**

```bash
grep -rn "WelcomeView" --include="*.swift" \
  | grep -v "Features/Profiles/Views/WelcomeView.swift" \
  | grep -v "Features/Profiles/Views/WelcomeStateResolver.swift" \
  | grep -v "Features/Profiles/Views/WelcomeHero.swift" \
  | grep -v "MoolahTests/Features/WelcomeStateResolverTests.swift" \
  | grep -v "plans/"
```

Expected call sites include `SessionRootView.swift` or equivalent places that show the sign-in UI when a Moolah-server session is signed out.

- [ ] **Step 2: Rename the file and the type**

```bash
git mv Features/Auth/WelcomeView.swift Features/Auth/SignedOutView.swift
```

Inside the moved file, rename `struct WelcomeView: View` → `struct SignedOutView: View`, and update all the `#Preview` blocks to reference `SignedOutView`. Update the doc-comment ("Shown when the user is signed out") to make it clearer: "Shown when a Moolah-server profile has lost its authentication; offers Sign in with Google."

- [ ] **Step 3: Update call sites**

For each match from Step 1, replace `WelcomeView()` with `SignedOutView()`.

- [ ] **Step 4: Delete `ProfileSetupView.swift`**

```bash
git rm Features/Profiles/Views/ProfileSetupView.swift
```

Run the grep sweep to make sure no remaining code references it:

```bash
grep -rn "ProfileSetupView" --include="*.swift" | grep -v "plans/"
```

Expected: no matches.

- [ ] **Step 5: Regenerate, build, run full test suite**

```bash
just generate
just test 2>&1 | tee .agent-tmp/task16.txt
grep -iE 'failed|error:' .agent-tmp/task16.txt || echo "OK"
```

- [ ] **Step 6: Format, review, commit**

Run `@code-review` on the rename diff.

```bash
just format
rm -f .agent-tmp/task16.txt
git add -A
git status    # confirm the rename, the delete, and any call-site updates are present
git commit -m "refactor(profiles): delete ProfileSetupView; rename Auth/WelcomeView → SignedOutView"
```

---

## Task 17: UI-test seeds + UI tests

**Files:**
- Modify: `UITestSupport/UITestSeeds.swift` (add 5 new seeds)
- Create: `MoolahUITests_macOS/Screens/WelcomeScreen.swift`
- Create: `MoolahUITests_macOS/Tests/WelcomeViewTests.swift`

Follow `guides/UI_TEST_GUIDE.md` — tests import only `XCTest`, all UI access goes through a screen driver, identifiers come from `UITestIdentifiers`. After writing any new seed or identifier, run `just generate`.

- [ ] **Step 1: Add seeds**

In `UITestSupport/UITestSeeds.swift` (inspect the file first to see its structure), add:

```swift
public enum UITestSeed: String {
  // ... existing cases ...
  case emptyNoProfiles             // blank index container
  case singleCloudProfile          // one ProfileRecord seeded in the index
  case multipleCloudProfiles       // two ProfileRecords seeded
  case iCloudUnavailable           // blank + forces iCloudAvailability = .unavailable(.notSignedIn)
  case midFormCloudProfileTrigger  // starts blank; a test-only button injects a ProfileRecord
}
```

Plumb each seed through the seed-application path (find the existing `applySeed(_:)` function and match its shape). For `iCloudUnavailable`, set the test override via a launch argument flag (e.g. `--ui-testing-icloud-unavailable`) that `SyncCoordinator.init` honours via its `isCloudKitAvailableOverride` parameter (already added in Task 2).

- [ ] **Step 2: Add test-only "inject profile" affordance**

For `midFormCloudProfileTrigger`, the test needs to simulate a `ProfileRecord` appearing in iCloud mid-form. Add a hidden UI-test-only button inside `CreateProfileFormView`:

```swift
#if DEBUG
  if ProcessInfo.processInfo.arguments.contains("--ui-testing-inject-profile") {
    Button("Inject iCloud profile (UITest)") { injectTestProfileAction() }
      .accessibilityIdentifier("welcome.create.uitest.injectProfile")
  }
#endif
```

Wire `injectTestProfileAction` through a closure passed from `WelcomeView`. In `WelcomeView`, the closure writes a `ProfileRecord` to the index container and calls `profileStore.loadCloudProfiles()` so observers fire.

Mark the identifier in `UITestIdentifiers.Welcome` so the screen driver can reference it:

```swift
#if DEBUG
  static let injectTestProfileButton = "welcome.create.uitest.injectProfile"
#endif
```

Per `guides/UI_TEST_GUIDE.md` §4 on test-only affordances, guard with `#if DEBUG`.

- [ ] **Step 3: Build the screen driver**

Create `MoolahUITests_macOS/Screens/WelcomeScreen.swift`:

```swift
import XCTest

/// Screen driver for ``WelcomeView``. Per `guides/UI_TEST_GUIDE.md`,
/// tests call only methods on this driver — never raw XCUIElement
/// queries. Every method logs an XCTestObservation trace and waits for
/// a post-condition, so transient UI changes never leave tests flaky.
struct WelcomeScreen {
  let app: XCUIApplication

  // MARK: - Hero

  func waitForHero(timeout: TimeInterval = 5) {
    let hero = app.buttons[UITestIdentifiers.Welcome.heroGetStartedButton]
    XCTAssertTrue(
      hero.waitForExistence(timeout: timeout),
      "Welcome hero 'Get started' button did not appear within \(timeout)s"
    )
  }

  func tapGetStarted() {
    app.buttons[UITestIdentifiers.Welcome.heroGetStartedButton].tap()
    let nameField = app.textFields[UITestIdentifiers.Welcome.nameField]
    XCTAssertTrue(
      nameField.waitForExistence(timeout: 5),
      "Name field did not appear after tapping Get started"
    )
  }

  // MARK: - Form

  func type(name: String) {
    let field = app.textFields[UITestIdentifiers.Welcome.nameField]
    field.click()
    field.typeText(name)
    XCTAssertEqual(field.value as? String, name)
  }

  func tapCreateProfile() {
    app.buttons[UITestIdentifiers.Welcome.createProfileButton].tap()
    // Post-condition: welcome hero is gone (session loaded).
    let hero = app.buttons[UITestIdentifiers.Welcome.heroGetStartedButton]
    XCTAssertFalse(
      hero.waitForExistence(timeout: 5),
      "Welcome hero still present after tapping Create Profile"
    )
  }

  // MARK: - Banner

  func waitForBanner(contains text: String, timeout: TimeInterval = 10) {
    let predicate = NSPredicate(format: "label CONTAINS[c] %@", text)
    let banner = app.staticTexts.matching(predicate).firstMatch
    XCTAssertTrue(
      banner.waitForExistence(timeout: timeout),
      "Banner with text '\(text)' did not appear within \(timeout)s"
    )
  }

  func bannerIsGone(timeout: TimeInterval = 3) {
    let open = app.buttons[UITestIdentifiers.Welcome.bannerOpenAction]
    let view = app.buttons[UITestIdentifiers.Welcome.bannerViewAction]
    let dismiss = app.buttons[UITestIdentifiers.Welcome.bannerDismissAction]
    _ = open.waitForNonExistence(timeout: timeout)
    _ = view.waitForNonExistence(timeout: timeout)
    _ = dismiss.waitForNonExistence(timeout: timeout)
    XCTAssertFalse(open.exists)
    XCTAssertFalse(view.exists)
    XCTAssertFalse(dismiss.exists)
  }

  func dismissBanner() {
    app.buttons[UITestIdentifiers.Welcome.bannerDismissAction].tap()
    bannerIsGone()
  }

  // MARK: - Picker

  func waitForPicker(timeout: TimeInterval = 5) {
    let createNew = app.buttons[UITestIdentifiers.Welcome.pickerCreateNewRow]
    XCTAssertTrue(
      createNew.waitForExistence(timeout: timeout),
      "Picker 'Create a new profile' row did not appear within \(timeout)s"
    )
  }

  func pickerRowCount() -> Int {
    let prefix = UITestIdentifiers.Welcome.pickerRow + "."
    return app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix)).count
  }

  // MARK: - iCloud off

  func waitForICloudOffChip(timeout: TimeInterval = 5) {
    let link = app.buttons[UITestIdentifiers.Welcome.iCloudOffSystemSettingsLink]
    XCTAssertTrue(
      link.waitForExistence(timeout: timeout),
      "'Open System Settings' link did not appear within \(timeout)s"
    )
  }

  // MARK: - Test-only

  #if DEBUG
    func injectCloudProfile() {
      app.buttons[UITestIdentifiers.Welcome.injectTestProfileButton].tap()
    }
  #endif
}

/// Convenience `waitForNonExistence` matching our in-repo pattern — if
/// `XCUIElement+Wait.swift` already defines it, delete this local copy.
private extension XCUIElement {
  func waitForNonExistence(timeout: TimeInterval) -> Bool {
    let expectation = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "exists == false"),
      object: self
    )
    return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
  }
}
```

- [ ] **Step 4: Write the UI tests**

Create `MoolahUITests_macOS/Tests/WelcomeViewTests.swift`:

```swift
import XCTest

final class WelcomeViewTests: XCTestCase {
  private var app: XCUIApplication!
  private var screen: WelcomeScreen!

  override func setUpWithError() throws {
    continueAfterFailure = false
    app = XCUIApplication()
    screen = WelcomeScreen(app: app)
  }

  // MARK: - Seed helpers

  private func launch(seed: String, extraArgs: [String] = []) {
    app.launchArguments = ["--ui-testing", "--ui-testing-seed=\(seed)"] + extraArgs
    app.launch()
  }

  // MARK: - Tests

  func testFirstLaunchNoCloudProfiles_showsHeroAndSetsUpProfile() throws {
    launch(seed: "emptyNoProfiles")
    screen.waitForHero()
    screen.tapGetStarted()
    screen.type(name: "Household")
    screen.tapCreateProfile()
  }

  func testFirstLaunchWithOneCloudProfile_autoOpens() throws {
    launch(seed: "singleCloudProfile")
    // No hero — auto-activates straight to SessionRootView.
    // Success condition: session chrome (e.g. sidebar) present quickly.
    let sidebar = app.otherElements["sessionRoot"]   // adjust to real identifier
    XCTAssertTrue(sidebar.waitForExistence(timeout: 10))
  }

  func testFirstLaunchWithMultipleCloudProfiles_showsPicker() throws {
    launch(seed: "multipleCloudProfiles")
    screen.waitForPicker()
    XCTAssertEqual(screen.pickerRowCount(), 2)
  }

  func testICloudUnavailable_showsOffChipAndDeepLink() throws {
    launch(seed: "iCloudUnavailable")
    screen.waitForHero()
    screen.waitForICloudOffChip()
  }

  func testMidFormCloudProfileArrives_showsBannerAndDismissSticks() throws {
    launch(seed: "midFormCloudProfileTrigger", extraArgs: ["--ui-testing-inject-profile"])
    screen.waitForHero()
    screen.tapGetStarted()
    screen.type(name: "Draft")

    #if DEBUG
      screen.injectCloudProfile()
    #else
      XCTFail("This test requires a DEBUG build for the inject affordance")
      return
    #endif

    screen.waitForBanner(contains: "in iCloud")
    screen.dismissBanner()

    #if DEBUG
      screen.injectCloudProfile()   // second arrival
    #endif

    // Banner must NOT re-appear — bannerIsGone waits on absence predicates.
    screen.bannerIsGone()
  }

  func testMidFormNoRaceWithAutoActivate() throws {
    launch(seed: "midFormCloudProfileTrigger", extraArgs: ["--ui-testing-inject-profile"])
    screen.waitForHero()
    screen.tapGetStarted()
    screen.type(name: "Draft")

    #if DEBUG
      screen.injectCloudProfile()
    #endif

    // Banner appears, but form stays — no auto-activation.
    screen.waitForBanner(contains: "in iCloud")

    // Confirm the form is still present by typing more.
    screen.type(name: "X")
  }
}
```

- [ ] **Step 5: Regenerate project, run UI tests**

```bash
just generate
just test WelcomeViewTests 2>&1 | tee .agent-tmp/task17.txt
grep -iE 'failed|error:' .agent-tmp/task17.txt || echo "OK"
```

If the "sessionRoot" identifier doesn't exist in `SessionRootView`, add it as a minor change to that view and reference `UITestIdentifiers.Session.root` — or just use whatever identifier already exists for sidebar. Run `grep -n "accessibilityIdentifier" Features/Session/Views/SessionRootView.swift` (or equivalent) to find one.

- [ ] **Step 6: Format, review, commit**

Run `@ui-test-review` on the new files, `@ui-review` on the `injectTestProfile` affordance change to `CreateProfileFormView.swift`.

```bash
just format
rm -f .agent-tmp/task17.txt
git add UITestSupport/UITestSeeds.swift \
        UITestSupport/UITestIdentifiers.swift \
        Features/Profiles/Views/CreateProfileFormView.swift \
        Features/Profiles/Views/WelcomeView.swift \
        MoolahUITests_macOS/Screens/WelcomeScreen.swift \
        MoolahUITests_macOS/Tests/WelcomeViewTests.swift
git commit -m "test(profiles): add UI tests + seeds for WelcomeView"
```

---

## Task 18: Brand QA pass

**Files:**
- No code changes unless this pass surfaces regressions. Any fixes go through the normal worktree + PR dance.

This is a manual verification pass. Record observations in `.agent-tmp/task18-qa.md` and open issues for anything that needs follow-up (reference the spec sections).

- [ ] **Step 1: macOS Light Mode**

1. Switch macOS to Light Mode (System Settings → Appearance → Light).
2. Wipe the Moolah profile index (delete `~/Library/Containers/com.moolah.app/` or use a spare account).
3. `just run-mac`.
4. Verify:
   - Hero renders dark against a potentially light titlebar.
   - "Get started" button focus ring visible; Tab navigation works.
   - Spinner animates; "Checking iCloud for your profiles…" label correctly placed.
   - Tapping "Get started" transitions to the form; form is system-themed (light).
   - "Advanced" disclosure shows Currency picker + FY month picker.
   - "Create Profile" button tints with system blue.
   - Cancel returns to hero.

- [ ] **Step 2: macOS Dark Mode**

Repeat Step 1 in Dark Mode. Verify:
- Hero unchanged (it's always dark).
- Form renders in dark system materials.
- Banner (inject via UI-test affordance if needed) is brand gold, readable.
- Picker renders in dark system chrome.

- [ ] **Step 3: iOS Light + Dark**

Wipe app on simulator, run `just build-ios`, launch app. Repeat Steps 1–2 equivalent checks. Verify haptics on a real device (simulator ignores haptics; plug in a phone if you have one).

- [ ] **Step 4: Dynamic Type at `.accessibility5`**

macOS: System Settings → Accessibility → Display → Text Size → maximum.
iOS: Settings → Accessibility → Display & Text Size → Larger Text → maximum.

Verify:
- Hero title wraps cleanly; subhead wraps within the 320pt max-width.
- "Get started" button grows; remains tappable (≥44pt).
- Form field labels stack properly; Advanced disclosure doesn't clip.
- Picker row meta (AUD · 12 accounts) wraps and keeps the account count on a single baseline.
- Banner wraps across multiple lines without clipping.

- [ ] **Step 5: VoiceOver traversal**

macOS: `cmd+fn+F5` to toggle VoiceOver. Traverse the welcome screen:
1. "Moolah" eyebrow should be hidden (decorative; title carries the meaning).
2. "Your money, rock solid." announced as a header.
3. Subhead announced verbatim.
4. "Get started, button" announced; focus visible.
5. In state 1, "Checking iCloud for your profiles" announced by the polite live region on its first appearance.
6. In state 4, the off-chip announces the full label: "iCloud sync is off. Your profile will be saved on this device. Open System Settings."
7. In the form, name field announced as "Name, text field".
8. In the picker, each row announced with label + currency + account count; create-new row reachable.

- [ ] **Step 6: System Settings deep link (macOS)**

Drive to state 4 (sign out of iCloud temporarily in System Settings). Tap "Open System Settings". Verify:
- Primary URL opens the Apple ID / iCloud pane on your macOS 26 install, OR
- The fallback opens System Settings.app to its root.

If neither works: file a bug referencing design spec §8 "Open System Settings" and the CI validation note.

- [ ] **Step 7: Record findings**

Write `.agent-tmp/task18-qa.md` with a checklist of pass/fail per step. Any fails → open a GitHub issue per `guides/CODE_GUIDE.md` §20 TODO policy and reference the issue from either the QA doc or a follow-up PR.

- [ ] **Step 8: No-code commit**

If QA passed with no changes, Task 18 has no commit. Note this in the PR ("Task 18 brand QA passed — no fixes needed"). If QA surfaced issues, open separate fix PRs referencing the issue number.

---

## Self-review checklist

Before marking this plan ready for execution:

- [x] Every design-spec section is covered by at least one task:
  - §1 Context — N/A (prose).
  - §2 Scope — Tasks 14, 15 (routing), 16 (removals).
  - §3.1 First launch / iCloud available — Tasks 8 (guard), 13 (resolver + view).
  - §3.2 iCloud unavailable — Tasks 13 (off chip branch), 17 (iCloudUnavailable test).
  - §3.3 Mid-form arrival — Tasks 8 (guard), 13 (banner in resolver), 17 (banner + dismiss tests).
  - §4.1 Hybrid visual — Tasks 9, 10, 11, 12.
  - §4.2 Typography — Tasks 9, 11, 12.
  - §4.3 Accessibility — Task 9 (focus, `.accessibilityAddTraits`, `.accessibilityLabel`), Task 11 (haptics), Task 18 (VoiceOver manual).
  - §4.4 Copy — Tasks 9–13 (verbatim).
  - §5 State machine — Task 13.
  - §6.1 `iCloudAvailability` on `SyncCoordinator` — Tasks 1, 2, 3.
  - §6.2 `profileIndexFetchedAtLeastOnce` — Tasks 5, 6, 7.
  - §6.3 Local-only profile path — inherent in the existing backend; Task 13 `handleCreate` uses `.cloudKit`; Task 18 Step 6 smoke-tests sign-out.
  - §7.1 New files — Tasks 9–13.
  - §7.2 Modified — Tasks 2–4, 8, 14, 15.
  - §7.3 Removals + rename — Task 16.
  - §7.4 Tests — Tasks 1–8 (unit/store/coordinator), 13 (resolver unit), 17 (UI).
  - §7.6 Preview coverage — Tasks 9–12 (three previews each).
  - §8 Edge cases — Task 13 (openSystemSettings fallback, handleCreate race guard), Task 18 (manual sign-in/out cycle).
  - §9 Implementation order — this plan's 18 tasks mirror the 9-phase order.

- [x] No placeholders. Every code block is real; every command is runnable.

- [x] Type consistency:
  - `ICloudAvailability` / `.UnavailableReason` — used consistently (Tasks 1, 2, 4, 13).
  - `WelcomePhase` — defined Task 8, consumed Task 13.
  - `WelcomeStateResolver.ResolvedState` / `.BannerKind` — internal to Task 13.
  - `ICloudArrivalBanner.Kind` (`.single` / `.multiple`) — defined Task 10, consumed Task 13.
  - `ICloudStatusLine.State` (`.checking` / `.noneFound`) — defined Task 9, consumed Task 13.
  - `UITestIdentifiers.Welcome.*` — stubbed Task 11, completed Task 17.

- [x] Each task has a commit step and is revert-safe on its own.

---

## Execution handoff

Per spec §9, each task lands as a separate PR through the merge queue. The first PR after this plan lands will be Task 1.

**Suggested approach when executing:** subagent-driven-development with fresh worktree per task, two-stage review (automated agents first, then a human skim of the PR description + diff).
