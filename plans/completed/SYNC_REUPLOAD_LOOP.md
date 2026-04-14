# Sync Re-Upload Loop Problem Analysis

## The Problem

After migrating a profile from remote to iCloud on the Mac, the Mac:
1. Beachballs for ~1 minute
2. Uploads duplicate records to CloudKit (93 account records for 31 actual accounts)
3. Fails to upload transactions, categories, earmarks, or investment values (the phone only receives accounts)

## The Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│ MainActor                                                       │
│                                                                 │
│  ┌──────────────┐    save()    ┌───────────────┐  addPending   │
│  │ SwiftData     │────────────▶│ ChangeTracker  │─────────────▶│
│  │ mainContext   │  (notif)    │ (observes all  │  Change()    │
│  │              │              │  context saves)│              │
│  └──────────────┘              └───────────────┘              │
│        ▲                                                       │
│        │ save()                                                │
│        │                                                       │
│  ┌──────────────┐  onRemoteChangesApplied   ┌──────────────┐  │
│  │ ProfileSync   │◀────────────────────────── │ Stores        │  │
│  │ Engine        │────────────────────────── ▶│ (load/reload) │  │
│  │              │  applyRemoteChanges()      │              │  │
│  └──────┬───────┘                            └──────────────┘  │
│         │                                                       │
│         │ pendingSaves Set                                      │
│         │ systemFieldsCache                                    │
│         │                                                       │
│  ┌──────▼───────┐                                              │
│  │ CKSyncEngine  │  (Apple framework, internal pending list)   │
│  │              │                                              │
│  └──────────────┘                                              │
└─────────────────────────────────────────────────────────────────┘
```

## Event Sources That Trigger Uploads

There are FOUR sources that add records to CKSyncEngine's pending upload list:

### 1. `queueAllExistingRecords()` — on first launch
- Called in `ProfileSyncEngine.start()` when `isFirstLaunch == true`
- Scans all record types, calls `addPendingChange(.saveRecord(id))` for each
- For a migration with 31 accounts + 18662 transactions + 158 categories + 21 earmarks + budget items + 2711 investment values = **21,597 records**

### 2. `ChangeTracker` — on every `mainContext.save()`
- Observes `NSManagedObjectContextDidSave` with `object: nil` (ALL contexts)
- Extracts inserted/updated/deleted entity IDs
- Calls `addPendingChange(.saveRecord(id))` for each
- Guard: checks `syncEngine.isApplyingRemoteChanges` to skip sync-originated saves
- **Problem:** Fires on ANY mainContext save, including:
  - `recomputeAllBalances` (updates `cachedBalance` on all accounts)
  - Store operations triggered by user navigation
  - Any SwiftData autosave

### 3. `handleSentRecordZoneChanges` error handlers
- On `serverRecordChanged`: caches server fields, re-queues the record
- On `zoneNotFound`: creates zone, re-queues
- On `unknownItem`, `quotaExceeded`, `limitExceeded`: re-queues
- These call `syncEngine.state.add(pendingRecordZoneChanges:)` **directly**, bypassing `addPendingChange`

### 4. `applyRemoteChanges` — caches system fields for received records
- Not an upload source directly, but caching system fields affects how re-uploads behave

## The Re-Upload Loop

Here's the exact sequence that causes the problem:

```
1. Migration imports 31 accounts + 18662 transactions into mainContext
2. context.save() triggers ChangeTracker → queues all records
3. ProfileSession creates ProfileSyncEngine
4. syncEngine.start() → queueAllExistingRecords() → queues all records (deduped by pendingSaves)
5. CKSyncEngine calls nextRecordZoneChangeBatch() → builds batch of records
6. CKSyncEngine sends batch to server
7. handleSentRecordZoneChanges:
   - Caches system fields for sent records
   - REMOVES sent records from pendingSaves  ← THIS IS THE PROBLEM
8. Meanwhile, accountStore.load() → fetchAll() → recomputeAllBalances() → mainContext.save()
9. ChangeTracker fires → addPendingChange for all 31 accounts
10. pendingSaves.insert(id) SUCCEEDS because step 7 removed them
11. syncEngine.state.add(pendingRecordZoneChanges:) adds them AGAIN
12. GOTO 5 — the same accounts are uploaded again
```

Each iteration of this loop:
- Adds another copy of each account to CKSyncEngine's internal pending list
- The dedup in `nextRecordZoneChangeBatch` filters within a single call, but CKSyncEngine calls it multiple times across send cycles
- Each send creates server records (first time) or updates them (with cached system fields)
- Other devices see each version as a separate modification event

## Why the Beachball

`nextRecordZoneChangeBatch` runs on the MainActor. It calls `recordToSave(for:)` for EVERY pending change, which does a SwiftData fetch per record. With 21,597+ pending changes (growing from the loop), this is 21,000+ individual fetch queries blocking the main actor.

The `recomputeAllBalances` call in `fetchAll()` also contributes — it fetches all 18,662 transactions on the main actor to compute balances for 31 accounts.

## Why Only Accounts Sync to the Phone

The re-upload loop keeps the Mac busy re-uploading accounts. CKSyncEngine's send queue is dominated by account records being re-queued. The 18,662 transactions are in the initial queue but never reach the front because accounts keep getting re-added.

## The `pendingSaves` Dual Role Problem

`pendingSaves` tries to serve two conflicting purposes:

1. **Dedup guard**: Prevents the same record from being queued multiple times
   - Requires: records stay in the set forever (or until deliberately re-queued)

2. **Pending tracking**: Tracks what hasn't been sent yet (for `hasPendingChanges`)
   - Requires: records are removed after successful send

These are incompatible. Removing after send (purpose 2) breaks the dedup guard (purpose 1).

## The ChangeTracker Fundamental Issue

The ChangeTracker is a blunt instrument. It observes `NSManagedObjectContextDidSave` and queues ALL changed entities. It has no way to distinguish:

- **User edits** (account renamed → should sync)
- **Sync-originated changes** (records just received from CloudKit → should NOT sync, guarded by `isApplyingRemoteChanges`)
- **Derived data updates** (`cachedBalance` recomputed → should NOT sync, but ChangeTracker doesn't know which fields changed)
- **Autosaves** (SwiftData's automatic saves → should NOT trigger re-uploads of records that are already queued)

The `isApplyingRemoteChanges` flag handles case 2 but not cases 3 or 4.

## CKSyncEngine's Internal State

CKSyncEngine maintains its own pending changes list (`syncEngine.state.pendingRecordZoneChanges`). This list:
- Does NOT deduplicate — calling `state.add(pendingRecordZoneChanges:)` multiple times with the same recordID adds multiple entries
- Is persisted across app launches via state serialization
- Is the source of truth for `nextRecordZoneChangeBatch`

Our `pendingSaves` Set is a local shadow that tries to prevent duplicate additions, but it's fragile because:
- It's cleared on send (allowing re-addition)
- It's not persisted (lost on restart)
- It doesn't prevent direct `syncEngine.state.add()` calls (error handlers bypass it)

## Summary of Root Causes

| Problem | Root Cause |
|---------|-----------|
| Server-side duplicates | Re-upload loop adds same records to CKSyncEngine multiple times |
| Re-upload loop | `handleSentRecordZoneChanges` removes from `pendingSaves`, allowing ChangeTracker to re-queue |
| ChangeTracker fires too often | `recomputeAllBalances` saves mainContext, ChangeTracker can't distinguish derived-data saves from user edits |
| Beachball | `nextRecordZoneChangeBatch` does N fetch queries for N pending changes, all on MainActor |
| Only accounts sync | Re-upload loop starves the send queue — accounts keep being re-added, transactions never reach the front |
| `cachedBalance` triggers uploads | Now excluded from CKRecord, but ChangeTracker still sees the AccountRecord as "updated" |

## What Needs to Be True

A correct solution must ensure:

1. Each record is uploaded to CloudKit exactly once per actual change
2. The ChangeTracker only queues records that were genuinely modified by user action
3. Sync-received records are never re-uploaded (unless subsequently edited by the user)
4. Derived data updates (`cachedBalance`) never trigger uploads
5. `nextRecordZoneChangeBatch` doesn't block the main actor excessively
6. CKSyncEngine's pending list never contains duplicate recordIDs
7. The system is race-free — correctness doesn't depend on timing of notifications vs. async operations
