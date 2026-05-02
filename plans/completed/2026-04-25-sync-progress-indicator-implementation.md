# Sync Progress Indicator Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a Photos-style passive sync indicator (macOS sidebar footer with text + relative timestamp; iOS sidebar-drawer footer with compact icon-led row) and a new `.heroDownloading` Welcome state that replaces the opaque "Checking iCloud" wait while iCloud data streams in.

**Architecture:** A new `@Observable @MainActor` value `SyncProgress` lives alongside `SyncCoordinator` and is exposed as `syncCoordinator.progress`. Existing `CKSyncEngine` event hooks feed it. Two render targets consume it: `SyncProgressFooter` (sidebar) and a new `.heroDownloading(received:)` arm in `WelcomeStateResolver` / `ICloudStatusLine`.

**Tech Stack:** Swift 6, SwiftUI, CloudKit (`CKSyncEngine`), SwiftData, Swift Testing, XCUITest. Build / test via `just` targets only — never raw `swift-format` / `xcodebuild` / `swift test`.

**Spec:** `plans/2026-04-25-sync-progress-indicator-design.md`

---

## Conventions every task must follow

- **TDD.** Write the failing test, run it (capture output to `.agent-tmp/`), confirm it fails for the expected reason, then implement.
- **Pre-commit.** Before `git commit`, run `just format` and check `mcp__xcode__XcodeListNavigatorIssues` (severity `warning`). All warnings in user code must be fixed before committing. The build is `SWIFT_TREAT_WARNINGS_AS_ERRORS: YES`.
- **Test capture.** Always pipe test output to a file: `just test … 2>&1 | tee .agent-tmp/test-output.txt`. Delete the temp file after reviewing.
- **Commits.** One commit per task, at the end of the task. Use the `Co-Authored-By: Claude Opus 4.7 (1M context)` trailer.
- **Code style.** Follow `guides/CODE_GUIDE.md`. Run `just format` before commits — never re-baseline SwiftLint. If `just format-check` fails, fix the underlying code, do not bump `.swiftlint-baseline.yml`.

---

## File map

**New files:**
- `Backends/CloudKit/Sync/SyncProgress.swift` — observable state machine.
- `Features/Sync/SyncProgressFooter.swift` — sidebar footer view (macOS + iOS bodies).
- `MoolahTests/Sync/SyncProgressTests.swift` — unit tests for `SyncProgress`.
- `MoolahTests/Features/SyncProgressFooterTests.swift` — view rendering tests.
- `MoolahUITests_macOS/Welcome/WelcomeDownloadingUITests.swift` — UI tests for new Welcome state.
- `MoolahUITests_macOS/Sync/SyncProgressFooterUITests.swift` — UI tests for footer states.

**Modified files:**
- `Backends/CloudKit/Sync/SyncCoordinator.swift` — add `progress` property; hydrate from UserDefaults on init.
- `Backends/CloudKit/Sync/SyncCoordinator+Lifecycle.swift` — feed `progress` from `beginFetchingChanges` / `endFetchingChanges`; clear `lastSettledAt` in `stop()`.
- `Backends/CloudKit/Sync/SyncCoordinator+RecordChanges.swift` — count records in `handleFetchedRecordZoneChangesAsync`; update `pendingUploads` in `handleSentRecordZoneChanges`; flip degraded on quota.
- `Backends/CloudKit/Sync/SyncCoordinator+Zones.swift` — flip degraded in `handleAccountChange`.
- `Backends/CloudKit/Sync/SyncCoordinator+Refetch.swift` — flip `.degraded(.retrying)` while `refetchAttempts > 0`.
- `Features/Profiles/Views/WelcomeStateResolver.swift` — new `.heroDownloading(received:)` arm.
- `Features/Profiles/Views/ICloudStatusLine.swift` — new `.checkingActive(received:)` state.
- `Features/Profiles/Views/WelcomeHero.swift` — animated layout transition; alternate button label.
- `Features/Profiles/Views/WelcomeView.swift` — `wasDownloading` `@State` and resolver wiring.
- `Features/Navigation/SidebarView.swift` — mount `SyncProgressFooter` via `.safeAreaInset(edge: .bottom)`.
- `MoolahTests/Sync/SyncCoordinatorTests.swift` (or sibling files) — assert progress wiring on each event path.
- `MoolahTests/Profiles/WelcomeStateResolverTests.swift` — coverage for `.heroDownloading`.
- `UITestSupport/UITestSeed.swift` — new seed cases for downloading and footer states.
- `UITestSupport/UITestIdentifiers.swift` — new identifier constants for footer + downloading view.

---

## Task 1: SyncProgress skeleton (Phase + Reason enums, initial state)

**Files:**
- Create: `Backends/CloudKit/Sync/SyncProgress.swift`
- Create: `MoolahTests/Sync/SyncProgressTests.swift`

- [ ] **Step 1: Write the failing test**

Create `MoolahTests/Sync/SyncProgressTests.swift`:

```swift
import Foundation
import Testing

@testable import Moolah

@Suite("SyncProgress")
@MainActor
struct SyncProgressTests {

  // MARK: - Initial state

  @Test
  func initialPhaseIsIdle() {
    let progress = SyncProgress(userDefaults: ephemeralDefaults())
    #expect(progress.phase == .idle)
    #expect(progress.recordsReceivedThisSession == 0)
    #expect(progress.pendingUploads == 0)
    #expect(progress.lastSettledAt == nil)
    #expect(progress.moreComing == false)
  }

  // MARK: - Helpers

  private func ephemeralDefaults() -> UserDefaults {
    let suite = "test.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    return defaults
  }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
mkdir -p .agent-tmp
just test SyncProgressTests 2>&1 | tee .agent-tmp/test-output.txt
```

Expected: build failure ("Cannot find 'SyncProgress' in scope").

- [ ] **Step 3: Create the SyncProgress type**

Create `Backends/CloudKit/Sync/SyncProgress.swift`:

```swift
import Foundation

/// Observable progress / phase state for `SyncCoordinator`. A single source
/// of truth consumed by `SyncProgressFooter` (sidebar) and the
/// `.heroDownloading` arm in `WelcomeStateResolver`.
///
/// All mutations happen on `@MainActor` via setter methods called from
/// `SyncCoordinator`'s existing `CKSyncEngine` event hooks. The fields
/// are `private(set)` so consumers can only read.
///
/// `pendingUploads` mirrors `syncEngine.state.pendingRecordZoneChanges.count`;
/// the engine state remains authoritative. Storing the mirror keeps SwiftUI
/// Observation invalidations reliable.
@Observable @MainActor
final class SyncProgress {
  enum Phase: Equatable {
    case idle
    case connecting
    case receiving
    case sending
    case syncing
    case upToDate
    case degraded(Reason)
  }

  enum Reason: Equatable {
    case quotaExceeded
    case iCloudUnavailable(ICloudAvailability.UnavailableReason)
    case retrying
  }

  private(set) var phase: Phase = .idle
  private(set) var recordsReceivedThisSession: Int = 0
  private(set) var pendingUploads: Int = 0
  private(set) var lastSettledAt: Date?
  private(set) var moreComing: Bool = false

  private let userDefaults: UserDefaults

  static let lastSettledAtKey = "com.moolah.sync.lastSettledAt"

  init(userDefaults: UserDefaults = .standard) {
    self.userDefaults = userDefaults
    if let stored = userDefaults.object(forKey: Self.lastSettledAtKey) as? Date {
      self.lastSettledAt = stored
    }
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
just test SyncProgressTests 2>&1 | tee .agent-tmp/test-output.txt
grep -i 'failed\|error:' .agent-tmp/test-output.txt
```

Expected: PASS, no failures.

- [ ] **Step 5: Commit**

```bash
just format
git add Backends/CloudKit/Sync/SyncProgress.swift MoolahTests/Sync/SyncProgressTests.swift
git commit -m "$(cat <<'EOF'
feat(sync): add SyncProgress skeleton with Phase / Reason enums

Empty observable state with idle defaults and UserDefaults-injected
init. Subsequent tasks add the state machine, persistence, and
SyncCoordinator wiring.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
rm .agent-tmp/test-output.txt
```

---

## Task 2: SyncProgress — receive transition

**Files:**
- Modify: `Backends/CloudKit/Sync/SyncProgress.swift`
- Modify: `MoolahTests/Sync/SyncProgressTests.swift`

- [ ] **Step 1: Write the failing test**

Append to `MoolahTests/Sync/SyncProgressTests.swift`:

```swift
  // MARK: - Receive transitions

  @Test
  func beginReceivingFromIdleEntersReceiving() {
    let progress = SyncProgress(userDefaults: ephemeralDefaults())
    progress.beginReceiving()
    #expect(progress.phase == .receiving)
  }

  @Test
  func beginReceivingWithPendingUploadsEntersSyncing() {
    let progress = SyncProgress(userDefaults: ephemeralDefaults())
    progress.updatePendingUploads(5)
    progress.beginReceiving()
    #expect(progress.phase == .syncing)
  }
```

- [ ] **Step 2: Run test to verify it fails**

```bash
just test SyncProgressTests 2>&1 | tee .agent-tmp/test-output.txt
```

Expected: build failure ("Value of type 'SyncProgress' has no member 'beginReceiving'").

- [ ] **Step 3: Implement the transitions**

Add to `SyncProgress.swift`:

```swift
  // MARK: - Mutations (called by SyncCoordinator)

  /// Update the mirror of `syncEngine.state.pendingRecordZoneChanges.count`.
  /// Called whenever the coordinator queues or sends changes.
  func updatePendingUploads(_ count: Int) {
    pendingUploads = count
  }

  /// `willFetchChanges` event — enter receive (or syncing if already sending).
  func beginReceiving() {
    if pendingUploads > 0 {
      phase = .syncing
    } else {
      phase = .receiving
    }
  }
```

- [ ] **Step 4: Run test to verify it passes**

```bash
just test SyncProgressTests 2>&1 | tee .agent-tmp/test-output.txt
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
just format
git add -u
git commit -m "$(cat <<'EOF'
feat(sync): SyncProgress.beginReceiving + pendingUploads mirror

beginReceiving routes to .receiving or .syncing based on pendingUploads.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
rm .agent-tmp/test-output.txt
```

---

## Task 3: SyncProgress — accumulate received counter

**Files:**
- Modify: `Backends/CloudKit/Sync/SyncProgress.swift`
- Modify: `MoolahTests/Sync/SyncProgressTests.swift`

- [ ] **Step 1: Write the failing test**

Append to `SyncProgressTests`:

```swift
  // MARK: - Counter accumulation

  @Test
  func recordReceivedAdvancesCounter() {
    let progress = SyncProgress(userDefaults: ephemeralDefaults())
    progress.beginReceiving()
    progress.recordReceived(modifications: 10, deletions: 3, moreComing: true)
    #expect(progress.recordsReceivedThisSession == 13)
    #expect(progress.moreComing == true)
  }

  @Test
  func recordReceivedIsAdditiveAcrossBatches() {
    let progress = SyncProgress(userDefaults: ephemeralDefaults())
    progress.beginReceiving()
    progress.recordReceived(modifications: 5, deletions: 0, moreComing: true)
    progress.recordReceived(modifications: 7, deletions: 2, moreComing: false)
    #expect(progress.recordsReceivedThisSession == 14)
    #expect(progress.moreComing == false)
  }
```

- [ ] **Step 2: Run test to verify it fails**

```bash
just test SyncProgressTests 2>&1 | tee .agent-tmp/test-output.txt
```

Expected: build failure ("no member 'recordReceived'").

- [ ] **Step 3: Implement the counter**

Add to `SyncProgress.swift`:

```swift
  /// `fetchedRecordZoneChanges` event — accumulate counts and capture
  /// `moreComing` from this batch.
  func recordReceived(modifications: Int, deletions: Int, moreComing: Bool) {
    recordsReceivedThisSession += modifications + deletions
    self.moreComing = moreComing
  }
```

- [ ] **Step 4: Run test to verify it passes**

```bash
just test SyncProgressTests 2>&1 | tee .agent-tmp/test-output.txt
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
just format
git add -u
git commit -m "$(cat <<'EOF'
feat(sync): SyncProgress.recordReceived accumulates batch counts

Modifications + deletions feed recordsReceivedThisSession; moreComing
from the latest batch is captured for the indeterminate-progress UI.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
rm .agent-tmp/test-output.txt
```

---

## Task 4: SyncProgress — settle on didFetchChanges

**Files:**
- Modify: `Backends/CloudKit/Sync/SyncProgress.swift`
- Modify: `MoolahTests/Sync/SyncProgressTests.swift`

- [ ] **Step 1: Write the failing test**

Append to `SyncProgressTests`:

```swift
  // MARK: - Settle

  @Test
  func endReceivingWithNoPendingSettlesAndResetsCounter() {
    let progress = SyncProgress(userDefaults: ephemeralDefaults())
    progress.beginReceiving()
    progress.recordReceived(modifications: 4, deletions: 0, moreComing: false)
    let now = Date(timeIntervalSince1970: 1_000_000)
    progress.endReceiving(now: now)
    #expect(progress.phase == .upToDate)
    #expect(progress.recordsReceivedThisSession == 0)
    #expect(progress.lastSettledAt == now)
  }

  @Test
  func endReceivingWithEmptySessionStillSettles() {
    let progress = SyncProgress(userDefaults: ephemeralDefaults())
    progress.beginReceiving()
    let now = Date(timeIntervalSince1970: 1_000_000)
    progress.endReceiving(now: now)
    #expect(progress.phase == .upToDate)
    #expect(progress.lastSettledAt == now)
  }

  @Test
  func endReceivingWithPendingUploadsTransitionsToSending() {
    let progress = SyncProgress(userDefaults: ephemeralDefaults())
    progress.updatePendingUploads(7)
    progress.beginReceiving()
    progress.endReceiving(now: Date())
    #expect(progress.phase == .sending)
    // Counter still resets so the next session starts at zero.
    #expect(progress.recordsReceivedThisSession == 0)
    // lastSettledAt does not advance until uploads also drain.
    #expect(progress.lastSettledAt == nil)
  }
```

- [ ] **Step 2: Run test to verify it fails**

```bash
just test SyncProgressTests 2>&1 | tee .agent-tmp/test-output.txt
```

Expected: build failure ("no member 'endReceiving'").

- [ ] **Step 3: Implement settle**

Add to `SyncProgress.swift`:

```swift
  /// `didFetchChanges` event — finish the fetch session and either settle
  /// (no pending uploads, no degraded reason) or transition to `.sending`
  /// while uploads drain.
  func endReceiving(now: Date) {
    recordsReceivedThisSession = 0
    moreComing = false
    if case .degraded = phase { return }
    if pendingUploads > 0 {
      phase = .sending
      return
    }
    phase = .upToDate
    lastSettledAt = now
    persistLastSettledAt()
  }

  // MARK: - Persistence

  private func persistLastSettledAt() {
    if let lastSettledAt {
      userDefaults.set(lastSettledAt, forKey: Self.lastSettledAtKey)
    } else {
      userDefaults.removeObject(forKey: Self.lastSettledAtKey)
    }
  }
```

- [ ] **Step 4: Run test to verify it passes**

```bash
just test SyncProgressTests 2>&1 | tee .agent-tmp/test-output.txt
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
just format
git add -u
git commit -m "$(cat <<'EOF'
feat(sync): SyncProgress.endReceiving settles or routes to .sending

Empty fetch sessions still settle (advances lastSettledAt during quiet
idle use). Pending uploads route to .sending without advancing the
timestamp until uploads drain.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
rm .agent-tmp/test-output.txt
```

---

## Task 5: SyncProgress — sending drains and settles

**Files:**
- Modify: `Backends/CloudKit/Sync/SyncProgress.swift`
- Modify: `MoolahTests/Sync/SyncProgressTests.swift`

- [ ] **Step 1: Write the failing test**

Append to `SyncProgressTests`:

```swift
  // MARK: - Sending → settle

  @Test
  func uploadsDrainingFromSendingSettles() {
    let progress = SyncProgress(userDefaults: ephemeralDefaults())
    progress.updatePendingUploads(3)
    progress.beginReceiving()
    progress.endReceiving(now: Date(timeIntervalSince1970: 0))
    #expect(progress.phase == .sending)
    let now = Date(timeIntervalSince1970: 2_000_000)
    progress.updatePendingUploads(0, now: now)
    #expect(progress.phase == .upToDate)
    #expect(progress.lastSettledAt == now)
  }

  @Test
  func uploadsDrainingDuringFetchDoesNotSettle() {
    let progress = SyncProgress(userDefaults: ephemeralDefaults())
    progress.updatePendingUploads(3)
    progress.beginReceiving()
    // Still receiving; uploads finishing should not preempt the fetch.
    progress.updatePendingUploads(0, now: Date())
    #expect(progress.phase == .receiving)
    #expect(progress.lastSettledAt == nil)
  }
```

- [ ] **Step 2: Run test to verify it fails**

```bash
just test SyncProgressTests 2>&1 | tee .agent-tmp/test-output.txt
```

Expected: build failure ("missing argument 'now'" or "extra argument").

- [ ] **Step 3: Implement the drain → settle path**

Replace `updatePendingUploads(_:)` in `SyncProgress.swift` with:

```swift
  /// Update the mirror of `syncEngine.state.pendingRecordZoneChanges.count`.
  /// Called whenever the coordinator queues or sends changes. When the count
  /// drops to 0:
  ///   - from `.sending`: settle (no fetch active).
  ///   - from `.syncing`: drop back to `.receiving` (fetch still going).
  ///   - otherwise: just update the mirror.
  func updatePendingUploads(_ count: Int, now: Date = Date()) {
    let wasNonzero = pendingUploads > 0
    pendingUploads = count
    guard count == 0, wasNonzero else { return }
    switch phase {
    case .sending:
      phase = .upToDate
      lastSettledAt = now
      persistLastSettledAt()
    case .syncing:
      phase = .receiving
    default:
      break
    }
  }
```

- [ ] **Step 4: Run test to verify it passes**

```bash
just test SyncProgressTests 2>&1 | tee .agent-tmp/test-output.txt
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
just format
git add -u
git commit -m "$(cat <<'EOF'
feat(sync): SyncProgress.updatePendingUploads settles on drain

When the count drops to 0 while in .sending we settle to .upToDate.
Drain during an active fetch is a no-op so the fetch lifecycle owns
the settle.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
rm .agent-tmp/test-output.txt
```

---

## Task 6: SyncProgress — degraded states

**Files:**
- Modify: `Backends/CloudKit/Sync/SyncProgress.swift`
- Modify: `MoolahTests/Sync/SyncProgressTests.swift`

- [ ] **Step 1: Write the failing test**

Append to `SyncProgressTests`:

```swift
  // MARK: - Degraded states

  @Test
  func quotaExceededEntersDegraded() {
    let progress = SyncProgress(userDefaults: ephemeralDefaults())
    progress.setQuotaExceeded(true)
    #expect(progress.phase == .degraded(.quotaExceeded))
  }

  @Test
  func quotaClearedRestoresIdle() {
    let progress = SyncProgress(userDefaults: ephemeralDefaults())
    progress.setQuotaExceeded(true)
    progress.setQuotaExceeded(false)
    #expect(progress.phase == .idle)
  }

  @Test
  func iCloudUnavailableEntersDegraded() {
    let progress = SyncProgress(userDefaults: ephemeralDefaults())
    progress.setICloudUnavailable(reason: .notSignedIn)
    #expect(progress.phase == .degraded(.iCloudUnavailable(.notSignedIn)))
  }

  @Test
  func retryingEntersDegraded() {
    let progress = SyncProgress(userDefaults: ephemeralDefaults())
    progress.setRetrying(true)
    #expect(progress.phase == .degraded(.retrying))
  }

  @Test
  func endReceivingDoesNotOverrideDegraded() {
    let progress = SyncProgress(userDefaults: ephemeralDefaults())
    progress.setQuotaExceeded(true)
    progress.beginReceiving()
    progress.endReceiving(now: Date())
    #expect(progress.phase == .degraded(.quotaExceeded))
  }
```

- [ ] **Step 2: Run test to verify it fails**

```bash
just test SyncProgressTests 2>&1 | tee .agent-tmp/test-output.txt
```

Expected: build failure ("no member 'setQuotaExceeded'", etc.).

- [ ] **Step 3: Implement the degraded setters and guard `beginReceiving`**

First, replace the existing `beginReceiving()` implementation (added in Task 2) with the guarded version:

```swift
  /// `willFetchChanges` event — enter receive (or syncing if already sending).
  /// No-op when in a degraded phase: the indicator should keep showing the
  /// degraded reason while sync continues in the background.
  func beginReceiving() {
    if case .degraded = phase { return }
    phase = pendingUploads > 0 ? .syncing : .receiving
  }
```

Then add the degraded setters:

```swift
  // MARK: - Degraded reasons

  /// Tracks the latest active degraded reason. Setters below toggle each
  /// reason independently; the resolver picks the most specific phase.
  private var quotaExceeded = false
  private var iCloudUnavailableReason: ICloudAvailability.UnavailableReason?
  private var retrying = false

  func setQuotaExceeded(_ active: Bool) {
    quotaExceeded = active
    resolveDegradedPhase()
  }

  func setICloudUnavailable(reason: ICloudAvailability.UnavailableReason?) {
    iCloudUnavailableReason = reason
    resolveDegradedPhase()
  }

  func setRetrying(_ active: Bool) {
    retrying = active
    resolveDegradedPhase()
  }

  /// Recompute `.phase` from the active degraded flags. Order: quota wins
  /// over iCloud availability wins over retry, because each is more
  /// actionable than the last. When all flags are clear, fall back to
  /// `.idle` (callers re-enter receive/send via the normal events).
  private func resolveDegradedPhase() {
    if quotaExceeded {
      phase = .degraded(.quotaExceeded)
      return
    }
    if let reason = iCloudUnavailableReason {
      phase = .degraded(.iCloudUnavailable(reason))
      return
    }
    if retrying {
      phase = .degraded(.retrying)
      return
    }
    if case .degraded = phase {
      phase = .idle
    }
  }
```

- [ ] **Step 4: Run test to verify it passes**

```bash
just test SyncProgressTests 2>&1 | tee .agent-tmp/test-output.txt
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
just format
git add -u
git commit -m "$(cat <<'EOF'
feat(sync): SyncProgress degraded states (quota / iCloud / retrying)

Three independent flags resolve to a single .degraded(reason) phase
in priority order. endReceiving and updatePendingUploads no longer
override an active degraded reason.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
rm .agent-tmp/test-output.txt
```

---

## Task 7: SyncProgress — start / stop / clear

**Files:**
- Modify: `Backends/CloudKit/Sync/SyncProgress.swift`
- Modify: `MoolahTests/Sync/SyncProgressTests.swift`

- [ ] **Step 1: Write the failing test**

Append to `SyncProgressTests`:

```swift
  // MARK: - Start / Stop

  @Test
  func didStartWithICloudAvailableEntersConnecting() {
    let progress = SyncProgress(userDefaults: ephemeralDefaults())
    progress.didStart(iCloudAvailable: true)
    #expect(progress.phase == .connecting)
  }

  @Test
  func didStartWithICloudUnavailableStaysIdle() {
    let progress = SyncProgress(userDefaults: ephemeralDefaults())
    progress.didStart(iCloudAvailable: false)
    #expect(progress.phase == .idle)
  }

  @Test
  func didStopReturnsToIdleAndClearsLastSettled() {
    let defaults = ephemeralDefaults()
    let progress = SyncProgress(userDefaults: defaults)
    progress.beginReceiving()
    progress.endReceiving(now: Date())
    #expect(progress.phase == .upToDate)
    progress.didStop()
    #expect(progress.phase == .idle)
    #expect(progress.lastSettledAt == nil)
    #expect(defaults.object(forKey: SyncProgress.lastSettledAtKey) == nil)
  }

  @Test
  func lastSettledAtRoundTripsThroughUserDefaults() {
    let defaults = ephemeralDefaults()
    let original = SyncProgress(userDefaults: defaults)
    original.beginReceiving()
    let stamp = Date(timeIntervalSince1970: 5_000_000)
    original.endReceiving(now: stamp)

    let rehydrated = SyncProgress(userDefaults: defaults)
    #expect(rehydrated.lastSettledAt == stamp)
  }
```

- [ ] **Step 2: Run test to verify it fails**

```bash
just test SyncProgressTests 2>&1 | tee .agent-tmp/test-output.txt
```

Expected: build failure ("no member 'didStart'" / "'didStop'").

- [ ] **Step 3: Implement start / stop**

Add to `SyncProgress.swift`:

```swift
  // MARK: - Start / Stop

  /// `SyncCoordinator.start()` finished priming `CKSyncEngine`.
  func didStart(iCloudAvailable: Bool) {
    if case .degraded = phase { return }
    phase = iCloudAvailable ? .connecting : .idle
  }

  /// `SyncCoordinator.stop()` — discard session state and persisted
  /// timestamp so a fresh sign-in starts clean.
  func didStop() {
    phase = .idle
    recordsReceivedThisSession = 0
    pendingUploads = 0
    moreComing = false
    quotaExceeded = false
    iCloudUnavailableReason = nil
    retrying = false
    lastSettledAt = nil
    persistLastSettledAt()
  }
```

- [ ] **Step 4: Run test to verify it passes**

```bash
just test SyncProgressTests 2>&1 | tee .agent-tmp/test-output.txt
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
just format
git add -u
git commit -m "$(cat <<'EOF'
feat(sync): SyncProgress.didStart / didStop and persisted timestamp

didStart enters .connecting only when iCloud is available; didStop
clears all session state and the persisted lastSettledAt. The init
hydrate path means a fresh launch sees the previous session's
timestamp.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
rm .agent-tmp/test-output.txt
```

---

## Task 8: Wire `SyncProgress` into `SyncCoordinator`

**Files:**
- Modify: `Backends/CloudKit/Sync/SyncCoordinator.swift`
- Modify: `MoolahTests/Sync/SyncCoordinatorTests.swift`

- [ ] **Step 1: Write the failing test**

Append to `MoolahTests/Sync/SyncCoordinatorTests.swift`:

```swift
  // MARK: - Progress wiring

  @Test
  func coordinatorExposesSyncProgress() throws {
    let manager = try ProfileContainerManager.forTesting()
    let coordinator = SyncCoordinator(containerManager: manager)
    #expect(coordinator.progress.phase == .idle)
  }
```

- [ ] **Step 2: Run test to verify it fails**

```bash
just test SyncCoordinatorTests/coordinatorExposesSyncProgress 2>&1 | tee .agent-tmp/test-output.txt
```

Expected: build failure ("no member 'progress'").

- [ ] **Step 3: Add the property and constructor wiring**

In `Backends/CloudKit/Sync/SyncCoordinator.swift`, between the `userDefaults` declaration and `static let backfillScanCompleteKeyPrefix`, add:

```swift
  /// Observable sync progress consumed by the sidebar footer and the
  /// `.heroDownloading` Welcome arm. Always non-nil; SyncCoordinator
  /// drives transitions from its existing event hooks.
  let progress: SyncProgress
```

In the `init(containerManager:userDefaults:isCloudKitAvailable:)` body, immediately after `self.userDefaults = userDefaults`, add:

```swift
    self.progress = SyncProgress(userDefaults: userDefaults)
```

- [ ] **Step 4: Run test to verify it passes**

```bash
just test SyncCoordinatorTests/coordinatorExposesSyncProgress 2>&1 | tee .agent-tmp/test-output.txt
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
just format
git add -u
git commit -m "$(cat <<'EOF'
feat(sync): expose SyncProgress on SyncCoordinator

Stored property initialised in the existing init; UserDefaults
instance is shared with the backfill flags so tests inject a single
suite.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
rm .agent-tmp/test-output.txt
```

---

## Task 9: Wire fetch lifecycle in `SyncCoordinator+Lifecycle`

**Files:**
- Modify: `Backends/CloudKit/Sync/SyncCoordinator+Lifecycle.swift`
- Modify: `MoolahTests/Sync/SyncCoordinatorTests.swift`

- [ ] **Step 1: Write the failing test**

Append to `MoolahTests/Sync/SyncCoordinatorTests.swift`:

```swift
  @Test
  func beginFetchingChangesEntersReceivingPhase() throws {
    let manager = try ProfileContainerManager.forTesting()
    let coordinator = SyncCoordinator(containerManager: manager)
    coordinator.beginFetchingChanges()
    #expect(coordinator.progress.phase == .receiving)
  }

  @Test
  func endFetchingChangesSettlesProgress() throws {
    let manager = try ProfileContainerManager.forTesting()
    let coordinator = SyncCoordinator(containerManager: manager)
    coordinator.beginFetchingChanges()
    coordinator.endFetchingChanges()
    #expect(coordinator.progress.phase == .upToDate)
    #expect(coordinator.progress.lastSettledAt != nil)
  }
```

- [ ] **Step 2: Run test to verify it fails**

```bash
just test SyncCoordinatorTests/beginFetchingChangesEntersReceivingPhase 2>&1 | tee .agent-tmp/test-output.txt
just test SyncCoordinatorTests/endFetchingChangesSettlesProgress 2>&1 | tee -a .agent-tmp/test-output.txt
```

Expected: assertion failures (phases stay `.idle`).

- [ ] **Step 3: Feed `progress` from the lifecycle hooks**

In `Backends/CloudKit/Sync/SyncCoordinator+Lifecycle.swift`:

In `beginFetchingChanges()`, after `fetchSessionTouchedIndexZone = false`, add:

```swift
    progress.beginReceiving()
```

In `endFetchingChanges()`, after `flushFetchSessionChanges()`, add:

```swift
    progress.endReceiving(now: Date())
```

In `stop()` — locate the body (search for `func stop()`) and after the existing teardown logic, add:

```swift
    progress.didStop()
```

In `completeStart(...)` (the function that finishes engine startup), after `iCloudAvailability` is set, add:

```swift
    progress.didStart(iCloudAvailable: iCloudAvailability == .available)
```

(If multiple branches set `iCloudAvailability`, add a single `progress.didStart(...)` at the end of `completeStart` that reads the now-final value.)

- [ ] **Step 4: Run test to verify it passes**

```bash
just test SyncCoordinatorTests 2>&1 | tee .agent-tmp/test-output.txt
grep -i 'failed\|error:' .agent-tmp/test-output.txt
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
just format
git add -u
git commit -m "$(cat <<'EOF'
feat(sync): feed SyncProgress from fetch lifecycle hooks

beginFetchingChanges / endFetchingChanges drive .receiving → settle.
completeStart sets .connecting; stop clears the timestamp.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
rm .agent-tmp/test-output.txt
```

---

## Task 10: Wire `fetchedRecordZoneChanges` to record counter

**Files:**
- Modify: `Backends/CloudKit/Sync/SyncCoordinator+RecordChanges.swift`
- Modify: `MoolahTests/Sync/SyncCoordinatorTests.swift`

- [ ] **Step 1: Write the failing test**

Append to `MoolahTests/Sync/SyncCoordinatorTests.swift`:

```swift
  @Test
  func fetchedRecordZoneChangesAdvancesReceivedCount() async throws {
    let manager = try ProfileContainerManager.forTesting()
    let coordinator = SyncCoordinator(containerManager: manager)
    coordinator.beginFetchingChanges()

    // The coordinator routes counts via accumulateProgressCounts, which is
    // public-for-tests. Drive it directly instead of constructing a
    // CKSyncEngine.Event.FetchedRecordZoneChanges (the type isn't trivially
    // constructible in a unit-test environment).
    coordinator.accumulateProgressCounts(
      modifications: 8, deletions: 2, moreComing: false)

    #expect(coordinator.progress.recordsReceivedThisSession == 10)
    #expect(coordinator.progress.moreComing == false)
  }
```

- [ ] **Step 2: Run test to verify it fails**

```bash
just test SyncCoordinatorTests/fetchedRecordZoneChangesAdvancesReceivedCount 2>&1 | tee .agent-tmp/test-output.txt
```

Expected: build failure ("no member 'accumulateProgressCounts'").

- [ ] **Step 3: Add the helper and call it from the fetch path**

In `Backends/CloudKit/Sync/SyncCoordinator+RecordChanges.swift`, add at the bottom of the `extension SyncCoordinator { ... }` body:

```swift
  /// Routes batch totals into `progress`. Public so unit tests can drive
  /// the counter without constructing a `CKSyncEngine.Event` value.
  @MainActor
  func accumulateProgressCounts(
    modifications: Int, deletions: Int, moreComing: Bool
  ) {
    progress.recordReceived(
      modifications: modifications, deletions: deletions, moreComing: moreComing)
  }
```

In `handleFetchedRecordZoneChangesAsync(_:)`, after the existing off-main grouping work but before the `for zoneID in allZones` loop, add:

```swift
    // Hop to main to update SyncProgress with this batch's counts. The
    // CKSyncEngine.Event already exposes moreComing; we capture it now so
    // the indicator can show "more coming" between batches.
    let modCount = changes.modifications.count
    let delCount = changes.deletions.count
    let moreComing = changes.moreComing
    await MainActor.run {
      self.accumulateProgressCounts(
        modifications: modCount, deletions: delCount, moreComing: moreComing)
    }
```

- [ ] **Step 4: Run test to verify it passes**

```bash
just test SyncCoordinatorTests 2>&1 | tee .agent-tmp/test-output.txt
grep -i 'failed\|error:' .agent-tmp/test-output.txt
```

Expected: PASS, no other regressions.

- [ ] **Step 5: Commit**

```bash
just format
git add -u
git commit -m "$(cat <<'EOF'
feat(sync): count fetched records into SyncProgress

handleFetchedRecordZoneChangesAsync now hops to main to update
SyncProgress with the batch's modification + deletion counts and
the moreComing flag.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
rm .agent-tmp/test-output.txt
```

---

## Task 11: Wire pending-uploads mirror + quota

**Files:**
- Modify: `Backends/CloudKit/Sync/SyncCoordinator+RecordChanges.swift`
- Modify: `Backends/CloudKit/Sync/SyncCoordinator+Lifecycle.swift`
- Modify: `MoolahTests/Sync/SyncCoordinatorTests.swift`

- [ ] **Step 1: Write the failing test**

Append to `MoolahTests/Sync/SyncCoordinatorTests.swift`:

```swift
  @Test
  func quotaFlagDrivesProgressDegraded() throws {
    let manager = try ProfileContainerManager.forTesting()
    let coordinator = SyncCoordinator(containerManager: manager)
    coordinator.applyQuotaState(true)
    #expect(coordinator.progress.phase == .degraded(.quotaExceeded))
    coordinator.applyQuotaState(false)
    // No active fetch / uploads pending → falls back to .idle
    #expect(coordinator.progress.phase == .idle)
  }
```

- [ ] **Step 2: Run test to verify it fails**

```bash
just test SyncCoordinatorTests/quotaFlagDrivesProgressDegraded 2>&1 | tee .agent-tmp/test-output.txt
```

Expected: build failure ("no member 'applyQuotaState'").

- [ ] **Step 3: Mirror quota + pending uploads into `progress`**

In `Backends/CloudKit/Sync/SyncCoordinator+RecordChanges.swift`, add at the bottom of the extension:

```swift
  /// Single setter for the quota-exceeded flag and its `progress` mirror.
  /// Replaces direct writes to `isQuotaExceeded` from the send path.
  @MainActor
  func applyQuotaState(_ exceeded: Bool) {
    isQuotaExceeded = exceeded
    progress.setQuotaExceeded(exceeded)
  }

  /// Pushes the live `pendingRecordZoneChanges.count` into `progress`.
  /// Called after every send event and after queueing changes.
  @MainActor
  func refreshPendingUploadsMirror() {
    let count = syncEngine?.state.pendingRecordZoneChanges.count ?? 0
    progress.updatePendingUploads(count)
  }
```

Now find the existing block in `handleSentRecordZoneChanges(_:)` that toggles `isQuotaExceeded`:

```swift
    if hasQuotaErrors {
      isQuotaExceeded = true
    } else if isQuotaExceeded {
      isQuotaExceeded = false
    }
```

Replace it with:

```swift
    applyQuotaState(hasQuotaErrors)
```

`applyQuotaState` is idempotent and the `setQuotaExceeded(false)` path only ever clears a `.degraded(.quotaExceeded)` phase; it never overrides `.receiving` / `.sending` / etc.

At the end of `handleSentRecordZoneChanges(_:)` (after all zone dispatches and quota handling), add:

```swift
    refreshPendingUploadsMirror()
```

In `Backends/CloudKit/Sync/SyncCoordinator+Lifecycle.swift`, in the helpers that queue changes (`queueRecordSave(_:)`, `queueRecordDelete(_:)`, and any `state.add(pendingRecordZoneChanges:)` call sites), add `refreshPendingUploadsMirror()` after each `state.add(...)` line so the mirror stays current.

- [ ] **Step 4: Run test to verify it passes**

```bash
just test SyncCoordinatorTests 2>&1 | tee .agent-tmp/test-output.txt
grep -i 'failed\|error:' .agent-tmp/test-output.txt
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
just format
git add -u
git commit -m "$(cat <<'EOF'
feat(sync): mirror quota + pendingUploads into SyncProgress

applyQuotaState replaces direct isQuotaExceeded writes; the mirror
flips .degraded(.quotaExceeded) atomically. refreshPendingUploadsMirror
is called after every state.add and every sent event so the upload
count stays live for the sidebar footer.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
rm .agent-tmp/test-output.txt
```

---

## Task 12: Wire `accountChange` to degraded

**Files:**
- Modify: `Backends/CloudKit/Sync/SyncCoordinator+Zones.swift`
- Modify: `MoolahTests/Sync/SyncCoordinatorTests.swift`

- [ ] **Step 1: Write the failing test**

Append to `MoolahTests/Sync/SyncCoordinatorTests.swift`:

```swift
  @Test
  func iCloudUnavailableMirrorsToProgress() throws {
    let manager = try ProfileContainerManager.forTesting()
    let coordinator = SyncCoordinator(containerManager: manager)
    coordinator.applyICloudAvailability(.unavailable(reason: .notSignedIn))
    #expect(
      coordinator.progress.phase
        == .degraded(.iCloudUnavailable(.notSignedIn)))

    coordinator.applyICloudAvailability(.available)
    #expect(coordinator.progress.phase == .idle)
  }
```

- [ ] **Step 2: Run test to verify it fails**

```bash
just test SyncCoordinatorTests/iCloudUnavailableMirrorsToProgress 2>&1 | tee .agent-tmp/test-output.txt
```

Expected: build failure ("no member 'applyICloudAvailability'").

- [ ] **Step 3: Add the unified setter**

In `Backends/CloudKit/Sync/SyncCoordinator+Zones.swift`, add at the bottom of the extension:

```swift
  /// Single setter for iCloud availability and its `progress` mirror.
  /// Replaces direct writes to `iCloudAvailability` from `handleAccountChange`
  /// and `completeStart`.
  @MainActor
  func applyICloudAvailability(_ availability: ICloudAvailability) {
    iCloudAvailability = availability
    let reason: ICloudAvailability.UnavailableReason?
    if case .unavailable(let r) = availability {
      reason = r
    } else {
      reason = nil
    }
    progress.setICloudUnavailable(reason: reason)
  }
```

Now replace direct writes to `iCloudAvailability` in this file with calls to `applyICloudAvailability(_:)`:

- The `handleAccountChange(_:)` body has lines like `iCloudAvailability = .available` and `iCloudAvailability = .unavailable(reason: .notSignedIn)` — replace each with `applyICloudAvailability(.available)` / `applyICloudAvailability(.unavailable(reason: .notSignedIn))`.
- Repeat for any other `iCloudAvailability = …` assignment in `+Zones.swift`.

In `Backends/CloudKit/Sync/SyncCoordinator+Lifecycle.swift`, replace the `self?.iCloudAvailability = Self.mapAccountStatus(status)` line inside the availability probe with `self?.applyICloudAvailability(Self.mapAccountStatus(status))`. Apply the same substitution to any other `iCloudAvailability = …` assignment in the lifecycle file.

- [ ] **Step 4: Run test to verify it passes**

```bash
just test SyncCoordinatorTests 2>&1 | tee .agent-tmp/test-output.txt
grep -i 'failed\|error:' .agent-tmp/test-output.txt
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
just format
git add -u
git commit -m "$(cat <<'EOF'
feat(sync): mirror iCloud availability into SyncProgress

applyICloudAvailability replaces direct iCloudAvailability writes;
SyncProgress.setICloudUnavailable flips .degraded(.iCloudUnavailable)
atomically with the public availability change.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
rm .agent-tmp/test-output.txt
```

---

## Task 13: Wire retry chain to degraded

**Files:**
- Modify: `Backends/CloudKit/Sync/SyncCoordinator+Refetch.swift`
- Modify: `MoolahTests/Sync/SyncCoordinatorTests.swift`

- [ ] **Step 1: Write the failing test**

Append to `MoolahTests/Sync/SyncCoordinatorTests.swift`:

```swift
  @Test
  func refetchAttemptsDriveRetryingPhase() async throws {
    let manager = try ProfileContainerManager.forTesting()
    let coordinator = SyncCoordinator(containerManager: manager)
    // bumpRefetchAttempts is internal; call it directly to drive the flag.
    coordinator.bumpRefetchAttempts()
    #expect(coordinator.progress.phase == .degraded(.retrying))
    coordinator.resetRefetchAttempts()
    #expect(coordinator.progress.phase == .idle)
  }
```

- [ ] **Step 2: Run test to verify it fails**

```bash
just test SyncCoordinatorTests/refetchAttemptsDriveRetryingPhase 2>&1 | tee .agent-tmp/test-output.txt
```

Expected: build failure or assertion failure (phase stays `.idle`).

- [ ] **Step 3: Drive `setRetrying` from the refetch path**

In `Backends/CloudKit/Sync/SyncCoordinator+Refetch.swift`:

Locate `func resetRefetchAttempts()` and add at the end of the body:

```swift
    progress.setRetrying(false)
```

Locate the function that increments `refetchAttempts` (likely `bumpRefetchAttempts()` or a section of `scheduleRefetch()` that does `refetchAttempts += 1`). After the increment, add:

```swift
    progress.setRetrying(true)
```

If there is no `bumpRefetchAttempts()` function, add one as a thin wrapper so the test can drive it without needing the full backoff path:

```swift
  /// Test seam: bump the attempt counter and flag retrying. Production code
  /// should call `scheduleRefetch()` instead.
  @MainActor
  func bumpRefetchAttempts() {
    refetchAttempts += 1
    progress.setRetrying(true)
  }
```

- [ ] **Step 4: Run test to verify it passes**

```bash
just test SyncCoordinatorTests 2>&1 | tee .agent-tmp/test-output.txt
grep -i 'failed\|error:' .agent-tmp/test-output.txt
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
just format
git add -u
git commit -m "$(cat <<'EOF'
feat(sync): mirror refetch chain into SyncProgress

resetRefetchAttempts clears .degraded(.retrying); the bump path sets
it. Footer now reflects the short-retry chain in real time.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
rm .agent-tmp/test-output.txt
```

---

## Task 14: Welcome resolver — `.heroDownloading` arm

**Files:**
- Modify: `Features/Profiles/Views/WelcomeStateResolver.swift`
- Modify: `MoolahTests/Profiles/WelcomeStateResolverTests.swift`

- [ ] **Step 1: Write the failing test**

Append to `MoolahTests/Profiles/WelcomeStateResolverTests.swift` (the file exists; if not, create it following the pattern of other resolver tests):

```swift
  // MARK: - heroDownloading

  @Test
  func resolveLandingShowsDownloadingWhenRecordsArrive() {
    let result = WelcomeStateResolver.resolve(
      phase: .landing,
      cloudProfilesCount: 0,
      iCloudAvailability: .available,
      indexFetchedAtLeastOnce: false,
      bannerDismissed: false,
      recordsReceivedThisSession: 47,
      wasDownloading: false
    )
    #expect(result == .heroDownloading(received: 47))
  }

  @Test
  func resolveLandingStaysCheckingWhenNoRecordsYet() {
    let result = WelcomeStateResolver.resolve(
      phase: .landing,
      cloudProfilesCount: 0,
      iCloudAvailability: .available,
      indexFetchedAtLeastOnce: false,
      bannerDismissed: false,
      recordsReceivedThisSession: 0,
      wasDownloading: false
    )
    #expect(result == .heroChecking)
  }

  @Test
  func resolveLandingStaysDownloadingOnceSeen() {
    // wasDownloading sticks even if the counter is zero (between sessions).
    let result = WelcomeStateResolver.resolve(
      phase: .landing,
      cloudProfilesCount: 0,
      iCloudAvailability: .available,
      indexFetchedAtLeastOnce: false,
      bannerDismissed: false,
      recordsReceivedThisSession: 0,
      wasDownloading: true
    )
    #expect(result == .heroDownloading(received: 0))
  }

  @Test
  func resolveLandingICloudOffOverridesDownloading() {
    let result = WelcomeStateResolver.resolve(
      phase: .landing,
      cloudProfilesCount: 0,
      iCloudAvailability: .unavailable(reason: .notSignedIn),
      indexFetchedAtLeastOnce: false,
      bannerDismissed: false,
      recordsReceivedThisSession: 47,
      wasDownloading: true
    )
    #expect(result == .heroOff(reason: .notSignedIn))
  }
```

- [ ] **Step 2: Run test to verify it fails**

```bash
just test WelcomeStateResolverTests 2>&1 | tee .agent-tmp/test-output.txt
```

Expected: build failure (`extra arguments` or `no case .heroDownloading`).

- [ ] **Step 3: Add the new state and inputs**

Replace the contents of `Features/Profiles/Views/WelcomeStateResolver.swift` with:

```swift
import Foundation

/// Pure-logic resolver for ``WelcomeView``'s state machine. Extracted
/// so every branch is unit-testable without SwiftUI. Inputs are value
/// types so this can stay nonisolated.
enum WelcomeStateResolver {
  enum ResolvedState: Equatable {
    case heroChecking
    case heroDownloading(received: Int)
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
    bannerDismissed: Bool,
    recordsReceivedThisSession: Int = 0,
    wasDownloading: Bool = false
  ) -> ResolvedState {
    switch phase {
    case .pickingProfile:
      return .picker

    case .creating:
      return resolveCreating(
        cloudProfilesCount: cloudProfilesCount,
        bannerDismissed: bannerDismissed
      )

    case .landing:
      return resolveLanding(
        cloudProfilesCount: cloudProfilesCount,
        iCloudAvailability: iCloudAvailability,
        indexFetchedAtLeastOnce: indexFetchedAtLeastOnce,
        recordsReceivedThisSession: recordsReceivedThisSession,
        wasDownloading: wasDownloading
      )
    }
  }

  private static func resolveCreating(
    cloudProfilesCount: Int,
    bannerDismissed: Bool
  ) -> ResolvedState {
    if bannerDismissed || cloudProfilesCount == 0 {
      return .form(banner: nil)
    }
    if cloudProfilesCount == 1 {
      return .form(banner: .singleArrived)
    }
    return .form(banner: .multiArrived(count: cloudProfilesCount))
  }

  private static func resolveLanding(
    cloudProfilesCount: Int,
    iCloudAvailability: ICloudAvailability,
    indexFetchedAtLeastOnce: Bool,
    recordsReceivedThisSession: Int,
    wasDownloading: Bool
  ) -> ResolvedState {
    if cloudProfilesCount == 1 {
      return .autoActivateSingle
    }
    if cloudProfilesCount >= 2 {
      return .picker
    }
    if case .unavailable(let reason) = iCloudAvailability {
      return .heroOff(reason: reason)
    }
    if indexFetchedAtLeastOnce {
      return .heroNoneFound
    }
    if wasDownloading || recordsReceivedThisSession > 0 {
      return .heroDownloading(received: recordsReceivedThisSession)
    }
    return .heroChecking
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
just test WelcomeStateResolverTests 2>&1 | tee .agent-tmp/test-output.txt
grep -i 'failed\|error:' .agent-tmp/test-output.txt
```

Expected: PASS. (Existing call sites still work because the new parameters have defaults.)

- [ ] **Step 5: Commit**

```bash
just format
git add -u
git commit -m "$(cat <<'EOF'
feat(welcome): WelcomeStateResolver gains .heroDownloading arm

Two new inputs (recordsReceivedThisSession + wasDownloading) drive the
new state. wasDownloading provides view-owned stickiness; iCloud-off
still overrides everything.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
rm .agent-tmp/test-output.txt
```

---

## Task 15: `ICloudStatusLine` — `.checkingActive(received:)` state

**Files:**
- Modify: `Features/Profiles/Views/ICloudStatusLine.swift`

- [ ] **Step 1: Add the new state arm**

Replace the existing `enum State` and `private var label: String` in `ICloudStatusLine.swift` with:

```swift
  enum State: Equatable {
    case checking
    case checkingActive(received: Int)
    case noneFound
  }
```

```swift
  private var label: String {
    switch state {
    case .checking:
      String(localized: "Checking iCloud for your profiles…")
    case .checkingActive(let received):
      let formatter = NumberFormatter()
      formatter.numberStyle = .decimal
      let receivedString = formatter.string(from: NSNumber(value: received)) ?? "\(received)"
      return String(
        localized: "Found data on iCloud · \(receivedString) records downloaded")
    case .noneFound:
      String(localized: "No profiles in iCloud yet.")
    }
  }
```

In `var body`, the spinner currently shows when `state == .checking`. Replace that condition to also show during downloading:

```swift
      if state == .checking {
        ProgressView()
          .controlSize(.small)
          .tint(WelcomeBrandColors.lightBlue)
      } else if case .checkingActive = state {
        ProgressView()
          .controlSize(.small)
          .tint(WelcomeBrandColors.lightBlue)
      }
```

In the `.accessibilityAddTraits(...)` modifier, update the condition the same way:

```swift
    .accessibilityAddTraits(
      {
        switch state {
        case .checking, .checkingActive: return [.updatesFrequently]
        case .noneFound: return []
        }
      }())
```

Append a new preview at the bottom:

```swift
#Preview("Downloading") {
  ZStack {
    WelcomeBrandColors.space.ignoresSafeArea()
    ICloudStatusLine(state: .checkingActive(received: 1234)).padding()
  }
  .frame(width: 360, height: 100)
}
```

- [ ] **Step 2: Run a build to confirm it compiles**

```bash
just build-mac 2>&1 | tee .agent-tmp/build-output.txt
grep -i 'error:' .agent-tmp/build-output.txt
```

Expected: build succeeds. (No tests yet — visual verification happens via the new previews and the UI test in Task 21.)

- [ ] **Step 3: Commit**

```bash
just format
git add -u
git commit -m "$(cat <<'EOF'
feat(welcome): ICloudStatusLine .checkingActive(received:) state

Adds the localized "Found data on iCloud · N records downloaded"
label and a matching preview. Spinner stays visible during the new
state.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
rm .agent-tmp/build-output.txt
```

---

## Task 16: `WelcomeView` — wire `wasDownloading` and progress to resolver

**Files:**
- Modify: `Features/Profiles/Views/WelcomeView.swift`

- [ ] **Step 1: Add stickiness state and forward the new resolver inputs**

In `Features/Profiles/Views/WelcomeView.swift`:

After the `@State private var bannerDismissed = false` line, add:

```swift
  @State private var hasEverDownloaded = false
```

Replace the existing `WelcomeStateResolver.resolve(...)` call inside `body` with:

```swift
    let received = syncCoordinator.progress.recordsReceivedThisSession
    let state = WelcomeStateResolver.resolve(
      phase: phase,
      cloudProfilesCount: profileStore.cloudProfiles.count,
      iCloudAvailability: profileStore.iCloudAvailability,
      indexFetchedAtLeastOnce: syncCoordinator.profileIndexFetchedAtLeastOnce,
      bannerDismissed: bannerDismissed,
      recordsReceivedThisSession: received,
      wasDownloading: hasEverDownloaded
    )
```

After the existing `.onChange(of: phase)` modifier in `body`, add:

```swift
      .onChange(of: received) { _, newValue in
        if newValue > 0 { hasEverDownloaded = true }
      }
```

Inside the `content(for:)` switch, add a new case before `.heroOff`:

```swift
    case .heroDownloading(let count):
      heroDownloadingView(received: count)
```

Add a new helper function below `heroView(state:)`:

```swift
  @ViewBuilder
  private func heroDownloadingView(received: Int) -> some View {
    WelcomeHero(
      mode: .downloading(received: received),
      primaryAction: beginCreate,
      footer: { ICloudStatusLine(state: .checkingActive(received: received)) }
    )
  }
```

Update `heroView(state:)` to pass `mode: .checking` to `WelcomeHero`:

```swift
  @ViewBuilder
  private func heroView(state: ICloudStatusLine.State) -> some View {
    WelcomeHero(
      mode: .checking,
      primaryAction: beginCreate,
      footer: { ICloudStatusLine(state: state) }
    )
  }
```

(`WelcomeHero` learns about `mode` in Task 17. The build will fail until then; that's fine — the test we run in Step 2 only exercises the resolver, not the hero.)

- [ ] **Step 2: Run resolver tests to confirm WelcomeView still compiles in isolation is not yet possible**

Skip the test run for this task — Task 17 introduces `WelcomeHero.Mode` and the build only goes green once both tasks land. Confirm only that the changes are syntactically minimal.

- [ ] **Step 3: Commit**

```bash
just format
git add -u
git commit -m "$(cat <<'EOF'
feat(welcome): WelcomeView wires SyncProgress + wasDownloading

hasEverDownloaded sticks once records arrive; the resolver call
forwards both new inputs. Hero call sites now pass a mode parameter
that WelcomeHero learns about in the next task.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 17: `WelcomeHero` — animated layout transition

**Files:**
- Modify: `Features/Profiles/Views/WelcomeHero.swift`

- [ ] **Step 1: Add the `Mode` enum and conditional layout**

Replace the existing `WelcomeHero` declaration (everything from `struct WelcomeHero<Footer: View>: View {` through the closing `}`) with:

```swift
struct WelcomeHero<Footer: View>: View {
  enum Mode: Equatable {
    case checking
    case downloading(received: Int)
  }

  let mode: Mode
  let primaryAction: () -> Void
  @ViewBuilder let footer: () -> Footer

  @FocusState private var focus: Focus?
  @Namespace private var heroNamespace

  private enum Focus: Hashable {
    case primaryCTA
  }

  init(
    mode: Mode = .checking,
    primaryAction: @escaping () -> Void,
    @ViewBuilder footer: @escaping () -> Footer
  ) {
    self.mode = mode
    self.primaryAction = primaryAction
    self.footer = footer
  }

  var body: some View {
    ZStack(alignment: .leading) {
      WelcomeBrandColors.space.ignoresSafeArea()
      heroContent
    }
    .task { focus = .primaryCTA }
    .animation(.easeInOut(duration: 0.4), value: mode)
  }

  private var heroContent: some View {
    VStack(alignment: .leading, spacing: 0) {
      Spacer(minLength: mode == .checking ? 48 : 24)
      eyebrow
      titleBlock
      if case .checking = mode { subhead }
      Spacer()
      ctaButton
      footer().frame(maxWidth: 320, alignment: .leading)
      if case .downloading = mode { downloadFootnote }
      Spacer(minLength: 28)
    }
    .padding(.horizontal, 32)
  }

  private var eyebrow: some View {
    Text("Moolah", comment: "First-run hero eyebrow label")
      .font(.caption.weight(.medium))
      .tracking(1.8)
      .textCase(.uppercase)
      .foregroundStyle(WelcomeBrandColors.balanceGold)
      .matchedGeometryEffect(id: "eyebrow", in: heroNamespace)
      .accessibilityHidden(true)
  }

  private var titleBlock: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text("Your money,", comment: "First-run hero title line 1")
        .foregroundStyle(.white)
      Text("rock solid.", comment: "First-run hero title line 2")
        .foregroundStyle(WelcomeBrandColors.balanceGold)
    }
    .font(mode == .checking ? .largeTitle.bold() : .title.bold())
    .matchedGeometryEffect(id: "title", in: heroNamespace)
    .accessibilityElement(children: .combine)
    .accessibilityLabel("Your money, rock solid.")
    .accessibilityAddTraits(.isHeader)
    .padding(.top, 10)
  }

  private var subhead: some View {
    Text(
      "Money stuff should be boring. Locked down, sorted out, taken care of — so the rest of your life doesn't have to be.",
      comment: "First-run hero subhead"
    )
    .font(.body)
    .foregroundStyle(WelcomeBrandColors.muted)
    .lineLimit(nil)
    .fixedSize(horizontal: false, vertical: true)
    .frame(maxWidth: 320, alignment: .leading)
    .padding(.top, 14)
  }

  private var ctaButton: some View {
    Button(action: primaryAction) {
      Text(buttonLabel, comment: "First-run primary CTA")
        .font(mode == .checking ? .headline : .subheadline)
        .frame(maxWidth: 280)
        .frame(minHeight: mode == .checking ? 44 : 36)
    }
    .buttonStyle(PrimaryHeroButtonStyle(prominent: mode == .checking))
    .focusable(true)
    .focused($focus, equals: .primaryCTA)
    .matchedGeometryEffect(id: "cta", in: heroNamespace)
    .onKeyPress(.return) {
      primaryAction()
      return .handled
    }
    .padding(.bottom, 12)
  }

  private var buttonLabel: String {
    switch mode {
    case .checking: return String(localized: "Get started")
    case .downloading: return String(localized: "Create a new profile")
    }
  }

  private var downloadFootnote: some View {
    Text(
      "Download from iCloud will continue in the background.",
      comment: "First-run footnote shown while iCloud data is downloading"
    )
    .font(.footnote)
    .foregroundStyle(WelcomeBrandColors.muted)
    .padding(.top, 8)
  }
}

private struct PrimaryHeroButtonStyle: ButtonStyle {
  let prominent: Bool

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .foregroundStyle(.white)
      .padding(.vertical, prominent ? 12 : 8)
      .padding(.horizontal, prominent ? 24 : 18)
      .background(
        WelcomeBrandColors.incomeBlue
          .opacity(buttonOpacity(pressed: configuration.isPressed))
      )
      .clipShape(.rect(cornerRadius: 10))
      .contentShape(.rect)
  }

  private func buttonOpacity(pressed: Bool) -> Double {
    let base = prominent ? 1.0 : 0.6
    return pressed ? base * 0.85 : base
  }
}
```

Append a new preview at the bottom for the downloading mode:

```swift
#Preview("WelcomeHero — downloading") {
  WelcomeHero(
    mode: .downloading(received: 1234),
    primaryAction: {},
    footer: { ICloudStatusLine(state: .checkingActive(received: 1234)) }
  )
  .frame(width: 420, height: 560)
}
```

- [ ] **Step 2: Build to verify the Welcome flow compiles**

```bash
just build-mac 2>&1 | tee .agent-tmp/build-output.txt
grep -i 'error:' .agent-tmp/build-output.txt
```

Expected: build succeeds.

- [ ] **Step 3: Run the full Welcome resolver suite**

```bash
just test WelcomeStateResolverTests 2>&1 | tee .agent-tmp/test-output.txt
grep -i 'failed\|error:' .agent-tmp/test-output.txt
```

Expected: PASS.

- [ ] **Step 4: Commit**

```bash
just format
git add -u
git commit -m "$(cat <<'EOF'
feat(welcome): WelcomeHero animates between checking and downloading

mode: .checking | .downloading drives layout. matchedGeometryEffect
on the eyebrow / title / CTA gives a smooth in-place transition;
button label switches to "Create a new profile" with a footnote
explaining background download.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
rm .agent-tmp/build-output.txt .agent-tmp/test-output.txt
```

---

## Task 18: `SyncProgressFooter` — view (macOS + iOS)

**Files:**
- Create: `Features/Sync/SyncProgressFooter.swift`
- Create: `MoolahTests/Features/SyncProgressFooterTests.swift`
- Modify: `UITestSupport/UITestIdentifiers.swift`

- [ ] **Step 1: Add identifiers**

In `UITestSupport/UITestIdentifiers.swift`, add a new nested enum (alongside the existing `Welcome` enum, or wherever sibling enums live):

```swift
public enum SyncFooter {
  public static let container = "sync.footer.container"
  public static let label = "sync.footer.label"
  public static let detail = "sync.footer.detail"
}
```

- [ ] **Step 2: Write the failing test**

Create `MoolahTests/Features/SyncProgressFooterTests.swift`:

```swift
import Foundation
import Testing

@testable import Moolah

@Suite("SyncProgressFooter labels")
@MainActor
struct SyncProgressFooterTests {

  @Test
  func upToDateLabelMatchesPhase() {
    let viewModel = SyncProgressFooter.ViewModel(
      phase: .upToDate,
      recordsReceivedThisSession: 0,
      pendingUploads: 0,
      lastSettledAt: Date(timeIntervalSince1970: 0)
    )
    #expect(viewModel.title == "Up to date")
    #expect(viewModel.iconName == "checkmark.icloud")
  }

  @Test
  func receivingLabelIncludesCount() {
    let viewModel = SyncProgressFooter.ViewModel(
      phase: .receiving,
      recordsReceivedThisSession: 1234,
      pendingUploads: 0,
      lastSettledAt: nil
    )
    #expect(viewModel.title == "Receiving from iCloud")
    #expect(viewModel.detail == "1,234 records")
    #expect(viewModel.iconName == "icloud.and.arrow.down")
  }

  @Test
  func sendingLabelIncludesCount() {
    let viewModel = SyncProgressFooter.ViewModel(
      phase: .sending,
      recordsReceivedThisSession: 0,
      pendingUploads: 12,
      lastSettledAt: nil
    )
    #expect(viewModel.title == "Sending to iCloud")
    #expect(viewModel.detail == "12 changes")
  }

  @Test
  func syncingLabelCombinesCounts() {
    let viewModel = SyncProgressFooter.ViewModel(
      phase: .syncing,
      recordsReceivedThisSession: 1234,
      pendingUploads: 47,
      lastSettledAt: nil
    )
    #expect(viewModel.title == "Syncing with iCloud")
    #expect(viewModel.detail == "1,234 received · 47 to send")
  }

  @Test
  func degradedQuotaLabel() {
    let viewModel = SyncProgressFooter.ViewModel(
      phase: .degraded(.quotaExceeded),
      recordsReceivedThisSession: 0,
      pendingUploads: 0,
      lastSettledAt: nil
    )
    #expect(viewModel.title == "iCloud storage full")
    #expect(viewModel.iconName == "exclamationmark.icloud")
  }

  @Test
  func degradedICloudUnavailableLabel() {
    let viewModel = SyncProgressFooter.ViewModel(
      phase: .degraded(.iCloudUnavailable(.notSignedIn)),
      recordsReceivedThisSession: 0,
      pendingUploads: 0,
      lastSettledAt: nil
    )
    #expect(viewModel.title == "iCloud unavailable")
    #expect(viewModel.iconName == "xmark.icloud")
  }

  @Test
  func degradedRetryingLabel() {
    let viewModel = SyncProgressFooter.ViewModel(
      phase: .degraded(.retrying),
      recordsReceivedThisSession: 0,
      pendingUploads: 0,
      lastSettledAt: nil
    )
    #expect(viewModel.title == "Retrying")
    #expect(viewModel.iconName == "arrow.clockwise.icloud")
  }
}
```

- [ ] **Step 3: Run the test to verify it fails**

```bash
just test SyncProgressFooterTests 2>&1 | tee .agent-tmp/test-output.txt
```

Expected: build failure ("Cannot find 'SyncProgressFooter' in scope").

- [ ] **Step 4: Create the view**

Create `Features/Sync/SyncProgressFooter.swift`:

```swift
import SwiftUI

/// Photos-style sync indicator for the sidebar footer.
///
/// Reads `SyncCoordinator.progress` and renders a two-line row on macOS
/// (icon + status + relative timestamp / counts) or a one-line compact
/// row on iOS. The row stays visible at all times on macOS so users know
/// the indicator exists; on iOS it only appears when the sidebar drawer
/// is open.
///
/// The label mapping lives on a nested `ViewModel` so it can be unit-tested
/// without SwiftUI.
struct SyncProgressFooter: View {
  @Environment(SyncCoordinator.self) private var syncCoordinator

  var body: some View {
    let viewModel = ViewModel(
      phase: syncCoordinator.progress.phase,
      recordsReceivedThisSession: syncCoordinator.progress.recordsReceivedThisSession,
      pendingUploads: syncCoordinator.progress.pendingUploads,
      lastSettledAt: syncCoordinator.progress.lastSettledAt
    )

    #if os(macOS)
      macOSRow(viewModel: viewModel)
    #else
      iOSRow(viewModel: viewModel)
    #endif
  }

  // MARK: - macOS

  #if os(macOS)
    @ViewBuilder
    private func macOSRow(viewModel: ViewModel) -> some View {
      HStack(alignment: .center, spacing: 10) {
        Image(systemName: viewModel.iconName)
          .foregroundStyle(viewModel.iconTint)
          .frame(width: 20)
        VStack(alignment: .leading, spacing: 2) {
          Text(viewModel.title)
            .font(.subheadline)
            .accessibilityIdentifier(UITestIdentifiers.SyncFooter.label)
          if let detail = viewModel.detail {
            Text(detail)
              .font(.caption)
              .foregroundStyle(.secondary)
              .monospacedDigit()
              .accessibilityIdentifier(UITestIdentifiers.SyncFooter.detail)
          } else if let lastSettledAt = viewModel.lastSettledAt {
            TimelineView(.periodic(from: .now, by: 60)) { context in
              Text(
                "Updated \(lastSettledAt, format: .relative(presentation: .named, unitsStyle: .wide))",
                comment: "Relative time since last successful sync (sidebar footer)"
              )
              .font(.caption)
              .foregroundStyle(.secondary)
              .accessibilityIdentifier(UITestIdentifiers.SyncFooter.detail)
              .id(context.date)
            }
          }
        }
        Spacer()
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
      .background(.regularMaterial)
      .accessibilityElement(children: .combine)
      .accessibilityIdentifier(UITestIdentifiers.SyncFooter.container)
    }
  #endif

  // MARK: - iOS

  #if os(iOS)
    @ViewBuilder
    private func iOSRow(viewModel: ViewModel) -> some View {
      HStack(spacing: 8) {
        Image(systemName: viewModel.iconName)
          .foregroundStyle(viewModel.iconTint)
        Text(viewModel.iOSLabel)
          .font(.caption)
          .foregroundStyle(.secondary)
          .monospacedDigit()
          .accessibilityIdentifier(UITestIdentifiers.SyncFooter.label)
        Spacer()
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 6)
      .accessibilityElement(children: .combine)
      .accessibilityIdentifier(UITestIdentifiers.SyncFooter.container)
    }
  #endif

  // MARK: - View model

  struct ViewModel {
    let phase: SyncProgress.Phase
    let recordsReceivedThisSession: Int
    let pendingUploads: Int
    let lastSettledAt: Date?

    var title: String {
      switch phase {
      case .idle, .connecting: return "Connecting…"
      case .upToDate: return "Up to date"
      case .receiving: return "Receiving from iCloud"
      case .sending: return "Sending to iCloud"
      case .syncing: return "Syncing with iCloud"
      case .degraded(.quotaExceeded): return "iCloud storage full"
      case .degraded(.iCloudUnavailable): return "iCloud unavailable"
      case .degraded(.retrying): return "Retrying"
      }
    }

    var detail: String? {
      let formatter = NumberFormatter()
      formatter.numberStyle = .decimal
      switch phase {
      case .receiving:
        let count = formatter.string(from: NSNumber(value: recordsReceivedThisSession))
          ?? "\(recordsReceivedThisSession)"
        return "\(count) records"
      case .sending:
        let count = formatter.string(from: NSNumber(value: pendingUploads))
          ?? "\(pendingUploads)"
        return "\(count) changes"
      case .syncing:
        let r = formatter.string(from: NSNumber(value: recordsReceivedThisSession))
          ?? "\(recordsReceivedThisSession)"
        let s = formatter.string(from: NSNumber(value: pendingUploads))
          ?? "\(pendingUploads)"
        return "\(r) received · \(s) to send"
      case .upToDate:
        return nil  // Footer falls through to relative timestamp
      case .idle, .connecting, .degraded:
        return nil
      }
    }

    var iconName: String {
      switch phase {
      case .idle, .connecting: return "icloud"
      case .upToDate: return "checkmark.icloud"
      case .receiving: return "icloud.and.arrow.down"
      case .sending: return "icloud.and.arrow.up"
      case .syncing: return "arrow.up.arrow.down.circle"
      case .degraded(.quotaExceeded): return "exclamationmark.icloud"
      case .degraded(.iCloudUnavailable): return "xmark.icloud"
      case .degraded(.retrying): return "arrow.clockwise.icloud"
      }
    }

    var iconTint: Color {
      switch phase {
      case .degraded: return .orange
      default: return .secondary
      }
    }

    /// One-line compact label used on iOS (no relative timestamp line).
    var iOSLabel: String {
      if let detail { return "\(title) · \(detail)" }
      return title
    }
  }
}
```

- [ ] **Step 5: Run the test**

```bash
just test SyncProgressFooterTests 2>&1 | tee .agent-tmp/test-output.txt
grep -i 'failed\|error:' .agent-tmp/test-output.txt
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
just format
git add -u Features/Sync/SyncProgressFooter.swift MoolahTests/Features/SyncProgressFooterTests.swift UITestSupport/UITestIdentifiers.swift
git commit -m "$(cat <<'EOF'
feat(sync): SyncProgressFooter view + label tests

Photos-style sidebar footer. macOS row is two-line with relative
timestamp via TimelineView; iOS row is one-line compact. Label /
icon mapping lives on a nested ViewModel so it stays unit-testable
without SwiftUI.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
rm .agent-tmp/test-output.txt
```

---

## Task 19: Mount `SyncProgressFooter` in `SidebarView`

**Files:**
- Modify: `Features/Navigation/SidebarView.swift`

- [ ] **Step 1: Add the safe-area inset**

In `Features/Navigation/SidebarView.swift`, locate the `body` property (the `var body: some View { List(selection: $selection) { … } … }` block).

Find the trailing `.refreshable { … }` modifier and add the following directly after it (before any other trailing modifiers):

```swift
    .safeAreaInset(edge: .bottom, spacing: 0) {
      SyncProgressFooter()
    }
```

- [ ] **Step 2: Build to verify the wiring compiles**

```bash
just build-mac 2>&1 | tee .agent-tmp/build-output.txt
grep -i 'error:' .agent-tmp/build-output.txt
```

Expected: build succeeds.

- [ ] **Step 3: Smoke-test in the running app**

```bash
just run-mac 2>&1 | tee .agent-tmp/run-output.txt &
```

Wait ~5 seconds for the window to appear. Confirm visually that the sidebar shows the footer row at the bottom (it should read "Connecting…" or "Up to date · Updated …" depending on iCloud state). Quit the app.

- [ ] **Step 4: Commit**

```bash
just format
git add -u
git commit -m "$(cat <<'EOF'
feat(sync): mount SyncProgressFooter in sidebar

safeAreaInset(edge: .bottom) so the footer sticks below the list and
never gets pushed off by long content. Visible on both macOS (always)
and iOS (only when the drawer is open).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
rm .agent-tmp/build-output.txt .agent-tmp/run-output.txt
```

---

## Task 20: UI test seeds for downloading + footer states

**Files:**
- Modify: `UITestSupport/UITestSeed.swift`

- [ ] **Step 1: Add seed cases**

In `UITestSupport/UITestSeed.swift`, extend the `UITestSeed` enum with:

```swift
  /// Forces the Welcome screen into `.heroDownloading(received: 1234)` so
  /// the new "Found data on iCloud · 1,234 records downloaded" copy and
  /// the de-emphasized "Create a new profile" button can be verified.
  case welcomeDownloading

  /// Drives `SyncProgress` into `.upToDate` with a `lastSettledAt` ~5
  /// minutes in the past so the macOS sidebar footer renders
  /// "Up to date · Updated 5 minutes ago".
  case sidebarFooterUpToDate

  /// Drives `SyncProgress` into `.receiving` with a non-zero count so the
  /// sidebar footer renders the receive label and count.
  case sidebarFooterReceiving

  /// Drives `SyncProgress` into `.sending` with `pendingUploads = 12`.
  case sidebarFooterSending
```

- [ ] **Step 2: Wire the seeds into `MoolahApp+Setup` (or wherever seed hydration runs)**

Search for the existing seed-hydration code:

```bash
grep -n "UITestSeed" /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/fix-sync-silent-drop/App/*.swift
```

Locate the file that maps `UITestSeed` cases to setup actions (likely `MoolahApp+Setup.swift` or `App/UITestingLauncherView.swift`). Inside the switch (or equivalent dispatch), add cases for the four new seeds. For each new seed, add a hydration block that:

- For `.welcomeDownloading`: calls `syncCoordinator.progress.beginReceiving()` then `syncCoordinator.progress.recordReceived(modifications: 1234, deletions: 0, moreComing: true)`. Leave `iCloudAvailability` `.available` and `profileIndexFetchedAtLeastOnce` `false`.
- For `.sidebarFooterUpToDate`: drive `progress.beginReceiving()`, then `progress.endReceiving(now: Date(timeIntervalSinceNow: -300))`.
- For `.sidebarFooterReceiving`: `progress.beginReceiving()`; `progress.recordReceived(modifications: 1234, deletions: 0, moreComing: true)`.
- For `.sidebarFooterSending`: `progress.updatePendingUploads(12)`; then call `progress.beginReceiving()` and `progress.endReceiving(now: Date())` to land in `.sending`.

If the existing seed dispatch is a single function, factor a small helper:

```swift
@MainActor
private func applyProgressSeed(_ seed: UITestSeed, progress: SyncProgress) {
  switch seed {
  case .welcomeDownloading, .sidebarFooterReceiving:
    progress.beginReceiving()
    progress.recordReceived(modifications: 1234, deletions: 0, moreComing: true)
  case .sidebarFooterUpToDate:
    progress.beginReceiving()
    progress.endReceiving(now: Date(timeIntervalSinceNow: -300))
  case .sidebarFooterSending:
    progress.updatePendingUploads(12)
    progress.beginReceiving()
    progress.endReceiving(now: Date())
  case .tradeBaseline:
    break
  }
}
```

…and call it from the existing seed switch.

- [ ] **Step 3: Build to verify**

```bash
just build-mac 2>&1 | tee .agent-tmp/build-output.txt
grep -i 'error:' .agent-tmp/build-output.txt
```

Expected: build succeeds.

- [ ] **Step 4: Commit**

```bash
just format
git add -u
git commit -m "$(cat <<'EOF'
test(sync): UITestSeeds for downloading + footer states

Four new seeds drive Welcome and the sidebar footer into the states
the next two tasks exercise via XCUITest.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
rm .agent-tmp/build-output.txt
```

---

## Task 21: UI test — Welcome `.heroDownloading`

**Files:**
- Create: `MoolahUITests_macOS/Welcome/WelcomeDownloadingUITests.swift`

- [ ] **Step 1: Write the UI test**

Create `MoolahUITests_macOS/Welcome/WelcomeDownloadingUITests.swift`:

```swift
import XCTest

@testable import UITestSupport

@MainActor
final class WelcomeDownloadingUITests: XCTestCase {

  override func setUp() {
    super.setUp()
    continueAfterFailure = false
  }

  func testWelcomeShowsDownloadingMessageAndAlternateButton() {
    let app = XCUIApplication()
    app.launchArguments = ["--ui-testing"]
    app.launchEnvironment["UI_TESTING_SEED"] = UITestSeed.welcomeDownloading.rawValue
    app.launch()

    let downloadingLabel = app.staticTexts.matching(
      NSPredicate(
        format: "label CONTAINS[c] 'Found data on iCloud' AND label CONTAINS '1,234'")
    ).firstMatch
    XCTAssertTrue(
      downloadingLabel.waitForExistence(timeout: 5),
      "Expected 'Found data on iCloud · 1,234 records downloaded' label")

    let createButton = app.buttons["Create a new profile"]
    XCTAssertTrue(
      createButton.waitForExistence(timeout: 1),
      "Expected the alternate 'Create a new profile' CTA")

    let footnote = app.staticTexts.matching(
      NSPredicate(
        format: "label CONTAINS[c] 'continue in the background'")
    ).firstMatch
    XCTAssertTrue(
      footnote.waitForExistence(timeout: 1),
      "Expected the background-download footnote")
  }
}
```

- [ ] **Step 2: Run the test**

```bash
just test-mac WelcomeDownloadingUITests 2>&1 | tee .agent-tmp/test-output.txt
grep -i 'failed\|error:' .agent-tmp/test-output.txt
```

Expected: PASS.

- [ ] **Step 3: Commit**

```bash
just format
git add -u
git commit -m "$(cat <<'EOF'
test(welcome): UI test for .heroDownloading state

Drives the welcomeDownloading seed and verifies the downloaded-records
copy, the alternate "Create a new profile" CTA, and the
background-download footnote all appear together.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
rm .agent-tmp/test-output.txt
```

---

## Task 22: UI test — sidebar footer states

**Files:**
- Create: `MoolahUITests_macOS/Sync/SyncProgressFooterUITests.swift`

- [ ] **Step 1: Write the UI test**

Create `MoolahUITests_macOS/Sync/SyncProgressFooterUITests.swift`:

```swift
import XCTest

@testable import UITestSupport

@MainActor
final class SyncProgressFooterUITests: XCTestCase {

  override func setUp() {
    super.setUp()
    continueAfterFailure = false
  }

  func testFooterShowsReceivingWithCount() {
    let app = launch(seed: .sidebarFooterReceiving)
    let labelMatcher = app.descendants(matching: .any).matching(
      identifier: UITestIdentifiers.SyncFooter.label
    ).firstMatch
    XCTAssertTrue(labelMatcher.waitForExistence(timeout: 5))
    XCTAssertEqual(labelMatcher.label, "Receiving from iCloud")

    let detailMatcher = app.descendants(matching: .any).matching(
      identifier: UITestIdentifiers.SyncFooter.detail
    ).firstMatch
    XCTAssertTrue(detailMatcher.waitForExistence(timeout: 1))
    XCTAssertEqual(detailMatcher.label, "1,234 records")
  }

  func testFooterShowsSendingWithCount() {
    let app = launch(seed: .sidebarFooterSending)
    let labelMatcher = app.descendants(matching: .any).matching(
      identifier: UITestIdentifiers.SyncFooter.label
    ).firstMatch
    XCTAssertTrue(labelMatcher.waitForExistence(timeout: 5))
    XCTAssertEqual(labelMatcher.label, "Sending to iCloud")
  }

  func testFooterShowsUpToDateWithRelativeTimestamp() {
    let app = launch(seed: .sidebarFooterUpToDate)
    let labelMatcher = app.descendants(matching: .any).matching(
      identifier: UITestIdentifiers.SyncFooter.label
    ).firstMatch
    XCTAssertTrue(labelMatcher.waitForExistence(timeout: 5))
    XCTAssertEqual(labelMatcher.label, "Up to date")

    let detailMatcher = app.descendants(matching: .any).matching(
      identifier: UITestIdentifiers.SyncFooter.detail
    ).firstMatch
    XCTAssertTrue(detailMatcher.waitForExistence(timeout: 1))
    XCTAssertTrue(
      detailMatcher.label.contains("Updated") && detailMatcher.label.contains("ago"),
      "Expected relative timestamp; got \(detailMatcher.label)")
  }

  // MARK: - Helpers

  @MainActor
  private func launch(seed: UITestSeed) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = ["--ui-testing"]
    app.launchEnvironment["UI_TESTING_SEED"] = seed.rawValue
    app.launch()
    return app
  }
}
```

- [ ] **Step 2: Run the test**

```bash
just test-mac SyncProgressFooterUITests 2>&1 | tee .agent-tmp/test-output.txt
grep -i 'failed\|error:' .agent-tmp/test-output.txt
```

Expected: PASS.

- [ ] **Step 3: Commit**

```bash
just format
git add -u
git commit -m "$(cat <<'EOF'
test(sync): UI tests for sidebar footer states

Three states (receiving / sending / upToDate) are exercised via the
new seeds; assertions read the dedicated accessibility identifiers
on the title and detail labels.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
rm .agent-tmp/test-output.txt
```

---

## Task 23: Final verification — full test suite + format check

**Files:** none (verification only)

- [ ] **Step 1: Run the full suite on both platforms**

```bash
just test 2>&1 | tee .agent-tmp/test-final.txt
grep -i 'failed\|error:' .agent-tmp/test-final.txt
```

Expected: PASS on iOS Simulator and macOS, no failures.

- [ ] **Step 2: Format check**

```bash
just format-check 2>&1 | tee .agent-tmp/format-check.txt
```

Expected: exits 0 with no diff.

- [ ] **Step 3: Xcode warning check**

Use `mcp__xcode__XcodeListNavigatorIssues` with `severity: "warning"`. Confirm only Preview-macro warnings remain (those are acceptable per CLAUDE.md). All user-code warnings must be zero.

- [ ] **Step 4: Smoke test the running app**

```bash
just run-mac
```

Confirm:
- Sidebar footer is visible at the bottom of the sidebar.
- Footer shows "Connecting…" or "Up to date · Updated …" depending on iCloud state.
- (If on a fresh device or signed-out account) Welcome shows "Checking iCloud" and, once records flow, transitions smoothly to "Found data on iCloud · N records downloaded" with the alternate CTA.

Quit the app after verifying.

- [ ] **Step 5: Cleanup**

```bash
rm -f .agent-tmp/test-final.txt .agent-tmp/format-check.txt
```

No commit — this task is verification only.

---

## After all tasks land

- Open a PR with `gh pr create` and add it to the merge queue per `feedback_prs_to_merge_queue` — never merge manually.
- Reference the design spec in the PR body: `Implements plans/2026-04-25-sync-progress-indicator-design.md`.
- The design's "Out of Scope / Future Work" list (pause/resume, tap-to-detail popover, per-zone progress, early picker) stays untouched. Do not bundle them into this PR.
