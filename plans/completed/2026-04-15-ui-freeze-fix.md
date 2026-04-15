# UI Freeze Fix — Completed 2026-04-15

## Problem

The app froze for 500-600ms repeatedly during CloudKit sync, and for ~1.2s on initial profile load.

## Root Causes Found

### 1. Sync batch processing on main thread (known)
`SyncCoordinator.handleEvent` hopped to `@MainActor` for the entire `applyRemoteChanges` call, which processes 200-record batches via SwiftData upserts. Each batch blocked the main thread for ~570ms.

### 2. AccountRepo.fetchAll on main thread (newly discovered)
`CloudKitAccountRepository.fetchAll()` ran entirely inside `MainActor.run`, including:
- `computeAllBalances()` — aggregates ALL transaction legs (606ms)
- `computeAllPositions()` — aggregates ALL transaction legs again (578ms)
- Both called `fetchNonScheduledLegs()` independently, doubling the work

This blocked the main thread for **1,185ms** on every call — initial load AND sync-triggered reloads.

## Fixes Applied

### Fix 1: Move applyRemoteChanges off main thread
- Made `applyRemoteChanges` `nonisolated` on both `ProfileDataSyncHandler` and `ProfileIndexSyncHandler`
- Restructured `SyncCoordinator.handleEvent` to run heavy work off-main, hopping to `@MainActor` only for handler resolution and observer notifications
- Commit: `8d770c3`

### Fix 2: Move AccountRepo.fetchAll off main thread
- `fetchAll()` now creates a background `ModelContext(modelContainer)` instead of using `MainActor.run`
- `fetchNonScheduledLegs` called once, result shared between balance and position computation
- New background-context overloads for helper methods; original `@MainActor` versions preserved for write operations
- Commit: `a8d2937`

## Measurements

### Before (both fixes)
```
PERF: applyRemoteChanges blocked main thread for 578ms (upsert: 522ms, save: 56ms, 200 saves)
PERF: AccountRepo.fetchAll took 1185ms on main (records: 1ms, balances: 606ms, positions: 578ms, 32 accounts)
```

### After (both fixes)
```
AccountRepo.fetchAll took 779ms off-main (records: 1ms, balances: 725ms, positions: 53ms, 32 accounts)
Main thread: 2638/2638 samples (100%) in mach_msg2_trap (idle)
```

- Total work reduced from 1,185ms to 779ms (34% faster due to single leg fetch)
- Main thread completely idle during all sync and fetch operations
- Positions computation dropped from 578ms to 53ms (reuses pre-fetched legs)
