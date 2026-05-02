# Sync: Record-Name Collision Fix — Design

**Date:** 2026-04-24
**Issue:** [#416](https://github.com/ajsutton/moolah-native/issues/416)
**Base branch:** `fix/sync-silent-drop-observability` (PR [#417](https://github.com/ajsutton/moolah-native/pull/417))
**Status:** Draft → pending user approval

## Summary

Encode the SwiftData record type into every UUID-keyed `CKRecord.ID.recordName`
so records of different types can never share a server-side identity, even when
their UUIDs collide locally. Ship dual-format readers (`TYPE|UUID` and bare
`UUID`) so legacy records already on the server continue to sync without
disruption. Skip active migration of legacy records in this release; file a
follow-up issue for a cleanup pass once this change is widely adopted.

## Background

`ProfileDataSyncHandler+RecordLookup.swift` uses the UUID-string recordName as
the sole identifier when building a `CKRecord` to upload. The lookup iterates
record types in a fixed order and returns the first match — it implicitly
assumes UUIDs are globally unique across types, but nothing in the schema
enforces that.

In the wild, 16 accounts on a reporter's profile shared UUIDs with their
opening-balance transactions. Every upload of those accounts returned the
matching `TransactionRecord` instead, CloudKit saw "no new record," and the
16 accounts never left the device. CKSyncEngine reported clean success on
every cycle.

The broader CloudKit invariant: records are identified by
`(recordName, zoneID)`. If two record types share a UUID, only one can ever
exist at that recordName on the server. Today the first-type-to-sync wins and
the others are silently shadowed.

The diagnostic PR [#417](https://github.com/ajsutton/moolah-native/pull/417) has
already closed the silent-drop observability gap. This PR fixes the underlying
collision.

## Scope

**In scope (v1, this PR):**

- New recordName format `"<recordType>|<uuid.uuidString>"` for every
  UUID-keyed record.
- Prefix-tolerant downlink readers that accept both the new format and bare
  UUIDs (so records already on the server keep working).
- `queueSave` / `queueDeletion` signature change that forces callers to pass
  the record type — eliminates the structural source of the bug permanently.
- Regression test coverage (UUID collision; legacy compat; downlink; uplink;
  system-fields round-trip).

**Out of scope (deferred):**

- Active deletion of legacy UUID-only records on the server. Tracked as a
  follow-up issue; unsafe until v1 is widely adopted (see Risks below).
- Changes to `InstrumentRecord` (string-keyed, can't collide).

## Architecture

### Record-name format

For every UUID-keyed record:

```
"<recordType>|<uuid.uuidString>"
```

Examples:

```
CD_AccountRecord|1CAC9567-574B-481A-BADA-D595325CBE0C
CD_TransactionRecord|1CAC9567-574B-481A-BADA-D595325CBE0C
CD_ProfileRecord|A1B2C3D4-...
```

The `|` delimiter is safe: CloudKit permits it in recordNames, none of our
`recordType` constants contain it, and it can't appear in an `InstrumentRecord`
string ID (`"AUD"`, `"ASX:BHP"`, etc.).

`InstrumentRecord` recordNames keep their string-ID form. The parser
distinguishes them by the absence of `|` and the fact that bare IDs don't
parse as UUIDs.

### Central helpers

Two helpers on `CKRecord.ID` centralize construction and parsing. They live in
a new file `Backends/CloudKit/Sync/CKRecordID+RecordName.swift`.

```swift
extension CKRecord.ID {
  /// Constructs the new prefixed recordName from a type and UUID.
  convenience init(recordType: String, uuid: UUID, zoneID: CKRecordZone.ID) {
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
}
```

Every other site that used to build or parse a UUID recordName by hand
delegates to these two helpers.

### Uplink (local → CloudKit)

#### Queue signatures

`SyncCoordinator+Lifecycle.swift`:

```swift
func queueSave(id: UUID, recordType: String, zoneID: CKRecordZone.ID) { ... }
func queueDeletion(id: UUID, recordType: String, zoneID: CKRecordZone.ID) { ... }
// String-ID overload for InstrumentRecord stays unchanged:
func queueSave(recordName: String, zoneID: CKRecordZone.ID) { ... }
```

Both construct the `CKRecord.ID` via the new `init(recordType:uuid:zoneID:)`.

#### Callers

- **`App/ProfileSession+SyncWiring.swift`** — each repository wires its own
  `onRecordChanged` / `onRecordDeleted` callback; every repository is
  type-specific, so each call passes its corresponding `XxxRecord.recordType`.
- **`App/MoolahApp+Setup.swift`** — `ProfileRecord` callbacks pass
  `ProfileRecord.recordType`.
- **`ProfileDataSyncHandler+QueueAndDelete.swift`** — `collectUnsynced<T>` and
  `collectAllUUIDs<T>` emit `CKRecord.ID` via the new init, using
  `T.recordType` directly (T conforms to `CloudKitRecordConvertible`).

#### CKRecord construction

Each `<Type>Record+CloudKit.swift` has a `toCKRecord(in:)` that builds
`CKRecord.ID` inline from `id.uuidString`. All ten UUID-keyed types swap to
the new init:

```swift
func toCKRecord(in zoneID: CKRecordZone.ID) -> CKRecord {
  let recordID = CKRecord.ID(
    recordType: Self.recordType, uuid: id, zoneID: zoneID)
  let record = CKRecord(recordType: Self.recordType, recordID: recordID)
  ...
}
```

#### Legacy-record preservation

`ProfileDataSyncHandler.buildCKRecord(for:)` already reuses the cached CKRecord
from `encodedSystemFields` when present, copying fresh field values onto it.
For a record that was synced before this change, `encodedSystemFields` decodes
to a `CKRecord` whose `recordID.recordName` is the bare UUID, so re-uploads
automatically stay under that legacy name. No new code required for this
path.

### Downlink (CloudKit → local)

Five sites parse `recordID.recordName` today. All except `applySystemFields`
switch to `uuidRecordName()`.

| File | Function | Change |
|---|---|---|
| `ProfileDataSyncHandler+BatchUpsert.swift:279` | `uuidPairs(from:)` | Use `uuidRecordName()`. |
| `ProfileDataSyncHandler+ApplyRemoteChanges.swift:93` | `applyBatchDeletions` UUID parse | Use `uuidRecordName()`. |
| `ProfileDataSyncHandler+SystemFields.swift:129` | `applySystemFields` | Drop recordName parsing entirely; dispatch by `ckRecord.recordType`. |
| `ProfileDataSyncHandler+SystemFields.swift:146` | `clearSystemFields` | Use `uuidRecordName()` (recordType is passed in separately). |
| `ProfileDataSyncHandler+RecordLookup.swift:48` | `recordToSave` | Unchanged — its "not a UUID" branch handles instrument IDs. Prefixed UUIDs route via `appendProfileDataRecords` before reaching this site. |

In `SyncCoordinator+Delegate.swift:252`, `appendProfileDataRecords` partitions
recordIDs into UUID-based vs. string-based. Switch to `uuidRecordName()` —
prefixed records land in the UUID bucket correctly.

Each `<Type>Record+CloudKit.swift`'s `fieldValues(from:)` parses
`ckRecord.recordID.recordName` back to a UUID. All ten swap to
`uuidRecordName()`:

```swift
static func fieldValues(from ckRecord: CKRecord) -> AccountRecord {
  AccountRecord(
    id: ckRecord.recordID.uuidRecordName() ?? UUID(),
    ...
  )
}
```

### No active migration in v1

Legacy records already synced under bare-UUID recordNames stay on the server
under those names indefinitely. `buildCKRecord`'s cached-record reuse keeps
them there on re-upload. The downlink helpers accept both formats, so peer
devices (current or future) continue to fetch them correctly.

## Alternatives considered

**Option A (chosen).** Dual-format reader, write new format only for
never-synced records, no migration.

- Pro: zero risk to mixed-version users.
- Con: server carries both formats forever (until v2).
- Con: downlink parses through a prefix branch on every record (negligible cost).

**Option B.** Opportunistically clear `encodedSystemFields` on a legacy record
the next time it's mutated, forcing it to re-upload under a prefixed name.

- Rejected: orphans the old UUID-only record on the server.

**Option C.** Option A + a collision detector that forces prefix-mode upload
for records whose UUID collides locally.

- Rejected: the collision-detector logic adds code to a path that's already
  correct under Option A. For the reporter's profile specifically, Option A
  alone is sufficient — the 16 affected accounts have `encodedSystemFields
  == nil` (never synced) so they naturally get the new prefixed name on first
  upload. The Transaction side keeps its UUID-only name, and peers see both
  records correctly after the fix.

**Option D.** Atomic delete-old + upload-new migration on launch of new build.

- Rejected for v1: breaks mixed-version users. A peer on the old build would
  receive the delete (losing its local copy) plus a prefixed save that the
  old downlink can't parse (silent drop). Net effect: data loss on peers
  that haven't updated yet.
- Deferred to v2 (follow-up issue). Once v1 is widely adopted, the
  prefix-parser is everywhere and D becomes safe.

## Risks & edge cases

### Mixed-version devices

A user with one device on v1 and another on the prior release continues to
work: v1 keeps re-uploading legacy records under UUID-only names (via the
cached `encodedSystemFields`), so the old device sees no change in recordName
format. Any record created on v1 (with a prefixed name) will be dropped by
the old device's downlink — that's the v1 → v0 regression path, but it only
affects new records and converges as soon as the old device updates.

The v1 → v0 drop is strictly better than today, where the 16 colliding records
are invisible on every device.

### State-file migration

`CKSyncEngine.State.Serialization` on disk from a prior launch may carry
pending `CKRecord.ID`s with bare UUIDs. On the first v1 launch, those are
still valid recordNames: `buildCKRecord` resolves them via the cached
`encodedSystemFields` (UUID-only path), and the send cycle uploads under the
same bare UUID. No state-file migration required.

Pending records with no `encodedSystemFields` but bare-UUID recordNames (e.g.
a crashed launch between SwiftData write and CloudKit send) would upload
under bare UUID unnecessarily — but that's only an issue if the same UUID
collides with another record type, and in that specific case we want to
re-queue under the prefixed name. The backfill scan in
`queueUnsyncedRecords` handles this: `collectUnsynced` emits prefixed
`CKRecord.ID`s, and CKSyncEngine's pending-list dedup (SYNC_GUIDE Rule 12)
merges duplicates by recordID — bare UUID and `TYPE|UUID` are distinct
recordIDs, so the prefixed version wins for the next send cycle.

### ProfileRecord single-type zone

The profile-index zone is single-type today, so `ProfileRecord` cannot
collide. We still prefix it for uniformity and forward compatibility. The
dual-format parser is cheap and keeps the policy consistent across zones.

### Instrument IDs

`InstrumentRecord` uses string IDs (`"AUD"`, `"ASX:BHP"`). These cannot
contain `|` and cannot parse as UUIDs, so `uuidRecordName()` returns `nil`
and the string-ID branch takes over — same as today.

## Testing

Five targeted tests under `MoolahTests/Sync/`:

1. **UUID-collision regression.** Seed an `AccountRecord(id: X)` and a
   `TransactionRecord(id: X)`, both unsynced. Run the queue → batch-build
   path for both profile-data saves. Assert two CKRecords are built:
   `CD_AccountRecord|X` (recordType `CD_AccountRecord`) and
   `CD_TransactionRecord|X` (recordType `CD_TransactionRecord`). Assert
   both land on the server after the send event.

2. **Uplink uses prefixed name for new records.** Queue a save for a
   never-synced `AccountRecord`. Inspect the CKRecord built for upload —
   `recordID.recordName == "CD_AccountRecord|<UUID>"`.

3. **Uplink preserves legacy name for already-synced records.** Seed an
   `AccountRecord` whose cached `encodedSystemFields` decodes to a
   `CKRecord.ID` with a bare-UUID recordName. Mutate the record, queue a
   save, build the batch. Assert the rebuilt CKRecord's
   `recordID.recordName` is the bare UUID (no prefix).

4. **Downlink accepts both formats.** Call `applyRemoteChanges` with two
   synthetic `CD_AccountRecord` CKRecords: one with
   `recordName == "<UUID1>"` (legacy) and one with
   `recordName == "CD_AccountRecord|<UUID2>"` (new). Assert both land in
   SwiftData as distinct `AccountRecord` rows with the correct UUIDs and
   `encodedSystemFields`.

5. **System-fields round-trip for prefixed records.** Simulate a successful
   `sentRecordZoneChanges` event carrying a saved CKRecord with
   `recordID.recordName == "CD_AccountRecord|<UUID>"` and
   `recordType == "CD_AccountRecord"`. Assert the local `AccountRecord`'s
   `encodedSystemFields` is populated — verifies `applySystemFields`
   dispatches by `recordType` (not by parsing the prefix).

All five run against the in-memory `TestBackend` (`CloudKitBackend` +
in-memory SwiftData).

## Files touched

**New file:**

- `Backends/CloudKit/Sync/CKRecordID+RecordName.swift` — the two helpers.

**Modified:**

- `Backends/CloudKit/Sync/SyncCoordinator+Lifecycle.swift` — queue signatures.
- `App/ProfileSession+SyncWiring.swift` — pass recordType to queue calls.
- `App/MoolahApp+Setup.swift` — `ProfileRecord` queue calls pass recordType.
- `Backends/CloudKit/Sync/ProfileDataSyncHandler+QueueAndDelete.swift` —
  `collectUnsynced` / `collectAllUUIDs` use prefixed construction.
- `Backends/CloudKit/Sync/ProfileDataSyncHandler+SystemFields.swift` —
  `applySystemFields` dispatches by `recordType`; `clearSystemFields` uses
  `uuidRecordName()`.
- `Backends/CloudKit/Sync/ProfileDataSyncHandler+BatchUpsert.swift` —
  `uuidPairs(from:)` uses `uuidRecordName()`.
- `Backends/CloudKit/Sync/ProfileDataSyncHandler+ApplyRemoteChanges.swift` —
  deletion UUID-parse uses `uuidRecordName()`.
- `Backends/CloudKit/Sync/SyncCoordinator+Delegate.swift` —
  `appendProfileDataRecords` partition uses `uuidRecordName()`.
- `Backends/CloudKit/Sync/<Type>Record+CloudKit.swift` × 10 —
  `toCKRecord` uses the new init; `fieldValues` uses `uuidRecordName()`.

**New tests:**

- `MoolahTests/Sync/RecordNameCollisionTests.swift` — the five tests above.

## Follow-up

GitHub issue (to be filed after spec approval): **"sync: migrate legacy
UUID-only records to prefixed recordNames"**. Tracks the v2 delete-old +
upload-new migration pass, gated on v1 having been in the field long enough
that mixed-version data loss is acceptable risk.
