# Design: Store CKRecord System Fields on SwiftData Model Records

**Date:** 2026-04-14
**Status:** Approved

## Problem

The sync engine maintains a `[String: Data]` dictionary (`systemFieldsCache`) mapping record UUIDs to their CKRecord encoded system fields. This dictionary is serialized to a single file after every sync batch. With 20,000+ records, encoding takes 150ms–5s+ of CPU per flush — even off the main thread, this wastes significant CPU and the dictionary consumes ~5MB of memory.

Apple's documentation and CKSyncEngine sample code recommend storing encoded system fields directly on the model object, not in a separate cache.

## Solution

Add an `encodedSystemFields: Data?` column to each of the 6 SwiftData model types. System fields are persisted automatically via the existing `context.save()` after each batch. Eliminate the separate cache file, in-memory dictionary, and all serialization code.

## Detailed Changes

### 1. Model Records

Add `var encodedSystemFields: Data?` to:
- `AccountRecord`
- `TransactionRecord`
- `CategoryRecord`
- `EarmarkRecord`
- `EarmarkBudgetItemRecord`
- `InvestmentValueRecord`

SwiftData handles schema migration automatically for new optional properties with nil default — no explicit migration plan needed.

The `encodedSystemFields` property must NOT be overwritten during batch upserts from sync — it should only be set from the pre-extracted system fields data, not from `fieldValues(from:)`. This is the same pattern as `cachedBalance` on `AccountRecord` (computed locally, not synced).

### 2. ProfileSyncEngine — Remove Cache Infrastructure

Delete entirely:
- `systemFieldsCache: [String: Data]` property
- `systemFieldsSaveTask: Task<Void, Never>?` property
- `systemFieldsCacheURL` computed property
- `loadSystemFieldsCache()` method
- `saveSystemFieldsCache()` method
- `flushSystemFieldsCache()` static method
- `deleteSystemFieldsCache()` method
- The `systemFieldsCache = loadSystemFieldsCache()` call in `start()`
- The synchronous flush in `stop()`

### 3. ProfileSyncEngine.buildCKRecord() — Read from Model

Current flow:
```swift
// Look up in dictionary
if let cachedData = systemFieldsCache[recordName],
   let cachedRecord = CKRecord.fromEncodedSystemFields(cachedData) { ... }
```

New flow: `recordToSave()` already fetches the SwiftData model record by UUID. Pass the model's `encodedSystemFields` through to `buildCKRecord()`:
```swift
// Read from the model record that was already fetched
if let cachedData = record.encodedSystemFields,
   let cachedRecord = CKRecord.fromEncodedSystemFields(cachedData) { ... }
```

This requires refactoring `recordToSave()` to pass the `encodedSystemFields` alongside the record, or changing `buildCKRecord()` to accept it as a parameter.

### 4. applyRemoteChanges() — Set on Model During Upsert

Current flow: system fields are cached in the dictionary, then `saveSystemFieldsCache()` triggers a debounced full-dictionary serialize.

New flow: pass pre-extracted system fields into `applyBatchSaves()` so each `batchUpsert*` method can set `record.encodedSystemFields` on the model. The existing `context.save()` at the end of `applyRemoteChanges()` persists everything in one transaction.

The pre-extracted system fields are already available as `[(String, Data)]` (record name → encoded data). Convert to a dictionary for O(1) lookup during upsert:
```swift
let systemFieldsByName = Dictionary(preExtracted, uniquingKeysWith: { _, last in last })
```

Each `batchUpsert*` method receives this dictionary and sets:
```swift
existing.encodedSystemFields = systemFieldsByName[id.uuidString]
// or for new inserts:
values.encodedSystemFields = systemFieldsByName[id.uuidString]
```

### 5. handleSentRecordZoneChanges() — Update After Upload

After successful upload, the server returns the record with updated system fields. Currently these are cached in the dictionary. Instead, fetch the model record and update its `encodedSystemFields`:

```swift
case .success(let saved):
    let data = saved.encodedSystemFields
    // Fetch and update the model record
    if let uuid = UUID(uuidString: saved.recordID.recordName) {
        updateSystemFields(uuid, data: data, context: context)
    }
```

For `.serverRecordChanged` conflicts (server-wins), same pattern with the server record's system fields.

A helper method `updateSystemFields(_:data:context:)` fetches across all 6 record types by UUID (similar to `recordToSave()`'s existing lookup pattern).

### 6. Batch Upsert Method Signatures

Each `batchUpsert*` method gains a `systemFields: [String: Data]` parameter:

```swift
private nonisolated static func batchUpsertAccounts(
    _ ckRecords: [CKRecord],
    context: ModelContext,
    systemFields: [String: Data]
)
```

`applyBatchSaves` passes the dictionary through.

### 7. Migration / Cleanup

On first launch after upgrade:
- The old `.systemfields` file still exists on disk but is never read
- Add a one-time cleanup in `start()`: delete the `.systemfields` file if it exists
- System fields on model records will be nil initially — this is fine. The first sync cycle repopulates them. Records uploaded without cached system fields may trigger a `.serverRecordChanged` error, which the existing conflict resolution handles by re-fetching and retrying.

### 8. deleteLocalData() — No Changes Needed

When all model records are deleted (account sign-out), their `encodedSystemFields` are deleted with them automatically. No separate cache cleanup needed.

## What This Eliminates

- ~5MB in-memory dictionary for large accounts
- All JSON/plist serialization (150ms–5s+ per flush)
- The debounced save task and its complexity
- The separate `.systemfields` file on disk
- CPU spikes from re-encoding after every batch
- The `saveSystemFieldsCache()` call in `applyRemoteChanges()` — system fields are now persisted as part of the existing `context.save()`

## Risk Assessment

**Data integrity:** System fields are advisory metadata for conflict detection. If lost (e.g., during migration), the worst case is a `.serverRecordChanged` error on the next upload, which triggers re-fetch and retry. No data loss.

**Schema migration:** SwiftData auto-migrates new optional properties with nil default. No explicit migration plan needed. Tested pattern — same as when `cachedBalance` was added to `AccountRecord`.

**Performance:** Eliminates serialization entirely. The `context.save()` cost may increase slightly (more data per record), but this is already the bottleneck at 20-60ms per batch and the additional ~200 bytes per record is negligible compared to the record data itself.
