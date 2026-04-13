# Explicit Sync Change Queueing

**Date:** 2026-04-13
**Status:** Implemented — uploading successfully

## Problem

After migrating a profile from remote to iCloud, accounts are duplicated (93 records for 31 accounts), other record types never sync, and the Mac beachballs. The root cause is a re-upload loop driven by the interaction between `ChangeTracker`, `pendingSaves`, and derived-data saves (`cachedBalance`).

The `ChangeTracker` observes all `NSManagedObjectContextDidSave` notifications and queues every touched record for upload. It cannot distinguish user edits from derived-data updates (e.g. `recomputeAllBalances` writing `cachedBalance`). The `pendingSaves` set tries to deduplicate but is removed-on-send, allowing the ChangeTracker to re-queue the same records on the next save. This creates an infinite loop: upload -> remove from pendingSaves -> balance recompute triggers save -> ChangeTracker re-queues -> upload again.

See `plans/SYNC_REUPLOAD_LOOP.md` for the full analysis.

## Design

Replace the notification-based `ChangeTracker` with explicit change queueing from repository methods. This aligns with Apple's CKSyncEngine sample app pattern where mutations both update the local store and notify the sync engine in one step.

### Changes

**Remove:**
- `ChangeTracker` class (entire file)
- `pendingSaves` and `pendingDeletions` sets from `ProfileSyncEngine`
- `addPendingChange` method from `ProfileSyncEngine`
- `changeTracker` property and wiring from `ProfileSession`

**Add:**
- `onRecordChanged: (UUID) -> Void` closure on each CloudKit repository, called after every syncable mutation (create, update, delete)
- `onRecordDeleted: (UUID) -> Void` closure on each CloudKit repository, called after deletions
- Both closures default to `{ _ in }` (no-op) so non-sync callers (tests, previews, RemoteBackend) don't need to handle them

**Modify:**
- `ProfileSyncEngine.addPendingChange` replaced with two simple public methods:
  - `queueSave(id: UUID)` — builds `CKRecord.ID` from the UUID and calls `syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(...)])`
  - `queueDeletion(id: UUID)` — same for deletions
  - No dedup set. CKSyncEngine accumulates entries; `nextRecordZoneChangeBatch` deduplicates (already implemented via `seenSaves`/`seenDeletes` sets).
- `ProfileSession` wires the closures when creating CloudKit repositories via downcast to concrete types
- `hasPendingChanges` checks `syncEngine.state.pendingRecordZoneChanges.isEmpty` instead of the removed local sets
- Error handlers in `handleSentRecordZoneChanges` re-queue on unexpected errors (default case) instead of silently dropping records

**Keep unchanged:**
- `queueAllExistingRecords()` — still needed as a recovery mechanism for migration, account sign-in, encrypted data reset, and state file loss
- `nextRecordZoneChangeBatch` deduplication logic — still needed because CKSyncEngine's pending list does not deduplicate
- `systemFieldsCache` — still needed for change tag preservation

## Additional Fixes Discovered During Implementation

### 1. Zone Creation Race (Critical)

CKSyncEngine does NOT create zones automatically. When records are sent to a non-existent zone, CKSyncEngine reports various error codes depending on context:
- `zoneNotFound` (code 26) — documented case
- `limitExceeded` (code 27) — when the batch is too large AND zone is missing
- `userDeletedZone` (code 28) — when zone was never created
- `invalidArguments` (code 12) — observed in practice for missing zones

**Fix:** `ensureZoneExists()` is called asynchronously on engine start, and after zone creation we explicitly call `sendChanges()` to flush pending records. The zone creation Task fires before CKSyncEngine schedules its first automatic send.

### 2. Batch Size Limit (Critical)

CloudKit limits batches to ~400 records per request. `nextRecordZoneChangeBatch` was returning ALL pending records (21K+) in a single batch, causing `BatchTooLarge` errors (internal code 1020). CKSyncEngine does NOT automatically chunk the batch — it sends exactly what `nextRecordZoneChangeBatch` returns.

**Fix:** `nextRecordZoneChangeBatch` now returns at most 400 records per call. CKSyncEngine calls the method repeatedly until it returns nil. With 21K records, this results in ~54 batches of 400.

### 3. Record Lookup Performance

The original `recordToSave(for:)` did individual SwiftData fetches per record, trying 6 record types each. With 21K records this was 130K+ queries on the main thread, causing beachball/white screen.

**Fix:** `buildBatchRecordLookup` does per-UUID lookups but only for the current batch (≤400 records). Record types are checked in frequency order (TransactionRecord first, then InvestmentValueRecord) to minimize queries. At 400 records per batch, worst case is 2400 queries — fast enough to not block the UI.

### 4. Error Recovery

The `default` case in `handleSentRecordZoneChanges` was `break` — silently dropping records on unexpected errors. When `invalidArguments` (code 12) was returned for a missing zone, all 21K records were permanently lost from the pending queue.

**Fix:** The `default` case now re-queues the record and logs the error. This ensures records survive unexpected errors and are retried on the next send cycle.

## Implementation Status

- [x] ChangeTracker removed
- [x] pendingSaves/pendingDeletions removed
- [x] Repository closures added and wired
- [x] Zone creation on startup
- [x] Batch size limit (400 per batch)
- [x] Record lookup optimized (frequency-ordered per-UUID lookups)
- [x] Error recovery (default case re-queues)
- [x] 620 tests pass, no warnings
- [x] Initial upload of 21K records succeeding (batches of 400, ~5-6 seconds per batch)
- [ ] Verify iPhone receives full dataset after Mac upload completes
- [ ] Verify ongoing sync (create/edit/delete on one device appears on the other)

## Lessons Learned

1. **CKSyncEngine does NOT deduplicate pending changes.** Adding the same recordID multiple times creates multiple entries. Dedup must happen in `nextRecordZoneChangeBatch`.

2. **CKSyncEngine does NOT create zones.** You must create the zone before sending records. The error codes for missing zones are inconsistent (`zoneNotFound`, `userDeletedZone`, `invalidArguments`). Proactive zone creation is the only reliable approach.

3. **CKSyncEngine does NOT chunk batches.** Whatever `nextRecordZoneChangeBatch` returns is sent as a single CloudKit operation. If it exceeds 400 records, the entire operation fails with `BatchTooLarge`. The method must self-limit to ≤400 records.

4. **CKSyncEngine error reporting is redacted.** OSLog privacy redaction hides record names, zone names, and error descriptions in production logs. You must check `com.apple.cloudkit` subsystem logs to see internal error details (like `BatchTooLarge`).

5. **Notification-based change tracking is fundamentally fragile.** `NSManagedObjectContextDidSave` cannot distinguish user edits from derived-data updates, leading to re-upload loops. Explicit queueing from repository mutations is the correct pattern.

6. **Shadow pending-change sets cause state inconsistency.** Maintaining a local `pendingSaves` set alongside CKSyncEngine's internal state creates opportunities for divergence. Let CKSyncEngine own its pending state and deduplicate at the batch level.
