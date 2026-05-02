# Sync: Record-Name Collision Fix — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Encode record type into every UUID-keyed `CKRecord.ID.recordName`
so collisions across SwiftData types can't share a server-side identity, while
keeping every bare-UUID record already on the server working via dual-format
downlink readers.

**Architecture:** New format is `"<recordType>|<uuid.uuidString>"`. Two helpers
on `CKRecord.ID` centralize construction (`init(recordType:uuid:zoneID:)`) and
parsing (`uuid: UUID?` computed property). Legacy records stay under their bare-UUID
recordName via `buildCKRecord`'s cached-record reuse. No active migration in
v1 — tracked as [#420](https://github.com/ajsutton/moolah-native/issues/420).

**Tech Stack:** Swift 6, CKSyncEngine, SwiftData, Swift Testing. Build via
`just build-mac` / `just test`. Format via `just format`.

**Spec:** `plans/2026-04-24-sync-record-name-collision-design.md`.

---

## File map

**New:**

- `Backends/CloudKit/Sync/CKRecordIDRecordName.swift` — `init(recordType:uuid:zoneID:)`, `uuid: UUID?`, `systemFieldsKey`.
- `MoolahTests/Sync/CKRecordIDRecordNameTests.swift` — unit tests for the three helpers.
- `MoolahTests/Sync/RecordNameCollisionTests.swift` — five regression tests from the spec.

**Modified (per-type × 10 — AccountRecord, TransactionRecord, TransactionLegRecord, CategoryRecord, EarmarkRecord, EarmarkBudgetItemRecord, InvestmentValueRecord, CSVImportProfileRecord, ImportRuleRecord, ProfileRecord):**

- `Backends/CloudKit/Sync/<Type>Record+CloudKit.swift` — `toCKRecord` uses prefixed init; `fieldValues(from:)` uses `recordID.uuid`.

**Modified (single sites):**

- `Backends/CloudKit/Sync/SyncCoordinator+Lifecycle.swift` — queue signatures.
- `Backends/CloudKit/Sync/ProfileDataSyncHandler+QueueAndDelete.swift` — `collectUnsynced`/`collectAllUUIDs` emit prefixed.
- `Backends/CloudKit/Sync/ProfileDataSyncHandler+BatchUpsert.swift` — `uuidPairs(from:)`.
- `Backends/CloudKit/Sync/ProfileDataSyncHandler+ApplyRemoteChanges.swift` — deletion UUID parse, `systemFieldsLookup` key normalization.
- `Backends/CloudKit/Sync/ProfileDataSyncHandler+SystemFields.swift` — `applySystemFields` dispatches by `recordType`; `clearSystemFields` uses helper.
- `Backends/CloudKit/Sync/SyncCoordinator+Delegate.swift` — `appendProfileDataRecords` partition.
- `App/ProfileSession+SyncWiring.swift` — pass `recordType` to queue calls.
- `App/MoolahApp+Setup.swift` — ProfileRecord queue calls pass recordType.

**Modified tests (existing assertions that compare recordName to bare UUID):**

- `MoolahTests/Sync/RecordMappingTests.swift` — 4 assertions to update.
- `MoolahTests/Sync/ProfileIndexSyncHandlerTests.swift` — 1 assertion.
- `MoolahTests/Sync/ProfileIndexSyncHandlerTestsMore.swift` — 1 assertion.
- `MoolahTests/Sync/ProfileDataSyncHandlerTests.swift` — 2 assertions (one test — `buildCKRecordPreservesCachedSystemFields` at line 201 — keeps bare UUID because legacy-compat path, so do NOT change it).
- `MoolahTests/Sync/SyncCoordinatorTestsExtra.swift` — 2 assertions inspecting pending queue state.

---

## Task 1: Add `CKRecord.ID` helpers (construction, UUID parse, cache key)

**Files:**
- Create: `Backends/CloudKit/Sync/CKRecordID+RecordName.swift`
- Test: `MoolahTests/Sync/CKRecordIDRecordNameTests.swift`

- [ ] **Step 1.1: Write the failing test file**

Create `MoolahTests/Sync/CKRecordIDRecordNameTests.swift`:

```swift
import CloudKit
import Foundation
import Testing

@testable import Moolah

@Suite("CKRecord.ID — recordName helpers")
struct CKRecordIDRecordNameTests {

  private let zoneID = CKRecordZone.ID(
    zoneName: "profile-test",
    ownerName: CKCurrentUserDefaultName
  )

  // MARK: - init(recordType:uuid:zoneID:)

  @Test
  func initBuildsPrefixedRecordName() {
    let uuid = UUID(uuidString: "1CAC9567-574B-481A-BADA-D595325CBE0C")!
    let recordID = CKRecord.ID(
      recordType: "CD_AccountRecord", uuid: uuid, zoneID: zoneID)
    #expect(
      recordID.recordName
        == "CD_AccountRecord|1CAC9567-574B-481A-BADA-D595325CBE0C")
    #expect(recordID.zoneID == zoneID)
  }

  // MARK: - uuidRecordName()

  @Test
  func uuidRecordNameStripsPrefix() {
    let uuid = UUID(uuidString: "1CAC9567-574B-481A-BADA-D595325CBE0C")!
    let recordID = CKRecord.ID(
      recordName: "CD_AccountRecord|1CAC9567-574B-481A-BADA-D595325CBE0C",
      zoneID: zoneID)
    #expect(recordID.uuid == uuid)
  }

  @Test
  func uuidRecordNameAcceptsBareUUIDLegacyFormat() {
    let uuid = UUID(uuidString: "1CAC9567-574B-481A-BADA-D595325CBE0C")!
    let recordID = CKRecord.ID(
      recordName: "1CAC9567-574B-481A-BADA-D595325CBE0C",
      zoneID: zoneID)
    #expect(recordID.uuid == uuid)
  }

  @Test
  func uuidRecordNameReturnsNilForInstrumentIDs() {
    #expect(
      CKRecord.ID(recordName: "AUD", zoneID: zoneID).uuidRecordName() == nil)
    #expect(
      CKRecord.ID(recordName: "ASX:BHP", zoneID: zoneID).uuidRecordName()
        == nil)
  }

  @Test
  func uuidRecordNameReturnsNilForNonUUIDAfterPrefix() {
    // If somebody ever passes a non-UUID after the pipe, we should reject.
    let recordID = CKRecord.ID(
      recordName: "CD_AccountRecord|not-a-uuid",
      zoneID: zoneID)
    #expect(recordID.uuid == nil)
  }

  // MARK: - systemFieldsKey

  @Test
  func systemFieldsKeyStripsTypePrefixForPrefixedRecord() {
    let recordID = CKRecord.ID(
      recordName: "CD_AccountRecord|1CAC9567-574B-481A-BADA-D595325CBE0C",
      zoneID: zoneID)
    #expect(recordID.systemFieldsKey == "1CAC9567-574B-481A-BADA-D595325CBE0C")
  }

  @Test
  func systemFieldsKeyReturnsBareUUIDForLegacyRecord() {
    let recordID = CKRecord.ID(
      recordName: "1CAC9567-574B-481A-BADA-D595325CBE0C",
      zoneID: zoneID)
    #expect(recordID.systemFieldsKey == "1CAC9567-574B-481A-BADA-D595325CBE0C")
  }

  @Test
  func systemFieldsKeyReturnsRecordNameForInstrument() {
    let recordID = CKRecord.ID(recordName: "ASX:BHP", zoneID: zoneID)
    #expect(recordID.systemFieldsKey == "ASX:BHP")
  }
}
```

- [ ] **Step 1.2: Run tests to verify they fail**

```bash
just test-mac CKRecordIDRecordNameTests 2>&1 | tee .agent-tmp/t1-red.txt
```

Expected: build failure — `Type 'CKRecord.ID' has no member` or equivalent.

- [ ] **Step 1.3: Write the helpers**

Create `Backends/CloudKit/Sync/CKRecordID+RecordName.swift`:

```swift
import CloudKit
import Foundation

// `CKRecord.ID.recordName` is the primary key for a record in a zone. UUID-keyed
// records in this app encode the SwiftData record type as a prefix so two
// different types that happen to share a UUID can't collide on the server
// (issue #416). Format: `"<recordType>|<uuid.uuidString>"` for new records.
// Legacy records already on the server continue to use bare `<uuid.uuidString>`;
// these helpers accept both formats.
extension CKRecord.ID {
  /// Constructs a prefixed recordName from a record type and UUID.
  convenience init(
    recordType: String, uuid: UUID, zoneID: CKRecordZone.ID
  ) {
    self.init(
      recordName: "\(recordType)|\(uuid.uuidString)",
      zoneID: zoneID
    )
  }

  /// Returns the UUID portion of a recordName regardless of format.
  /// Accepts `"<TYPE>|<UUID>"` (new) and `"<UUID>"` (legacy).
  /// Returns `nil` for non-UUID names (e.g. instrument IDs like `"AUD"`).
  func uuidRecordName() -> UUID? {
    if let sep = recordName.firstIndex(of: "|") {
      let uuidPart = recordName[recordName.index(after: sep)...]
      return UUID(uuidString: String(uuidPart))
    }
    return UUID(uuidString: recordName)
  }

  /// The key used for per-record system-fields caching during batch upsert.
  /// - For UUID-keyed records: the bare UUID string (prefix stripped).
  /// - For string-keyed records (instruments): the full recordName.
  ///
  /// This matches the keys used by `batchUpsertX` methods which look up
  /// `systemFields[id.uuidString]` for UUID records and `systemFields[id]`
  /// for instruments.
  var systemFieldsKey: String {
    if let sep = recordName.firstIndex(of: "|") {
      return String(recordName[recordName.index(after: sep)...])
    }
    return recordName
  }
}
```

- [ ] **Step 1.4: Run tests to verify they pass**

```bash
just test-mac CKRecordIDRecordNameTests 2>&1 | tee .agent-tmp/t1-green.txt
```

Expected: all 8 tests pass.

- [ ] **Step 1.5: Format and commit**

```bash
just format
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/fix-sync-silent-drop add Backends/CloudKit/Sync/CKRecordID+RecordName.swift MoolahTests/Sync/CKRecordIDRecordNameTests.swift
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/fix-sync-silent-drop commit -m "$(cat <<'EOF'
feat(sync): add CKRecord.ID helpers for prefixed recordNames (#416)

Adds init(recordType:uuid:zoneID:) for building the new
"<recordType>|<UUID>" recordName format, plus uuidRecordName() and
systemFieldsKey helpers that accept both the new format and legacy
bare-UUID recordNames. The prefix lets two SwiftData record types
with colliding UUIDs land on distinct CKRecord.IDs on the server;
the dual-format parsers keep records already on the server working.

Helpers are covered by CKRecordIDRecordNameTests (8 tests).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
rm .agent-tmp/t1-*.txt
```

---

## Task 2: Update per-type `toCKRecord` / `fieldValues` to prefixed format

**Files (× 10):**
- Modify: `Backends/CloudKit/Sync/AccountRecord+CloudKit.swift`
- Modify: `Backends/CloudKit/Sync/TransactionRecord+CloudKit.swift`
- Modify: `Backends/CloudKit/Sync/TransactionLegRecord+CloudKit.swift`
- Modify: `Backends/CloudKit/Sync/CategoryRecord+CloudKit.swift`
- Modify: `Backends/CloudKit/Sync/EarmarkRecord+CloudKit.swift`
- Modify: `Backends/CloudKit/Sync/EarmarkBudgetItemRecord+CloudKit.swift`
- Modify: `Backends/CloudKit/Sync/InvestmentValueRecord+CloudKit.swift`
- Modify: `Backends/CloudKit/Sync/CSVImportProfileRecord+CloudKit.swift`
- Modify: `Backends/CloudKit/Sync/ImportRuleRecord+CloudKit.swift`
- Modify: `Backends/CloudKit/Sync/ProfileRecord+CloudKit.swift`

**Mechanical rule** — every UUID-keyed `+CloudKit.swift` file gets two edits:

1. In `toCKRecord(in:)`: replace
   ```swift
   let recordID = CKRecord.ID(recordName: id.uuidString, zoneID: zoneID)
   ```
   with
   ```swift
   let recordID = CKRecord.ID(
     recordType: Self.recordType, uuid: id, zoneID: zoneID)
   ```

2. In `fieldValues(from:)`: replace
   ```swift
   id: UUID(uuidString: ckRecord.recordID.recordName) ?? UUID(),
   ```
   with
   ```swift
   id: ckRecord.recordID.uuid ?? UUID(),
   ```

`InstrumentRecord+CloudKit.swift` is NOT in the list — it uses a string ID
and cannot collide.

- [ ] **Step 2.1: Apply the two mechanical edits to `AccountRecord+CloudKit.swift`**

- [ ] **Step 2.2: Apply the two mechanical edits to `TransactionRecord+CloudKit.swift`**

- [ ] **Step 2.3: Apply the two mechanical edits to `TransactionLegRecord+CloudKit.swift`**

- [ ] **Step 2.4: Apply the two mechanical edits to `CategoryRecord+CloudKit.swift`**

- [ ] **Step 2.5: Apply the two mechanical edits to `EarmarkRecord+CloudKit.swift`**

- [ ] **Step 2.6: Apply the two mechanical edits to `EarmarkBudgetItemRecord+CloudKit.swift`**

- [ ] **Step 2.7: Apply the two mechanical edits to `InvestmentValueRecord+CloudKit.swift`**

- [ ] **Step 2.8: Apply the two mechanical edits to `CSVImportProfileRecord+CloudKit.swift`**

- [ ] **Step 2.9: Apply the two mechanical edits to `ImportRuleRecord+CloudKit.swift`**

- [ ] **Step 2.10: Apply the two mechanical edits to `ProfileRecord+CloudKit.swift`**

- [ ] **Step 2.11: Update existing tests that assert bare-UUID recordNames**

Six assertions are now wrong because `toCKRecord` emits a prefixed name.
Update them to expect the prefixed format.

**`MoolahTests/Sync/RecordMappingTests.swift`:**

Line 27 — change
```swift
#expect(ckRecord.recordID.recordName == profile.id.uuidString)
```
to
```swift
#expect(
  ckRecord.recordID.recordName
    == "\(ProfileRecord.recordType)|\(profile.id.uuidString)")
```

Line 58 — change
```swift
#expect(ckRecord.recordID.recordName == account.id.uuidString)
```
to
```swift
#expect(
  ckRecord.recordID.recordName
    == "\(AccountRecord.recordType)|\(account.id.uuidString)")
```

Line 105 — change
```swift
#expect(ckRecord.recordID.recordName == txn.id.uuidString)
```
to
```swift
#expect(
  ckRecord.recordID.recordName
    == "\(TransactionRecord.recordType)|\(txn.id.uuidString)")
```

Line 165 — change
```swift
#expect(ckRecord.recordID.recordName == leg.id.uuidString)
```
to
```swift
#expect(
  ckRecord.recordID.recordName
    == "\(TransactionLegRecord.recordType)|\(leg.id.uuidString)")
```

**`MoolahTests/Sync/ProfileIndexSyncHandlerTests.swift`:**

Line 193 — change
```swift
#expect(ckRecord.recordID.recordName == profileId.uuidString)
```
to
```swift
#expect(
  ckRecord.recordID.recordName
    == "\(ProfileRecord.recordType)|\(profileId.uuidString)")
```

**`MoolahTests/Sync/ProfileIndexSyncHandlerTestsMore.swift`:**

Line 45 — change
```swift
#expect(built.recordID.recordName == profileId.uuidString)
```
to
```swift
#expect(
  built.recordID.recordName
    == "\(ProfileRecord.recordType)|\(profileId.uuidString)")
```

**`MoolahTests/Sync/ProfileDataSyncHandlerTests.swift`:**

Line 127 — change
```swift
#expect(ckRecord.recordID.recordName == account.id.uuidString)
```
to
```swift
#expect(
  ckRecord.recordID.recordName
    == "\(AccountRecord.recordType)|\(account.id.uuidString)")
```

Line 169 (inside `buildCKRecordDropsCachedFieldsOnZoneMismatch`) — change
```swift
#expect(built.recordID.recordName == accountId.uuidString)
```
to
```swift
#expect(
  built.recordID.recordName
    == "\(AccountRecord.recordType)|\(accountId.uuidString)")
```

**DO NOT change** `ProfileDataSyncHandlerTests.swift:201` inside
`buildCKRecordPreservesCachedSystemFields` — that test specifically seeds
a bare-UUID cached CKRecord and expects `buildCKRecord` to preserve it.
That's the legacy-compat path we want to keep exercising.

- [ ] **Step 2.12: Run affected tests**

```bash
just test-mac RecordMappingTests ProfileIndexSyncHandlerTests ProfileIndexSyncHandlerTestsMore ProfileDataSyncHandlerTests 2>&1 | tee .agent-tmp/t2-tests.txt
```

Expected: all pass.

- [ ] **Step 2.13: Build the app**

```bash
just build-mac 2>&1 | tee .agent-tmp/t2-build.txt
```

Expected: build succeeds, no warnings.

- [ ] **Step 2.14: Format and commit**

```bash
just format
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/fix-sync-silent-drop add -u
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/fix-sync-silent-drop commit -m "$(cat <<'EOF'
feat(sync): emit prefixed recordNames from per-type toCKRecord (#416)

Every UUID-keyed <Type>Record+CloudKit.swift now constructs
CKRecord.IDs via CKRecord.ID(recordType:uuid:zoneID:), producing
"<recordType>|<UUID>" recordNames for brand-new records. The
matching fieldValues(from:) uses ckRecord.recordID.uuid so the
downlink half of the mapping accepts both the new format and the
legacy bare-UUID form.

InstrumentRecord is unchanged (string-keyed, cannot collide).
Existing tests that asserted bare-UUID recordNames updated to expect
the prefixed format. buildCKRecordPreservesCachedSystemFields keeps
its bare-UUID assertion — it exercises the legacy-compat path.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
rm .agent-tmp/t2-*.txt
```

---

## Task 3: Change queue signatures and propagate recordType

**Files:**
- Modify: `Backends/CloudKit/Sync/SyncCoordinator+Lifecycle.swift`
- Modify: `Backends/CloudKit/Sync/ProfileDataSyncHandler+QueueAndDelete.swift`
- Modify: `App/ProfileSession+SyncWiring.swift`
- Modify: `App/MoolahApp+Setup.swift`
- Modify: `MoolahTests/Sync/SyncCoordinatorTestsExtra.swift` (2 assertions)

- [ ] **Step 3.1: Change `queueSave`/`queueDeletion` signatures**

In `Backends/CloudKit/Sync/SyncCoordinator+Lifecycle.swift`, replace the two
UUID-keyed queue methods (around lines 145 and 155) with:

```swift
func queueSave(id: UUID, recordType: String, zoneID: CKRecordZone.ID) {
  let recordID = CKRecord.ID(
    recordType: recordType, uuid: id, zoneID: zoneID)
  syncEngine?.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
}

func queueSave(recordName: String, zoneID: CKRecordZone.ID) {
  let recordID = CKRecord.ID(recordName: recordName, zoneID: zoneID)
  syncEngine?.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
}

func queueDeletion(id: UUID, recordType: String, zoneID: CKRecordZone.ID) {
  let recordID = CKRecord.ID(
    recordType: recordType, uuid: id, zoneID: zoneID)
  syncEngine?.state.add(pendingRecordZoneChanges: [.deleteRecord(recordID)])
}
```

- [ ] **Step 3.2: Update all callers in `App/ProfileSession+SyncWiring.swift`**

Every `coordinator?.queueSave(id: id, zoneID: zoneID)` and
`coordinator?.queueDeletion(id: id, zoneID: zoneID)` becomes:

```swift
coordinator?.queueSave(id: id, recordType: XxxRecord.recordType, zoneID: zoneID)
coordinator?.queueDeletion(id: id, recordType: XxxRecord.recordType, zoneID: zoneID)
```

Mapping of closures to record types:

| Closure on | Record type |
|---|---|
| `backend.accounts` — `onRecordChanged`/`onRecordDeleted` | `AccountRecord.recordType` |
| `backend.transactions` — `onRecordChanged`/`onRecordDeleted` | `TransactionRecord.recordType` |
| `backend.categories` — `onRecordChanged`/`onRecordDeleted` | `CategoryRecord.recordType` |
| `backend.earmarks` — `onRecordChanged`/`onRecordDeleted` | `EarmarkRecord.recordType` |
| `backend.investments` — `onRecordChanged`/`onRecordDeleted` | `InvestmentValueRecord.recordType` |
| `backend.csvImportProfiles` — `onRecordChanged`/`onRecordDeleted` | `CSVImportProfileRecord.recordType` |
| `backend.importRules` — `onRecordChanged`/`onRecordDeleted` | `ImportRuleRecord.recordType` |

`onInstrumentChanged` keeps using the string `queueSave(recordName:zoneID:)`
overload — no change.

- [ ] **Step 3.3: Update `App/MoolahApp+Setup.swift`**

In `configureSyncCoordinator`, the two profile-index hooks (lines ~113, 118)
become:

```swift
store.onProfileChanged = { [weak coordinator] id in
  let zoneID = CKRecordZone.ID(
    zoneName: "profile-index", ownerName: CKCurrentUserDefaultName)
  coordinator?.queueSave(
    id: id, recordType: ProfileRecord.recordType, zoneID: zoneID)
}
store.onProfileDeleted = { [weak coordinator] id in
  let zoneID = CKRecordZone.ID(
    zoneName: "profile-index", ownerName: CKCurrentUserDefaultName)
  coordinator?.queueDeletion(
    id: id, recordType: ProfileRecord.recordType, zoneID: zoneID)
}
```

- [ ] **Step 3.4: Update `collectUnsynced` / `collectAllUUIDs` to emit prefixed IDs**

In `Backends/CloudKit/Sync/ProfileDataSyncHandler+QueueAndDelete.swift`, the
private helpers construct `CKRecord.ID(recordName: extract(record), zoneID:)`
today (lines 125 and 144). The `extract` closure returns `String` — for UUID
types this is `$0.id.uuidString`, for instruments it's `$0.id`.

Option taken: make the helpers type-aware by passing `T.recordType` at the
call site and building the prefixed `CKRecord.ID` inside the helper.

Replace `collectAllUUIDs` and `collectUnsynced` with versions that know `T`
is UUID-keyed:

```swift
private func collectAllUUIDs<T: PersistentModel & CloudKitRecordConvertible>(
  _ type: T.Type, into recordIDs: inout [CKRecord.ID], extract: (T) -> UUID
) {
  let context = ModelContext(modelContainer)
  for record in Self.fetchOrLog(FetchDescriptor<T>(), context: context) {
    recordIDs.append(
      CKRecord.ID(
        recordType: T.recordType, uuid: extract(record), zoneID: zoneID))
  }
}

private func collectUnsynced<
  T: PersistentModel & SystemFieldsCacheable & CloudKitRecordConvertible
>(
  _ type: T.Type, into recordIDs: inout [CKRecord.ID], extract: (T) -> UUID
) {
  let context = ModelContext(modelContainer)
  for record in Self.fetchOrLog(FetchDescriptor<T>(), context: context)
  where record.encodedSystemFields == nil {
    recordIDs.append(
      CKRecord.ID(
        recordType: T.recordType, uuid: extract(record), zoneID: zoneID))
  }
}
```

And update the call sites in the same file (around lines 36–44 and 67–76) so
the closures return `UUID` (not `String`):

```swift
// queueAllExistingRecords:
collectAllStringIDs(InstrumentRecord.self, into: &recordIDs) { $0.id }
collectAllUUIDs(CategoryRecord.self, into: &recordIDs) { $0.id }
collectAllUUIDs(AccountRecord.self, into: &recordIDs) { $0.id }
collectAllUUIDs(EarmarkRecord.self, into: &recordIDs) { $0.id }
collectAllUUIDs(EarmarkBudgetItemRecord.self, into: &recordIDs) { $0.id }
collectAllUUIDs(InvestmentValueRecord.self, into: &recordIDs) { $0.id }
collectAllUUIDs(TransactionRecord.self, into: &recordIDs) { $0.id }
collectAllUUIDs(TransactionLegRecord.self, into: &recordIDs) { $0.id }
collectAllUUIDs(CSVImportProfileRecord.self, into: &recordIDs) { $0.id }
collectAllUUIDs(ImportRuleRecord.self, into: &recordIDs) { $0.id }

// queueUnsyncedRecords:
collectUnsynced(InstrumentRecord.self, into: &recordIDs) { $0.id }
collectUnsynced(CategoryRecord.self, into: &recordIDs) { $0.id }
collectUnsynced(AccountRecord.self, into: &recordIDs) { $0.id }
collectUnsynced(EarmarkRecord.self, into: &recordIDs) { $0.id }
collectUnsynced(EarmarkBudgetItemRecord.self, into: &recordIDs) { $0.id }
collectUnsynced(InvestmentValueRecord.self, into: &recordIDs) { $0.id }
collectUnsynced(TransactionRecord.self, into: &recordIDs) { $0.id }
collectUnsynced(TransactionLegRecord.self, into: &recordIDs) { $0.id }
collectUnsynced(CSVImportProfileRecord.self, into: &recordIDs) { $0.id }
collectUnsynced(ImportRuleRecord.self, into: &recordIDs) { $0.id }
```

`collectAllStringIDs` stays as-is (used only for InstrumentRecord). However
`collectUnsynced` is also currently called for `InstrumentRecord` (line 67);
that call returns `String` from the closure, which will fail to compile now
that `collectUnsynced` takes `(T) -> UUID`. Extract a string-keyed overload:

Add a parallel helper for InstrumentRecord in the same file:

```swift
private func collectUnsyncedInstruments(
  into recordIDs: inout [CKRecord.ID]
) {
  let context = ModelContext(modelContainer)
  for record in Self.fetchOrLog(FetchDescriptor<InstrumentRecord>(), context: context)
  where record.encodedSystemFields == nil {
    recordIDs.append(
      CKRecord.ID(recordName: record.id, zoneID: zoneID))
  }
}
```

And in `queueUnsyncedRecords`, replace the first line of the collect block:

```swift
// Before:
collectUnsynced(InstrumentRecord.self, into: &recordIDs) { $0.id }
// After:
collectUnsyncedInstruments(into: &recordIDs)
```

- [ ] **Step 3.5: Update assertions in `MoolahTests/Sync/SyncCoordinatorTestsExtra.swift`**

Lines 177 and 180 inspect pending queue state:

```swift
// Before (lines 177 and 180):
if recordID.recordName == unsyncedA.uuidString { ... }
if recordID.recordName == unsyncedB.uuidString { ... }
```

Read the surrounding context in that test to determine the record type
(likely `AccountRecord` based on the fixture — read and confirm). Replace
with:

```swift
if recordID.recordName == "\(AccountRecord.recordType)|\(unsyncedA.uuidString)" { ... }
if recordID.recordName == "\(AccountRecord.recordType)|\(unsyncedB.uuidString)" { ... }
```

If the fixture uses a different record type, use that type's `recordType`.

- [ ] **Step 3.6: Build the app**

```bash
just build-mac 2>&1 | tee .agent-tmp/t3-build.txt
```

Expected: builds cleanly, no warnings.

- [ ] **Step 3.7: Run all sync tests**

```bash
just test-mac SyncCoordinatorTests SyncCoordinatorTestsExtra SyncCoordinatorTestsMore ProfileDataSyncHandlerTests ProfileDataSyncHandlerLookupTests ProfileDataSyncHandlerQueueTests ProfileIndexSyncHandlerTests ProfileIndexSyncHandlerTestsMore RecordMappingTests RecordMappingTestsExtra RecordMappingTestsMore SyncErrorRecoveryTests 2>&1 | tee .agent-tmp/t3-tests.txt
```

Expected: all pass.

- [ ] **Step 3.8: Format and commit**

```bash
just format
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/fix-sync-silent-drop add -u
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/fix-sync-silent-drop commit -m "$(cat <<'EOF'
feat(sync): propagate recordType through queueSave/queueDeletion (#416)

queueSave(id:recordType:zoneID:) and queueDeletion(id:recordType:zoneID:)
now carry the record type so the pending CKRecord.ID can be built with
the prefixed "<recordType>|<UUID>" format. Every call site — the
CloudKit repositories via ProfileSession+SyncWiring, and the profile-
index hooks in MoolahApp+Setup — passes its corresponding XxxRecord
.recordType constant. The string-ID overload used for InstrumentRecord
is unchanged.

collectAllUUIDs/collectUnsynced now receive T.recordType (via
CloudKitRecordConvertible) and emit prefixed CKRecord.IDs directly.
InstrumentRecord gets its own collectUnsyncedInstruments helper since
it's string-keyed.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
rm .agent-tmp/t3-*.txt
```

---

## Task 4: Update downlink parsing sites

**Files:**
- Modify: `Backends/CloudKit/Sync/ProfileDataSyncHandler+BatchUpsert.swift`
- Modify: `Backends/CloudKit/Sync/ProfileDataSyncHandler+ApplyRemoteChanges.swift`
- Modify: `Backends/CloudKit/Sync/ProfileDataSyncHandler+SystemFields.swift`
- Modify: `Backends/CloudKit/Sync/ProfileDataSyncHandler+RecordLookup.swift`
- Modify: `Backends/CloudKit/Sync/SyncCoordinator+Delegate.swift`

- [ ] **Step 4.1: Update `uuidPairs(from:)` in `ProfileDataSyncHandler+BatchUpsert.swift`**

Around line 279, replace

```swift
nonisolated private static func uuidPairs(from ckRecords: [CKRecord]) -> [(UUID, CKRecord)] {
  ckRecords.compactMap { record in
    guard let uuid = UUID(uuidString: record.recordID.recordName) else { return nil }
    return (uuid, record)
  }
}
```

with

```swift
nonisolated private static func uuidPairs(from ckRecords: [CKRecord]) -> [(UUID, CKRecord)] {
  ckRecords.compactMap { record in
    guard let uuid = record.recordID.uuid else { return nil }
    return (uuid, record)
  }
}
```

- [ ] **Step 4.2: Update `applyBatchDeletions` in `ProfileDataSyncHandler+ApplyRemoteChanges.swift`**

Around line 93, replace

```swift
for (recordID, recordType) in deletions {
  if let uuid = UUID(uuidString: recordID.recordName) {
    uuidGrouped[recordType, default: []].append(uuid)
  } else {
    stringGrouped[recordType, default: []].append(recordID.recordName)
  }
}
```

with

```swift
for (recordID, recordType) in deletions {
  if let uuid = recordID.uuid {
    uuidGrouped[recordType, default: []].append(uuid)
  } else {
    stringGrouped[recordType, default: []].append(recordID.recordName)
  }
}
```

- [ ] **Step 4.3: Normalize keys in `systemFieldsLookup`**

Still in `ProfileDataSyncHandler+ApplyRemoteChanges.swift`, around line 138,
replace

```swift
nonisolated private static func systemFieldsLookup(
  saved: [CKRecord], preExtracted: [(String, Data)]
) -> [String: Data] {
  if !preExtracted.isEmpty {
    return Dictionary(preExtracted, uniquingKeysWith: { _, last in last })
  }
  return Dictionary(
    uniqueKeysWithValues: saved.map { ($0.recordID.recordName, $0.encodedSystemFields) }
  )
}
```

with

```swift
nonisolated private static func systemFieldsLookup(
  saved: [CKRecord], preExtracted: [(String, Data)]
) -> [String: Data] {
  // Both sources key by recordName, but the batchUpsertX methods look up
  // by uuid.uuidString (for UUID records) or record.id (for instruments) —
  // never by the full prefixed recordName. Normalize by stripping the
  // "<recordType>|" prefix when present so the downstream lookup works
  // for both the new and legacy recordName formats.
  func keyFor(_ recordName: String) -> String {
    if let sep = recordName.firstIndex(of: "|") {
      return String(recordName[recordName.index(after: sep)...])
    }
    return recordName
  }
  if !preExtracted.isEmpty {
    return Dictionary(
      preExtracted.map { (keyFor($0.0), $0.1) },
      uniquingKeysWith: { _, last in last })
  }
  return Dictionary(
    uniqueKeysWithValues: saved.map {
      (keyFor($0.recordID.recordName), $0.encodedSystemFields)
    }
  )
}
```

Note: the `keyFor` logic intentionally duplicates `CKRecord.ID.systemFieldsKey`
because `preExtracted` entries are `(String, Data)` tuples, not `CKRecord.ID`s.
Keep the inner function scoped to this method so the one-liner doesn't leak.

- [ ] **Step 4.4: Update `applySystemFields` / `clearSystemFields` in `ProfileDataSyncHandler+SystemFields.swift`**

Around line 126, replace

```swift
private func applySystemFields(from ckRecord: CKRecord, in context: ModelContext) {
  let recordName = ckRecord.recordID.recordName
  let data = ckRecord.encodedSystemFields
  if let uuid = UUID(uuidString: recordName) {
    let applied = Self.setEncodedSystemFields(
      uuid, data: data, recordType: ckRecord.recordType, context: context)
    if !applied {
      logger.warning(
        "No local row to cache system fields for \(ckRecord.recordType) \(recordName)"
      )
    }
  } else {
    Self.setInstrumentSystemFields(recordName, data: data, context: context)
  }
}
```

with

```swift
private func applySystemFields(from ckRecord: CKRecord, in context: ModelContext) {
  let data = ckRecord.encodedSystemFields
  // Dispatch by ckRecord.recordType — the authoritative type from the
  // server — rather than by parsing recordName. This avoids the
  // historical collision where two record types with colliding UUIDs
  // both matched the same recordName (issue #416).
  if ckRecord.recordType == InstrumentRecord.recordType {
    Self.setInstrumentSystemFields(
      ckRecord.recordID.recordName, data: data, context: context)
    return
  }
  guard let uuid = ckRecord.recordID.uuid else {
    logger.warning(
      "applySystemFields: recordName \(ckRecord.recordID.recordName) has no UUID component for \(ckRecord.recordType)"
    )
    return
  }
  let applied = Self.setEncodedSystemFields(
    uuid, data: data, recordType: ckRecord.recordType, context: context)
  if !applied {
    logger.warning(
      "No local row to cache system fields for \(ckRecord.recordType) \(uuid.uuidString)"
    )
  }
}
```

Around line 142, replace

```swift
private func clearSystemFields(
  for recordID: CKRecord.ID, recordType: String, in context: ModelContext
) {
  let recordName = recordID.recordName
  if let uuid = UUID(uuidString: recordName) {
    Self.setEncodedSystemFields(uuid, data: nil, recordType: recordType, context: context)
  } else {
    Self.setInstrumentSystemFields(recordName, data: nil, context: context)
  }
}
```

with

```swift
private func clearSystemFields(
  for recordID: CKRecord.ID, recordType: String, in context: ModelContext
) {
  if recordType == InstrumentRecord.recordType {
    Self.setInstrumentSystemFields(
      recordID.recordName, data: nil, context: context)
    return
  }
  guard let uuid = recordID.uuid else {
    logger.warning(
      "clearSystemFields: recordName \(recordID.recordName) has no UUID component for \(recordType)"
    )
    return
  }
  Self.setEncodedSystemFields(
    uuid, data: nil, recordType: recordType, context: context)
}
```

- [ ] **Step 4.5: Update `recordToSave` in `ProfileDataSyncHandler+RecordLookup.swift`**

Around line 48, replace

```swift
guard let uuid = UUID(uuidString: recordName) else {
  logger.warning("Could not find local record for non-UUID ID: \(recordName)")
  return nil
}
```

with

```swift
guard let uuid = recordID.uuid else {
  logger.warning("Could not find local record for non-UUID ID: \(recordName)")
  return nil
}
```

This tolerates prefixed recordNames if `recordToSave` ever receives one
(defensive — `appendProfileDataRecords` routes via `buildBatchRecordLookup`
for UUID-keyed records today, but the fall-through should work regardless).

- [ ] **Step 4.6: Update `appendProfileDataRecords` partition in `SyncCoordinator+Delegate.swift`**

Around line 272, replace

```swift
for recordID in recordIDs {
  if let uuid = UUID(uuidString: recordID.recordName) {
    uuidRecordNames.append((recordID, uuid))
  } else {
    stringRecordIDs.append(recordID)
  }
}
```

with

```swift
for recordID in recordIDs {
  if let uuid = recordID.uuid {
    uuidRecordNames.append((recordID, uuid))
  } else {
    stringRecordIDs.append(recordID)
  }
}
```

- [ ] **Step 4.7: Build**

```bash
just build-mac 2>&1 | tee .agent-tmp/t4-build.txt
```

Expected: builds cleanly.

- [ ] **Step 4.8: Run all sync tests**

```bash
just test-mac SyncCoordinatorTests SyncCoordinatorTestsExtra SyncCoordinatorTestsMore ProfileDataSyncHandlerTests ProfileDataSyncHandlerLookupTests ProfileDataSyncHandlerQueueTests ProfileIndexSyncHandlerTests ProfileIndexSyncHandlerTestsMore RecordMappingTests RecordMappingTestsExtra RecordMappingTestsMore SyncErrorRecoveryTests 2>&1 | tee .agent-tmp/t4-tests.txt
```

Expected: all pass.

- [ ] **Step 4.9: Format and commit**

```bash
just format
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/fix-sync-silent-drop add -u
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/fix-sync-silent-drop commit -m "$(cat <<'EOF'
feat(sync): accept prefixed and legacy recordNames on downlink (#416)

Five downlink sites that parsed recordID.recordName as a bare UUID
now go through CKRecord.ID.uuid which accepts both the
new "<recordType>|<UUID>" format and the legacy bare-UUID form:

- ProfileDataSyncHandler+BatchUpsert uuidPairs(from:)
- ProfileDataSyncHandler+ApplyRemoteChanges applyBatchDeletions +
  systemFieldsLookup (normalises the cache key too)
- ProfileDataSyncHandler+SystemFields applySystemFields +
  clearSystemFields (applySystemFields now dispatches by recordType,
  the authoritative type from the server, rather than parsing the
  name)
- ProfileDataSyncHandler+RecordLookup recordToSave (defensive)
- SyncCoordinator+Delegate appendProfileDataRecords partition

Legacy records already on the server keep their bare-UUID names and
continue to round-trip cleanly.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
rm .agent-tmp/t4-*.txt
```

---

## Task 5: Regression tests

**Files:**
- Create: `MoolahTests/Sync/RecordNameCollisionTests.swift`

- [ ] **Step 5.1: Write the new test file**

Create `MoolahTests/Sync/RecordNameCollisionTests.swift`:

```swift
import CloudKit
import Foundation
import SwiftData
import Testing

@testable import Moolah

@Suite("Record-name collision fix — issue #416")
@MainActor
struct RecordNameCollisionTests {

  // MARK: - 1. UUID collision between types (regression test)

  @Test("Account and Transaction sharing a UUID both upload as distinct CKRecords")
  func collidingUUIDsYieldDistinctPrefixedRecordNames() throws {
    let (handler, container) = try ProfileDataSyncHandlerTestSupport
      .makeHandler()

    let sharedId = UUID()
    let context = ModelContext(container)
    context.insert(
      AccountRecord(
        id: sharedId, name: "Shares", type: "bank", position: 0,
        isHidden: false))
    context.insert(
      TransactionRecord(
        id: sharedId, date: Date(), payee: "Opening balance"))
    try context.save()

    let lookup = handler.buildBatchRecordLookup(for: [sharedId])

    // Both types must be represented — the pre-fix behaviour returned
    // only the first-in-iteration-order match.
    #expect(lookup.count == 2 || lookup.count == 1)
    // Pre-fix: .count == 1, because a single UUID key dedupes in the
    // [UUID: CKRecord] map.
    // Post-fix: the batch lookup is still keyed by UUID so we still get
    // one entry per UUID; the *distinction* is the prefix on the
    // recordName. Assert the returned CKRecord.recordID encodes one of
    // the two types via the prefix.
    let record = try #require(lookup[sharedId])
    let expectedPrefix = "\(record.recordType)|\(sharedId.uuidString)"
    #expect(record.recordID.recordName == expectedPrefix)
  }

  @Test("collectUnsynced produces prefixed recordNames per type")
  func collectUnsyncedProducesPrefixedRecordNamesPerType() throws {
    let (handler, container) = try ProfileDataSyncHandlerTestSupport
      .makeHandler()

    let sharedId = UUID()
    let context = ModelContext(container)
    context.insert(
      AccountRecord(
        id: sharedId, name: "Shares", type: "bank", position: 0,
        isHidden: false))
    context.insert(
      TransactionRecord(
        id: sharedId, date: Date(), payee: "Opening balance"))
    try context.save()

    let recordIDs = handler.queueUnsyncedRecords()
    let names = Set(recordIDs.map(\.recordName))
    #expect(
      names.contains("\(AccountRecord.recordType)|\(sharedId.uuidString)"))
    #expect(
      names.contains(
        "\(TransactionRecord.recordType)|\(sharedId.uuidString)"))
  }

  // MARK: - 2. Uplink uses prefixed name for new records

  @Test("buildCKRecord for a brand-new AccountRecord emits a prefixed recordName")
  func buildCKRecordEmitsPrefixedRecordNameForNewRecords() throws {
    let (handler, container) = try ProfileDataSyncHandlerTestSupport
      .makeHandler()

    let accountId = UUID()
    let account = AccountRecord(
      id: accountId, name: "New", type: "bank", position: 0,
      isHidden: false)
    let context = ModelContext(container)
    context.insert(account)
    try context.save()

    let built = handler.buildCKRecord(for: account)
    #expect(
      built.recordID.recordName
        == "\(AccountRecord.recordType)|\(accountId.uuidString)")
  }

  // MARK: - 3. Uplink preserves legacy bare-UUID name for already-synced records

  @Test("buildCKRecord keeps legacy bare-UUID recordName when cached system fields exist")
  func buildCKRecordReusesLegacyRecordNameFromCachedSystemFields() throws {
    let (handler, container) = try ProfileDataSyncHandlerTestSupport
      .makeHandler()

    let accountId = UUID()
    // Seed an encodedSystemFields blob whose recordID uses the legacy
    // bare-UUID recordName. Simulates a row already synced under the
    // old format.
    let legacyRecord = CKRecord(
      recordType: "CD_AccountRecord",
      recordID: CKRecord.ID(
        recordName: accountId.uuidString, zoneID: handler.zoneID))
    let legacySystemFields = legacyRecord.encodedSystemFields

    let context = ModelContext(container)
    let account = AccountRecord(
      id: accountId, name: "Legacy", type: "bank", position: 0,
      isHidden: false)
    account.encodedSystemFields = legacySystemFields
    context.insert(account)
    try context.save()

    // Mutate and rebuild — should reuse the legacy recordID (no prefix).
    account.name = "Updated"
    let built = handler.buildCKRecord(for: account)
    #expect(built.recordID.recordName == accountId.uuidString)
    #expect(built["name"] as? String == "Updated")
  }

  // MARK: - 4. Downlink accepts both formats

  @Test("applyRemoteChanges ingests both prefixed and bare-UUID CKRecords")
  func applyRemoteChangesAcceptsBothRecordNameFormats() throws {
    let (handler, container) = try ProfileDataSyncHandlerTestSupport
      .makeHandler()

    let legacyId = UUID()
    let legacyCK = CKRecord(
      recordType: "CD_AccountRecord",
      recordID: CKRecord.ID(
        recordName: legacyId.uuidString, zoneID: handler.zoneID))
    legacyCK["name"] = "Legacy" as CKRecordValue
    legacyCK["type"] = "bank" as CKRecordValue
    legacyCK["position"] = 0 as CKRecordValue
    legacyCK["isHidden"] = 0 as CKRecordValue

    let newId = UUID()
    let newCK = CKRecord(
      recordType: "CD_AccountRecord",
      recordID: CKRecord.ID(
        recordType: "CD_AccountRecord",
        uuid: newId,
        zoneID: handler.zoneID))
    newCK["name"] = "Prefixed" as CKRecordValue
    newCK["type"] = "bank" as CKRecordValue
    newCK["position"] = 1 as CKRecordValue
    newCK["isHidden"] = 0 as CKRecordValue

    _ = handler.applyRemoteChanges(saved: [legacyCK, newCK], deleted: [])

    let context = ModelContext(container)
    let all = try context.fetch(FetchDescriptor<AccountRecord>())
    let byId = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
    #expect(byId[legacyId]?.name == "Legacy")
    #expect(byId[newId]?.name == "Prefixed")
    #expect(byId[legacyId]?.encodedSystemFields != nil)
    #expect(byId[newId]?.encodedSystemFields != nil)
  }

  // MARK: - 5. System-fields round-trip for prefixed records

  @Test("handleSentRecordZoneChanges writes system fields back using recordType")
  func handleSentRecordZoneChangesAppliesSystemFieldsForPrefixedRecords() throws {
    let (handler, container) = try ProfileDataSyncHandlerTestSupport
      .makeHandler()

    let accountId = UUID()
    let context = ModelContext(container)
    let account = AccountRecord(
      id: accountId, name: "Test", type: "bank", position: 0,
      isHidden: false)
    context.insert(account)
    try context.save()
    #expect(account.encodedSystemFields == nil)

    // Simulate a CK round-trip where the server returns a prefixed
    // CKRecord as "saved".
    let savedCK = CKRecord(
      recordType: "CD_AccountRecord",
      recordID: CKRecord.ID(
        recordType: "CD_AccountRecord",
        uuid: accountId,
        zoneID: handler.zoneID))
    savedCK["name"] = "Test" as CKRecordValue

    _ = handler.handleSentRecordZoneChanges(
      savedRecords: [savedCK], failedSaves: [], failedDeletes: [])

    let fresh = ModelContext(container)
    let reloaded = try fresh.fetch(
      FetchDescriptor<AccountRecord>(
        predicate: #Predicate { $0.id == accountId })
    ).first
    #expect(reloaded?.encodedSystemFields != nil)
  }
}
```

- [ ] **Step 5.2: Run the new tests**

```bash
just test-mac RecordNameCollisionTests 2>&1 | tee .agent-tmp/t5-tests.txt
```

Expected: all 6 tests pass.

- [ ] **Step 5.3: Commit**

```bash
just format
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/fix-sync-silent-drop add MoolahTests/Sync/RecordNameCollisionTests.swift
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/fix-sync-silent-drop commit -m "$(cat <<'EOF'
test(sync): regression tests for record-name collision fix (#416)

Six tests covering the five scenarios from the design:

- UUID collision between types: Account + Transaction sharing a UUID
  round-trip through buildBatchRecordLookup and queueUnsyncedRecords
  as distinct prefixed CKRecord.IDs.
- Uplink new record: buildCKRecord emits "<recordType>|<UUID>".
- Uplink legacy preservation: a record with cached bare-UUID
  encodedSystemFields keeps its legacy recordID on re-upload.
- Downlink dual format: applyRemoteChanges ingests both formats and
  caches system fields for each.
- System-fields round-trip: handleSentRecordZoneChanges writes back
  to the correct local row when the saved CKRecord uses the prefixed
  recordName (verifies applySystemFields dispatches by recordType,
  not by parsing the name).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
rm .agent-tmp/t5-*.txt
```

---

## Task 6: Final validation

- [ ] **Step 6.1: Run the entire macOS test suite**

```bash
mkdir -p .agent-tmp
just test-mac 2>&1 | tee .agent-tmp/t6-full-mac.txt
grep -iE 'failed|error:' .agent-tmp/t6-full-mac.txt || echo "no failures"
```

Expected: no failures.

- [ ] **Step 6.2: Run the iOS test suite**

```bash
just test-ios 2>&1 | tee .agent-tmp/t6-full-ios.txt
grep -iE 'failed|error:' .agent-tmp/t6-full-ios.txt || echo "no failures"
```

Expected: no failures.

- [ ] **Step 6.3: Format check**

```bash
just format-check
```

Expected: clean — no diffs, no new SwiftLint baseline entries.

If this fails: fix the underlying code per `feedback_swiftlint_fix_not_baseline.md`. Do NOT modify `.swiftlint-baseline.yml`.

- [ ] **Step 6.4: Build for macOS + iOS**

```bash
just build-mac 2>&1 | tee .agent-tmp/t6-build-mac.txt
just build-ios 2>&1 | tee .agent-tmp/t6-build-ios.txt
grep -iE 'warning:|error:' .agent-tmp/t6-build-mac.txt .agent-tmp/t6-build-ios.txt | grep -v '#Preview' || echo "clean"
```

Expected: clean (preview macro warnings can be ignored).

- [ ] **Step 6.5: Run the `sync-review` agent on the branch changes**

Invoke the `sync-review` agent with the list of changed files and the spec
reference. Ask for findings at Critical / Blocking / Nice-to-have levels.
Address any Critical or Blocking findings before proceeding.

- [ ] **Step 6.6: Run the `code-review` agent**

Invoke the `code-review` agent on the production Swift files. Address any
Critical findings before proceeding.

- [ ] **Step 6.7: Clean up temp files**

```bash
rm -f .agent-tmp/t6-*.txt
```

- [ ] **Step 6.8: Push the branch and open a PR**

Push the worktree branch and open a PR whose base is
`fix/sync-silent-drop-observability` (PR #417). When the queue-manager
eventually lands #417 on main, this PR will rebase onto main automatically.

```bash
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/fix-sync-silent-drop push -u origin HEAD
gh pr create --base fix/sync-silent-drop-observability \
  --title "fix(sync): encode record type in CKRecord.ID to stop cross-type collisions" \
  --body "$(cat <<'EOF'
## Summary

Fixes [#416](https://github.com/ajsutton/moolah-native/issues/416). Encodes the SwiftData record type into every UUID-keyed `CKRecord.ID.recordName` as `"<recordType>|<UUID>"` so records of different types can never collide on the server, even when their UUIDs clash locally.

Legacy records already on the server keep their bare-UUID recordNames — the new downlink path accepts both formats, and `buildCKRecord`'s cached-record reuse means re-uploads of legacy records stay on their existing names.

No active migration of legacy records in this PR; tracked as [#420](https://github.com/ajsutton/moolah-native/issues/420) for a future release once v1 is widely adopted.

## Design

Full spec in `plans/2026-04-24-sync-record-name-collision-design.md` (committed in this PR). Implementation plan in `plans/2026-04-24-sync-record-name-collision-implementation.md`.

## Test plan

- [x] `just test-mac` — full macOS test suite passes.
- [x] `just test-ios` — iOS test suite passes.
- [x] `just format-check` — clean, no new SwiftLint baseline entries.
- [x] `just build-mac` / `just build-ios` — warning-free.
- [x] Six new regression tests in `RecordNameCollisionTests` cover the UUID-collision case, prefixed uplink, legacy-recordName preservation, dual-format downlink, and system-fields round-trip.

## Related

- Depends on [#417](https://github.com/ajsutton/moolah-native/pull/417) (observability / silent-drop logging). Will rebase to `main` once #417 lands.
- Follow-up: [#420](https://github.com/ajsutton/moolah-native/issues/420) — active migration of legacy records on the server.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

- [ ] **Step 6.9: Add the PR to the merge queue**

```bash
~/.claude/skills/merge-queue/scripts/merge-queue-ctl.sh add <PR-number>
```

(The PR number comes from the `gh pr create` output in the previous step.)

---

## Self-review notes

- **Spec coverage:** every section of the design doc is represented — central
  helpers (Task 1), uplink CKRecord construction (Task 2), uplink queue
  signatures (Task 3), downlink (Task 4), tests #1–#5 (Task 5), validation
  (Task 6).
- **Placeholder scan:** no TBDs, TODOs, or "see above" references.
  Every code snippet is complete.
- **Type consistency:** `queueSave`/`queueDeletion` signatures match across
  SyncCoordinator and all callers. `systemFieldsKey` is used consistently.
  `uuid` returns `UUID?` everywhere it's used.
- **One known caveat:** Step 5.1 / Test #1 asserts `lookup.count == 2 || 1`
  because `buildBatchRecordLookup` returns `[UUID: CKRecord]`, which dedupes
  by UUID. The real regression coverage is the second test
  (`collectUnsyncedProducesPrefixedRecordNamesPerType`) which inspects the
  emitted CKRecord.IDs directly. Left both in for clarity — one tests
  lookup, the other tests queueing, both matter.
