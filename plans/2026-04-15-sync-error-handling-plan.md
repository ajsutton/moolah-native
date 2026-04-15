# Sync Error Handling & Robustness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix five pre-existing sync infrastructure issues: zone filtering on sent changes, quota exceeded user notification, save failure recovery, silent fetch errors, and ModelContext consistency.

**Architecture:** All fixes are in the sync layer (`Backends/CloudKit/Sync/`) with one new UI component. Changes are independent and ordered by risk: mechanical logging fixes first, then signature changes, then new coordinator logic, then the UI component.

**Tech Stack:** Swift, SwiftData, CKSyncEngine, SwiftUI, Swift Testing

**Design spec:** `plans/2026-04-15-sync-error-handling-design.md`

---

## File Map

| File | Action | Responsibility |
|------|--------|---------------|
| `Backends/CloudKit/Sync/SyncErrorRecovery.swift` | Modify | New `classify` signature, `quotaExceeded` field |
| `Backends/CloudKit/Sync/ProfileDataSyncHandler.swift` | Modify | `fetchOrLog` helper, `ApplyResult` return, new `handleSentRecordZoneChanges` signature |
| `Backends/CloudKit/Sync/ProfileIndexSyncHandler.swift` | Modify | `fetchOrLog` helper, `ApplyResult` return, `mainContext` fix, new `handleSentRecordZoneChanges` signature |
| `Backends/CloudKit/Sync/SyncCoordinator.swift` | Modify | Zone filtering, `isQuotaExceeded`, re-fetch on save failure |
| `Features/Sync/SyncStatusBanner.swift` | Create | Quota exceeded banner view |
| `App/ContentView.swift` | Modify | Add banner overlay |
| `MoolahTests/Sync/ProfileDataSyncHandlerTests.swift` | Modify | Update for new signatures |
| `MoolahTests/Sync/ProfileIndexSyncHandlerTests.swift` | Modify | Update for new signatures |
| `MoolahTests/Sync/SyncErrorRecoveryTests.swift` | Create | Tests for new classify signature and quota field |

---

### Task 1: Replace try? with fetchOrLog in ProfileDataSyncHandler

Zero-risk mechanical change. Adds logging to silent fetch failures in `buildBatchRecordLookup`.

**Files:**
- Modify: `Backends/CloudKit/Sync/ProfileDataSyncHandler.swift`

- [ ] **Step 1: Add the fetchOrLog helper method**

Add this private method to `ProfileDataSyncHandler`, inside the class body, before `buildBatchRecordLookup`:

```swift
/// Fetches records using the given descriptor, logging errors instead of silently discarding them.
private func fetchOrLog<T: PersistentModel>(
  _ descriptor: FetchDescriptor<T>,
  context: ModelContext
) -> [T] {
  do {
    return try context.fetch(descriptor)
  } catch {
    logger.error("SwiftData fetch failed for \(T.self): \(error)")
    return []
  }
}
```

- [ ] **Step 2: Replace all 7 `try?` sites in `buildBatchRecordLookup`**

Replace each `(try? context.fetch(...)) ?? []` with `fetchOrLog(descriptor, context: context)`. For example, the first one (transactions, around line 142-145):

Before:
```swift
let transactions =
  (try? context.fetch(
    FetchDescriptor<TransactionRecord>(predicate: #Predicate { ids.contains($0.id) })
  )) ?? []
```

After:
```swift
let transactions = fetchOrLog(
  FetchDescriptor<TransactionRecord>(predicate: #Predicate { ids.contains($0.id) }),
  context: context)
```

Apply the same pattern to all 7 fetch calls in `buildBatchRecordLookup`: `TransactionRecord`, `TransactionLegRecord`, `InvestmentValueRecord`, `AccountRecord`, `CategoryRecord`, `EarmarkRecord`, `EarmarkBudgetItemRecord`.

- [ ] **Step 3: Build**

```bash
mkdir -p .agent-tmp && just build-mac 2>&1 | tee .agent-tmp/build-output.txt
grep -i 'error:' .agent-tmp/build-output.txt
```

Expected: BUILD SUCCEEDED

- [ ] **Step 4: Run tests**

```bash
just test 2>&1 | tee .agent-tmp/test-output.txt
grep -i 'failed' .agent-tmp/test-output.txt
```

Expected: All tests pass.

- [ ] **Step 5: Commit**

```bash
git add Backends/CloudKit/Sync/ProfileDataSyncHandler.swift
git commit -m "fix: log SwiftData fetch errors in sync batch record lookup

Replace (try? context.fetch(...)) ?? [] with fetchOrLog helper that
logs errors before returning empty. Previously, store corruption or
schema issues would silently drop records from upload batches."
```

- [ ] **Step 6: Clean up temp files**

```bash
rm -f .agent-tmp/build-output.txt .agent-tmp/test-output.txt
```

---

### Task 2: Replace try? with fetchOrLog in ProfileIndexSyncHandler

Same pattern as Task 1, applied to `ProfileIndexSyncHandler`.

**Files:**
- Modify: `Backends/CloudKit/Sync/ProfileIndexSyncHandler.swift`

- [ ] **Step 1: Add the fetchOrLog helper method**

Add the same helper to `ProfileIndexSyncHandler`:

```swift
/// Fetches records using the given descriptor, logging errors instead of silently discarding them.
private func fetchOrLog<T: PersistentModel>(
  _ descriptor: FetchDescriptor<T>,
  context: ModelContext
) -> [T] {
  do {
    return try context.fetch(descriptor)
  } catch {
    logger.error("SwiftData fetch failed for \(T.self): \(error)")
    return []
  }
}
```

- [ ] **Step 2: Replace try? sites**

Replace `try?` fetch calls in `applyRemoteChanges` (line 45, 62), `recordToSave` (line 101), `queueAllExistingRecords` (line 113), `deleteLocalData` (line 128), `clearAllSystemFields` (line 147), `updateEncodedSystemFields` (line 162), `clearEncodedSystemFields` (line 177), and `handleSentRecordZoneChanges` (lines 200, 222, 231).

For `applyRemoteChanges` (line 45), the pattern changes from:

```swift
if let existing = try? context.fetch(descriptor).first {
```

to:

```swift
if let existing = fetchOrLog(descriptor, context: context).first {
```

Apply the same transformation to all `try? context.fetch(...)` sites in the file.

For `queueAllExistingRecords` (line 113), change from:

```swift
guard let records = try? context.fetch(descriptor), !records.isEmpty else { return [] }
```

to:

```swift
let records = fetchOrLog(descriptor, context: context)
guard !records.isEmpty else { return [] }
```

For `clearAllSystemFields` (line 147), change from:

```swift
if let records = try? context.fetch(FetchDescriptor<ProfileRecord>()) {
```

to:

```swift
let records = fetchOrLog(FetchDescriptor<ProfileRecord>(), context: context)
if !records.isEmpty {
```

Also replace `try? context.save()` on line 152 with:

```swift
do {
  try context.save()
} catch {
  logger.error("Failed to save cleared system fields: \(error)")
}
```

- [ ] **Step 3: Build and test**

```bash
mkdir -p .agent-tmp && just build-mac 2>&1 | tee .agent-tmp/build-output.txt
grep -i 'error:' .agent-tmp/build-output.txt
```

- [ ] **Step 4: Commit**

```bash
git add Backends/CloudKit/Sync/ProfileIndexSyncHandler.swift
git commit -m "fix: log SwiftData fetch errors in profile index sync handler

Replace try? with fetchOrLog helper throughout ProfileIndexSyncHandler.
Also replace bare try? context.save() in clearAllSystemFields with
do/catch + error logging."
```

- [ ] **Step 5: Clean up**

```bash
rm -f .agent-tmp/build-output.txt .agent-tmp/test-output.txt
```

---

### Task 3: Use mainContext for @MainActor methods in ProfileIndexSyncHandler

**Files:**
- Modify: `Backends/CloudKit/Sync/ProfileIndexSyncHandler.swift`

- [ ] **Step 1: Add a mainContext computed property**

Add a convenience computed property at the top of the class (after the stored properties):

```swift
@MainActor
private var mainContext: ModelContext {
  modelContainer.mainContext
}
```

- [ ] **Step 2: Replace `ModelContext(modelContainer)` in @MainActor methods**

In all `@MainActor` methods (NOT `nonisolated` methods), replace `let context = ModelContext(modelContainer)` with `let context = mainContext`.

Methods to update:
- `recordToSave` (line 97)
- `queueAllExistingRecords` (line 111)
- `deleteLocalData` (line 127)
- `clearAllSystemFields` (line 146)
- `updateEncodedSystemFields` (line 158)
- `clearEncodedSystemFields` (line 173)
- `handleSentRecordZoneChanges` (line 194, line 216)

**Do NOT change:**
- `applyRemoteChanges` — this is `nonisolated` and must create its own context

- [ ] **Step 3: Build and test**

```bash
mkdir -p .agent-tmp && just test 2>&1 | tee .agent-tmp/test-output.txt
grep -i 'failed' .agent-tmp/test-output.txt
```

Expected: All tests pass.

- [ ] **Step 4: Commit**

```bash
git add Backends/CloudKit/Sync/ProfileIndexSyncHandler.swift
git commit -m "fix: use mainContext for on-main methods in ProfileIndexSyncHandler

@MainActor methods now use modelContainer.mainContext instead of
creating a fresh ModelContext. This ensures changes are visible to
other @MainActor code without needing a merge/refresh cycle."
```

- [ ] **Step 5: Clean up**

```bash
rm -f .agent-tmp/test-output.txt
```

---

### Task 4: Update SyncErrorRecovery.classify to accept filtered inputs

Changes the `classify` signature to accept per-zone records instead of the full event. Also adds a dedicated `quotaExceeded` field.

**Files:**
- Modify: `Backends/CloudKit/Sync/SyncErrorRecovery.swift`
- Create: `MoolahTests/Sync/SyncErrorRecoveryTests.swift`

- [ ] **Step 1: Write tests for the new classify signature**

Create `MoolahTests/Sync/SyncErrorRecoveryTests.swift`:

```swift
import CloudKit
import Foundation
import Testing

@testable import Moolah

@Suite("SyncErrorRecovery")
struct SyncErrorRecoveryTests {

  private func makeCKError(code: CKError.Code) -> CKError {
    CKError(code)
  }

  private func makeFailedSave(
    recordName: String, zoneID: CKRecordZone.ID, errorCode: CKError.Code
  ) -> CKSyncEngine.Event.SentRecordZoneChanges.FailedRecordSave {
    let record = CKRecord(
      recordType: "TestRecord",
      recordID: CKRecord.ID(recordName: recordName, zoneID: zoneID))
    // FailedRecordSave is a struct from CloudKit — we need to construct one.
    // This may require using the existing test pattern in the codebase.
    // If FailedRecordSave cannot be directly constructed, use the full
    // SentRecordZoneChanges event pattern from existing tests.
    fatalError("See existing test patterns for constructing FailedRecordSave")
  }

  @Test func classifyQuotaExceededSeparatedFromRequeue() {
    // Test that quotaExceeded records appear in the quotaExceeded array,
    // not in the requeue array
    // Implementation depends on how FailedRecordSave can be constructed in tests
  }

  @Test func classifyEmptyInputsReturnsEmpty() {
    let result = SyncErrorRecovery.classify(
      failedSaves: [],
      failedDeletes: [],
      logger: Logger(subsystem: "test", category: "test"))
    #expect(result.quotaExceeded.isEmpty)
    #expect(result.requeue.isEmpty)
    #expect(result.conflicts.isEmpty)
    #expect(result.unknownItems.isEmpty)
    #expect(result.zoneNotFoundSaves.isEmpty)
    #expect(result.zoneNotFoundDeletes.isEmpty)
  }
}
```

**Note:** `CKSyncEngine.Event.SentRecordZoneChanges.FailedRecordSave` may not be directly constructible in tests. Check the existing test patterns in `ProfileDataSyncHandlerTests.swift` and `ProfileIndexSyncHandlerTests.swift` to see how sent changes are tested. If they can't be constructed, test through the handler methods instead and simplify these tests to cover only the `ClassifiedFailures` struct changes and the empty-input case.

- [ ] **Step 2: Update ClassifiedFailures to add quotaExceeded field**

In `SyncErrorRecovery.swift`, add a `quotaExceeded` field to `ClassifiedFailures`:

```swift
struct ClassifiedFailures {
  var zoneNotFoundSaves: [CKRecord.ID] = []
  var zoneNotFoundDeletes: [CKRecord.ID] = []
  var conflicts: [(recordID: CKRecord.ID, serverRecord: CKRecord)] = []
  var unknownItems: [(recordID: CKRecord.ID, recordType: String)] = []
  var quotaExceeded: [CKRecord.ID] = []
  var requeue: [CKRecord.ID] = []
}
```

- [ ] **Step 3: Change the classify method signature**

Replace the existing `classify` method with:

```swift
static func classify(
  failedSaves: [CKSyncEngine.Event.SentRecordZoneChanges.FailedRecordSave],
  failedDeletes: [(CKRecord.ID, CKError)],
  logger: Logger
) -> ClassifiedFailures {
  var result = ClassifiedFailures()

  for failure in failedSaves {
    let recordID = failure.record.recordID

    switch failure.error.code {
    case .zoneNotFound, .userDeletedZone:
      result.zoneNotFoundSaves.append(recordID)

    case .serverRecordChanged:
      if let serverRecord = failure.error.serverRecord {
        result.conflicts.append((recordID: recordID, serverRecord: serverRecord))
      } else {
        logger.warning(
          "serverRecordChanged with no serverRecord for \(recordID.recordName) — re-queuing")
        result.requeue.append(recordID)
      }

    case .unknownItem:
      result.unknownItems.append((recordID: recordID, recordType: failure.record.recordType))

    case .quotaExceeded:
      logger.error(
        "iCloud quota exceeded — sync paused for record \(recordID.recordName)")
      result.quotaExceeded.append(recordID)

    case .limitExceeded:
      result.requeue.append(recordID)

    default:
      logger.error(
        "Save error (code=\(failure.error.code.rawValue)) for \(recordID.recordName): \(failure.error) — re-queuing"
      )
      result.requeue.append(recordID)
    }
  }

  for (recordID, error) in failedDeletes {
    if error.code == .zoneNotFound || error.code == .userDeletedZone {
      result.zoneNotFoundDeletes.append(recordID)
    } else {
      logger.error("Failed to delete record \(recordID.recordName): \(error)")
    }
  }

  return result
}
```

- [ ] **Step 4: Update requeueFailures to include quotaExceeded**

In `requeueFailures`, add `quotaExceeded` records to the pending saves:

```swift
for recordID in failures.quotaExceeded {
  pendingSaves.append(.saveRecord(recordID))
}
```

Add this line after the existing `for recordID in failures.requeue` loop.

- [ ] **Step 5: Build — expect compile errors in callers**

```bash
mkdir -p .agent-tmp && just build-mac 2>&1 | tee .agent-tmp/build-output.txt
grep -i 'error:' .agent-tmp/build-output.txt
```

Expected: Compile errors in `ProfileDataSyncHandler.handleSentRecordZoneChanges` and `ProfileIndexSyncHandler.handleSentRecordZoneChanges` where they call the old `classify` signature. These will be fixed in the next task.

- [ ] **Step 6: Temporarily fix callers to unblock the build**

In both `ProfileDataSyncHandler.swift` (line 561) and `ProfileIndexSyncHandler.swift` (line 212), update the `classify` call from:

```swift
let failures = SyncErrorRecovery.classify(sentChanges, logger: logger)
```

to:

```swift
let failures = SyncErrorRecovery.classify(
  failedSaves: sentChanges.failedRecordSaves,
  failedDeletes: sentChanges.failedRecordDeletes.map { ($0.key, $0.value) },
  logger: logger)
```

**Note:** Check the actual type of `sentChanges.failedRecordDeletes` — it may be `[CKRecord.ID: CKError]` (dictionary) rather than an array of tuples. If so, use `.map { ($0.key, $0.value) }` to convert. If it's already `[(CKRecord.ID, CKError)]`, pass it directly.

- [ ] **Step 7: Build and test**

```bash
just build-mac 2>&1 | tee .agent-tmp/build-output.txt && just test 2>&1 | tee .agent-tmp/test-output.txt
grep -i 'error:\|failed' .agent-tmp/build-output.txt .agent-tmp/test-output.txt
```

Expected: Build succeeds, all tests pass.

- [ ] **Step 8: Commit**

```bash
git add Backends/CloudKit/Sync/SyncErrorRecovery.swift Backends/CloudKit/Sync/ProfileDataSyncHandler.swift Backends/CloudKit/Sync/ProfileIndexSyncHandler.swift MoolahTests/Sync/SyncErrorRecoveryTests.swift
git commit -m "refactor: update SyncErrorRecovery.classify to accept filtered inputs

Change classify to accept pre-filtered failedSaves and failedDeletes
arrays instead of the full SentRecordZoneChanges event. Add dedicated
quotaExceeded field to ClassifiedFailures (previously lumped into
requeue). This prepares for per-zone filtering in the coordinator."
```

- [ ] **Step 9: Clean up**

```bash
rm -f .agent-tmp/build-output.txt .agent-tmp/test-output.txt
```

---

### Task 5: Filter sentChanges by zone in SyncCoordinator

Now that handlers accept filtered inputs, update the coordinator to pass per-zone data.

**Files:**
- Modify: `Backends/CloudKit/Sync/SyncCoordinator.swift`
- Modify: `Backends/CloudKit/Sync/ProfileDataSyncHandler.swift`
- Modify: `Backends/CloudKit/Sync/ProfileIndexSyncHandler.swift`

- [ ] **Step 1: Change handler `handleSentRecordZoneChanges` signatures**

In `ProfileDataSyncHandler.swift`, change the signature from:

```swift
func handleSentRecordZoneChanges(
  _ sentChanges: CKSyncEngine.Event.SentRecordZoneChanges
) -> SyncErrorRecovery.ClassifiedFailures {
```

to:

```swift
func handleSentRecordZoneChanges(
  savedRecords: [CKRecord],
  failedSaves: [CKSyncEngine.Event.SentRecordZoneChanges.FailedRecordSave],
  failedDeletes: [(CKRecord.ID, CKError)]
) -> SyncErrorRecovery.ClassifiedFailures {
```

Update the method body:
- Replace `sentChanges.savedRecords` with `savedRecords`
- The `classify` call already uses the new filtered signature (from Task 4 Step 6) — pass the parameters through:

```swift
let failures = SyncErrorRecovery.classify(
  failedSaves: failedSaves,
  failedDeletes: failedDeletes,
  logger: logger)
```

- [ ] **Step 2: Same for ProfileIndexSyncHandler**

Apply the same signature change to `ProfileIndexSyncHandler.handleSentRecordZoneChanges`:

```swift
func handleSentRecordZoneChanges(
  savedRecords: [CKRecord],
  failedSaves: [CKSyncEngine.Event.SentRecordZoneChanges.FailedRecordSave],
  failedDeletes: [(CKRecord.ID, CKError)]
) -> SyncErrorRecovery.ClassifiedFailures {
```

Update the body to use `savedRecords` instead of `sentChanges.savedRecords`, and pass filtered failures to `classify`.

- [ ] **Step 3: Update the coordinator to pass per-zone records**

In `SyncCoordinator.handleSentRecordZoneChanges`, update the per-zone loop (around line 674-689). Replace:

```swift
case .profileIndex:
  failures = profileIndexHandler.handleSentRecordZoneChanges(sentChanges)

case .profileData(let profileId):
  guard let handler = try? handlerForProfileZone(profileId: profileId, zoneID: zoneID)
  else {
    logger.error("Failed to get handler for sent changes, profile \(profileId)")
    continue
  }
  failures = handler.handleSentRecordZoneChanges(sentChanges)
```

with:

```swift
case .profileIndex:
  failures = profileIndexHandler.handleSentRecordZoneChanges(
    savedRecords: savedByZone[zoneID] ?? [],
    failedSaves: failedSavesByZone[zoneID] ?? [],
    failedDeletes: failedDeletesByZone[zoneID] ?? [])

case .profileData(let profileId):
  guard let handler = try? handlerForProfileZone(profileId: profileId, zoneID: zoneID)
  else {
    logger.error("Failed to get handler for sent changes, profile \(profileId)")
    continue
  }
  failures = handler.handleSentRecordZoneChanges(
    savedRecords: savedByZone[zoneID] ?? [],
    failedSaves: failedSavesByZone[zoneID] ?? [],
    failedDeletes: failedDeletesByZone[zoneID] ?? [])
```

Also remove the stale comment on line 667-668: `// Build a per-zone sentChanges-like structure by passing the full event // to the handler — the handlers already handle filtering internally.`

- [ ] **Step 4: Build and test**

```bash
mkdir -p .agent-tmp && just test 2>&1 | tee .agent-tmp/test-output.txt
grep -i 'failed' .agent-tmp/test-output.txt
```

Expected: All tests pass.

- [ ] **Step 5: Commit**

```bash
git add Backends/CloudKit/Sync/SyncCoordinator.swift Backends/CloudKit/Sync/ProfileDataSyncHandler.swift Backends/CloudKit/Sync/ProfileIndexSyncHandler.swift
git commit -m "fix: filter sentChanges by zone before passing to handlers

Each handler now receives only its own zone's saved records, failed
saves, and failed deletes. Previously the full unfiltered event was
passed, causing duplicate classification and re-queuing across zones."
```

- [ ] **Step 6: Clean up**

```bash
rm -f .agent-tmp/test-output.txt
```

---

### Task 6: Return ApplyResult from applyRemoteChanges

Change both handlers to return a result type that distinguishes success from save failure.

**Files:**
- Modify: `Backends/CloudKit/Sync/ProfileDataSyncHandler.swift`
- Modify: `Backends/CloudKit/Sync/ProfileIndexSyncHandler.swift`
- Modify: `Backends/CloudKit/Sync/SyncCoordinator.swift`

- [ ] **Step 1: Add ApplyResult enum to ProfileDataSyncHandler**

Add at the top of `ProfileDataSyncHandler.swift`, before the class declaration:

```swift
/// Result of applying remote changes from CKSyncEngine.
enum ApplyResult: Sendable {
  /// Changes saved successfully. Contains the set of changed record types.
  case success(changedTypes: Set<String>)
  /// context.save() failed. The coordinator should schedule a re-fetch.
  case saveFailed(Error)
}
```

- [ ] **Step 2: Update ProfileDataSyncHandler.applyRemoteChanges return type**

Change the signature from:

```swift
@discardableResult
nonisolated func applyRemoteChanges(
  saved: [CKRecord],
  deleted: [(CKRecord.ID, String)],
  preExtractedSystemFields: [(String, Data)]? = nil
) -> Set<String> {
```

to:

```swift
nonisolated func applyRemoteChanges(
  saved: [CKRecord],
  deleted: [(CKRecord.ID, String)],
  preExtractedSystemFields: [(String, Data)]? = nil
) -> ApplyResult {
```

Update the save block (around lines 80-92):

```swift
do {
  os_signpost(.begin, log: Signposts.sync, name: "contextSave", signpostID: signpostID)
  let saveStart = ContinuousClock.now
  try context.save()
  saveDuration = ContinuousClock.now - saveStart
  os_signpost(.end, log: Signposts.sync, name: "contextSave", signpostID: signpostID)
  changedTypes = Set(saved.map(\.recordType) + deleted.map(\.1))
} catch {
  os_signpost(.end, log: Signposts.sync, name: "contextSave", signpostID: signpostID)
  logger.error("Failed to save remote changes: \(error)")

  // Log performance even on failure
  let batchMs = (ContinuousClock.now - batchStart).inMilliseconds
  if batchMs > 100 {
    logger.info(
      "applyRemoteChanges took \(batchMs)ms (save FAILED after upsert: \((ContinuousClock.now - batchStart - saveDuration).inMilliseconds)ms)")
  }
  return .saveFailed(error)
}
```

And change the final return (around line 108) from:

```swift
return changedTypes
```

to:

```swift
return .success(changedTypes: changedTypes)
```

- [ ] **Step 3: Update ProfileIndexSyncHandler.applyRemoteChanges return type**

Change from returning `Void` to returning `ApplyResult`:

```swift
nonisolated func applyRemoteChanges(saved: [CKRecord], deleted: [CKRecord.ID]) -> ApplyResult {
```

Update the save block (around lines 67-71):

```swift
do {
  try context.save()
  return .success(changedTypes: Set(saved.map(\.recordType)))
} catch {
  logger.error("Failed to save remote profile changes: \(error)")
  return .saveFailed(error)
}
```

Remove any code after the save that returns void — the return is now inside the do/catch.

- [ ] **Step 4: Update SyncCoordinator to handle ApplyResult**

In `SyncCoordinator.handleFetchedRecordZoneChangesAsync`, update the profile-index handling (around line 569):

Before:
```swift
profileIndexHandler.applyRemoteChanges(saved: saved, deleted: deletedIDs)
```

After:
```swift
let indexResult = profileIndexHandler.applyRemoteChanges(saved: saved, deleted: deletedIDs)
if case .saveFailed(let error) = indexResult {
  logger.error("Profile index save failed, scheduling re-fetch: \(error)")
  await scheduleRefetch()
}
```

Update the profile-data handling (around line 597):

Before:
```swift
let changedTypes = handler.applyRemoteChanges(
  saved: saved, deleted: deleted, preExtractedSystemFields: zonePreExtracted)
```

After:
```swift
let result = handler.applyRemoteChanges(
  saved: saved, deleted: deleted, preExtractedSystemFields: zonePreExtracted)
```

Then update the notification block to handle the result:

```swift
switch result {
case .success(let changedTypes):
  if !changedTypes.isEmpty {
    await MainActor.run {
      if isFetchingChanges {
        accumulateFetchSessionChanges(for: profileId, changedTypes: changedTypes)
      } else {
        notifyObservers(for: profileId, changedTypes: changedTypes)
      }
    }
  }
case .saveFailed(let error):
  logger.error("Profile data save failed for \(profileId), scheduling re-fetch: \(error)")
  await scheduleRefetch()
}
```

- [ ] **Step 5: Add scheduleRefetch to SyncCoordinator**

Add a private method and a coalescing task property:

```swift
/// Task for coalescing re-fetch requests after save failures.
private var refetchTask: Task<Void, Never>?

/// Schedules a re-fetch after a 5-second delay. Multiple calls coalesce into one re-fetch.
private func scheduleRefetch() async {
  await MainActor.run {
    refetchTask?.cancel()
    refetchTask = Task {
      try? await Task.sleep(for: .seconds(5))
      guard !Task.isCancelled else { return }
      logger.info("Re-fetching changes after save failure")
      try? await syncEngine?.fetchChanges()
    }
  }
}
```

- [ ] **Step 6: Build and test**

```bash
mkdir -p .agent-tmp && just test 2>&1 | tee .agent-tmp/test-output.txt
grep -i 'failed' .agent-tmp/test-output.txt
```

Expected: All tests pass. Some test call sites may need updating if they check `applyRemoteChanges` return values.

- [ ] **Step 7: Commit**

```bash
git add Backends/CloudKit/Sync/ProfileDataSyncHandler.swift Backends/CloudKit/Sync/ProfileIndexSyncHandler.swift Backends/CloudKit/Sync/SyncCoordinator.swift
git commit -m "fix: recover from applyRemoteChanges save failures via re-fetch

applyRemoteChanges now returns ApplyResult (.success or .saveFailed)
instead of Set<String>/Void. On save failure, the coordinator skips
observer notification and schedules a re-fetch after 5 seconds.
CKSyncEngine's change token wasn't advanced, so re-fetching
re-delivers the failed records."
```

- [ ] **Step 8: Clean up**

```bash
rm -f .agent-tmp/test-output.txt
```

---

### Task 7: Add isQuotaExceeded to SyncCoordinator

**Files:**
- Modify: `Backends/CloudKit/Sync/SyncCoordinator.swift`

- [ ] **Step 1: Add the observable property**

Add to the existing observable state section of `SyncCoordinator` (near `isRunning` and `isFetchingChanges`):

```swift
/// True when iCloud storage is full and sync uploads are failing.
/// Cleared when a send cycle completes without quota errors.
private(set) var isQuotaExceeded = false
```

- [ ] **Step 2: Set isQuotaExceeded when quota errors are detected**

In `handleSentRecordZoneChanges`, after the per-zone loop (around line 702, before the method closing brace), add:

```swift
// Track quota exceeded state across all zones in this send cycle
let hasQuotaErrors = allZones.contains { zoneID in
  let zoneFailedSaves = failedSavesByZone[zoneID] ?? []
  return zoneFailedSaves.contains { $0.error.code == .quotaExceeded }
}
if hasQuotaErrors {
  isQuotaExceeded = true
} else if !sentChanges.failedRecordSaves.isEmpty || !sentChanges.savedRecords.isEmpty {
  // Only clear if we actually processed records (not an empty event)
  isQuotaExceeded = false
}
```

- [ ] **Step 3: Clear on stop**

In the `stop()` method, add:

```swift
isQuotaExceeded = false
```

- [ ] **Step 4: Build and test**

```bash
mkdir -p .agent-tmp && just test 2>&1 | tee .agent-tmp/test-output.txt
grep -i 'failed' .agent-tmp/test-output.txt
```

- [ ] **Step 5: Commit**

```bash
git add Backends/CloudKit/Sync/SyncCoordinator.swift
git commit -m "feat: track iCloud quota exceeded state on SyncCoordinator

Add isQuotaExceeded observable property. Set when send failures include
quotaExceeded errors, cleared when a send completes without them."
```

- [ ] **Step 6: Clean up**

```bash
rm -f .agent-tmp/test-output.txt
```

---

### Task 8: Add SyncStatusBanner UI

**Files:**
- Create: `Features/Sync/SyncStatusBanner.swift`
- Modify: `App/ContentView.swift`
- Modify: `project.yml` (if needed — check if `Features/Sync/` is auto-included by glob)

- [ ] **Step 1: Check project.yml for file inclusion**

Read `project.yml` to understand how source files are included. If it uses a glob pattern like `Features/**`, the new directory is auto-included. If files are listed explicitly, add the new path.

- [ ] **Step 2: Create SyncStatusBanner.swift**

Create `Features/Sync/SyncStatusBanner.swift`:

```swift
import SwiftUI

/// Non-modal banner displayed when iCloud storage is full.
/// Appears at the top of the content area and persists until
/// the condition clears or the user dismisses it.
struct SyncStatusBanner: View {
  @Environment(SyncCoordinator.self) private var syncCoordinator
  @State private var dismissed = false

  var body: some View {
    if syncCoordinator.isQuotaExceeded && !dismissed {
      HStack {
        Image(systemName: "exclamationmark.icloud.fill")
          .foregroundStyle(.orange)
        Text("iCloud storage is full. Some changes can't sync until you free up space.")
          .font(.callout)
        Spacer()
        Button {
          dismissed = true
        } label: {
          Image(systemName: "xmark")
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Dismiss sync warning")
      }
      .padding(.horizontal)
      .padding(.vertical, 8)
      .background(.yellow.opacity(0.15))
      .onChange(of: syncCoordinator.isQuotaExceeded) { old, new in
        // Reset dismissal when the condition clears and reappears
        if !old && new {
          dismissed = false
        }
      }
    }
  }
}
```

- [ ] **Step 3: Add SyncStatusBanner to ContentView**

In `App/ContentView.swift`, add the banner at the top of the body. Wrap the existing `NavigationSplitView` in a `VStack`:

```swift
var body: some View {
  VStack(spacing: 0) {
    SyncStatusBanner()
    NavigationSplitView {
      // ... existing sidebar content
```

And close the `VStack` after the `NavigationSplitView` closing brace.

- [ ] **Step 4: Build and test**

```bash
mkdir -p .agent-tmp && just build-mac 2>&1 | tee .agent-tmp/build-output.txt
grep -i 'error:' .agent-tmp/build-output.txt
```

- [ ] **Step 5: Run tests**

```bash
just test 2>&1 | tee .agent-tmp/test-output.txt
grep -i 'failed' .agent-tmp/test-output.txt
```

- [ ] **Step 6: Commit**

```bash
git add Features/Sync/SyncStatusBanner.swift App/ContentView.swift
git commit -m "feat: show banner when iCloud storage is full

Add SyncStatusBanner that observes SyncCoordinator.isQuotaExceeded.
Shows a non-modal warning bar at the top of the main content area.
Dismissible, reappears when condition recurs."
```

- [ ] **Step 7: Clean up**

```bash
rm -f .agent-tmp/build-output.txt .agent-tmp/test-output.txt
```
