# UI Freeze Fix — Systematic Diagnosis & Repair

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Eliminate UI freezes during CloudKit sync by measuring each stage of the sync-to-UI pipeline, identifying what blocks the main thread, and fixing each bottleneck with evidence.

**Architecture:** The sync pipeline has three stages that can block the main thread: (1) `applyRemoteChanges` — SwiftData upserts of CKRecords, (2) `context.save()` merge notifications from background saves propagating to the main context, (3) store reloads triggered by sync observers that call `repository.fetchAll()` inside `MainActor.run`. The stashed fix addresses stage 1. This plan instruments all three stages, measures them, and fixes whatever is actually slow.

**Tech Stack:** Swift, SwiftData, CKSyncEngine, os_signpost, `sample` CLI tool

**Prior work:** See `plans/2026-04-15-ui-freeze-investigation.md` for evidence gathered so far. The off-main fix is in `git stash` (`stash@{0}: WIP: off-main sync changes`).

---

## Phase 1: Apply Stashed Fix & Instrument the Full Pipeline

The stashed fix moves `applyRemoteChanges` off the main thread. It builds and passes tests. We need to apply it, then add instrumentation to the *remaining* pipeline stages to find what else blocks main.

### Task 1: Apply the stashed off-main fix

**Files:**
- Modify: `Backends/CloudKit/Sync/SyncCoordinator.swift`
- Modify: `Backends/CloudKit/Sync/ProfileDataSyncHandler.swift`
- Modify: `Backends/CloudKit/Sync/ProfileIndexSyncHandler.swift`

- [ ] **Step 1: Apply the stash**

```bash
git stash pop
```

- [ ] **Step 2: Verify it builds**

```bash
mkdir -p .agent-tmp && just build-mac 2>&1 | tee .agent-tmp/build-output.txt
grep -i 'error:' .agent-tmp/build-output.txt
```

Expected: Build succeeds, no errors.

- [ ] **Step 3: Run tests**

```bash
just test 2>&1 | tee .agent-tmp/test-output.txt
grep -i 'failed\|error:' .agent-tmp/test-output.txt
```

Expected: All tests pass (774 iOS + 790 macOS, per investigation notes).

- [ ] **Step 4: Commit**

```bash
git add Backends/CloudKit/Sync/SyncCoordinator.swift Backends/CloudKit/Sync/ProfileDataSyncHandler.swift Backends/CloudKit/Sync/ProfileIndexSyncHandler.swift
git commit -m "perf: move applyRemoteChanges off main thread

CKSyncEngine batch processing (SwiftData upserts + context.save) now runs
on a background thread. Only handler resolution and observer notifications
hop to @MainActor. Stack sampling confirmed main thread is idle during sync
with this change applied."
```

### Task 2: Add PERF logging to store reload paths

The store reloads are already partially instrumented (they log if > 16ms), but we need more granularity — specifically, how long the `repository.fetchAll()` call takes vs. the comparison/assignment. We also need to instrument `ProfileSession.scheduleReloadFromSync` to see total reload pipeline cost.

**Files:**
- Modify: `Features/Accounts/AccountStore.swift:44-59`
- Modify: `Features/Categories/CategoryStore.swift:39-57`
- Modify: `Features/Earmarks/EarmarkStore.swift:43-58`

- [ ] **Step 1: Add fetch-vs-compare breakdown to AccountStore.reloadFromSync**

In `Features/Accounts/AccountStore.swift`, replace the existing `reloadFromSync` method with timing that separates fetch from comparison:

```swift
func reloadFromSync() async {
    let start = ContinuousClock.now
    do {
        let fresh = Accounts(from: try await repository.fetchAll())
        let fetchMs = (ContinuousClock.now - start).inMilliseconds
        if fresh.ordered != accounts.ordered {
            accounts = fresh
        }
        let totalMs = (ContinuousClock.now - start).inMilliseconds
        if totalMs > 16 {
            logger.warning(
                "⚠️ PERF: accountStore.reloadFromSync took \(totalMs)ms (fetch: \(fetchMs)ms, diff+assign: \(totalMs - fetchMs)ms)"
            )
        }
    } catch {
        logger.error("Failed to reload accounts from sync: \(error)")
    }
}
```

- [ ] **Step 2: Same for CategoryStore.reloadFromSync**

In `Features/Categories/CategoryStore.swift`:

```swift
func reloadFromSync() async {
    let start = ContinuousClock.now
    do {
        let freshList = try await repository.fetchAll()
        let fetchMs = (ContinuousClock.now - start).inMilliseconds
        let fresh = Categories(from: freshList)
        let freshCategories = fresh.flattenedByPath().map(\.category)
        let currentCategories = categories.flattenedByPath().map(\.category)
        if freshCategories != currentCategories {
            categories = fresh
        }
        let totalMs = (ContinuousClock.now - start).inMilliseconds
        if totalMs > 16 {
            logger.warning(
                "⚠️ PERF: categoryStore.reloadFromSync took \(totalMs)ms (fetch: \(fetchMs)ms, diff+assign: \(totalMs - fetchMs)ms)"
            )
        }
    } catch {
        logger.error("Failed to reload categories from sync: \(error)")
    }
}
```

- [ ] **Step 3: Same for EarmarkStore.reloadFromSync**

In `Features/Earmarks/EarmarkStore.swift`:

```swift
func reloadFromSync() async {
    let start = ContinuousClock.now
    do {
        let fresh = Earmarks(from: try await repository.fetchAll())
        let fetchMs = (ContinuousClock.now - start).inMilliseconds
        if fresh.ordered != earmarks.ordered {
            earmarks = fresh
        }
        let totalMs = (ContinuousClock.now - start).inMilliseconds
        if totalMs > 16 {
            logger.warning(
                "⚠️ PERF: earmarkStore.reloadFromSync took \(totalMs)ms (fetch: \(fetchMs)ms, diff+assign: \(totalMs - fetchMs)ms)"
            )
        }
    } catch {
        logger.error("Failed to reload earmarks from sync: \(error)")
    }
}
```

- [ ] **Step 4: Build and run tests**

```bash
just build-mac 2>&1 | tee .agent-tmp/build-output.txt
grep -i 'error:' .agent-tmp/build-output.txt
```

Expected: Builds cleanly.

- [ ] **Step 5: Commit**

```bash
git add Features/Accounts/AccountStore.swift Features/Categories/CategoryStore.swift Features/Earmarks/EarmarkStore.swift
git commit -m "perf: add fetch-vs-compare breakdown to store reload logging"
```

### Task 3: Add PERF logging to AccountRepo.fetchAll sub-operations

`AccountStore.reloadFromSync` calls `repository.fetchAll()`, which does THREE things inside `MainActor.run`: fetch account records, `computeAllBalances()`, and `computeAllPositions()`. We need to know which is expensive.

**Files:**
- Modify: `Backends/CloudKit/Repositories/CloudKitAccountRepository.swift:22-50`

- [ ] **Step 1: Add sub-operation timing to fetchAll**

In `Backends/CloudKit/Repositories/CloudKitAccountRepository.swift`, add timing inside the `MainActor.run` block of `fetchAll()`:

```swift
return try await MainActor.run {
    let fetchStart = ContinuousClock.now
    let records = try context.fetch(descriptor)
    let fetchMs = (ContinuousClock.now - fetchStart).inMilliseconds

    let balanceStart = ContinuousClock.now
    let balances = try computeAllBalances()
    let balanceMs = (ContinuousClock.now - balanceStart).inMilliseconds

    let positionStart = ContinuousClock.now
    let allPositions = try computeAllPositions()
    let positionMs = (ContinuousClock.now - positionStart).inMilliseconds

    let result = try records.map { record in
        let storageValue = balances[record.id] ?? 0
        let balance = InstrumentAmount(storageValue: storageValue, instrument: instrument)
        let investmentValue =
            record.type == AccountType.investment.rawValue
            ? try latestInvestmentValue(for: record.id)
            : nil
        let positions = allPositions[record.id] ?? []
        return record.toDomain(
            balance: balance, investmentValue: investmentValue, positions: positions)
    }
    let totalMs = (ContinuousClock.now - fetchStart).inMilliseconds
    if totalMs > 16 {
        logger.warning(
            "⚠️ PERF: AccountRepo.fetchAll took \(totalMs)ms on main (records: \(fetchMs)ms, balances: \(balanceMs)ms, positions: \(positionMs)ms, map: \(totalMs - fetchMs - balanceMs - positionMs)ms, \(records.count) accounts)"
        )
    }
    return result
}
```

- [ ] **Step 2: Build**

```bash
just build-mac 2>&1 | tee .agent-tmp/build-output.txt
grep -i 'error:' .agent-tmp/build-output.txt
```

- [ ] **Step 3: Commit**

```bash
git add Backends/CloudKit/Repositories/CloudKitAccountRepository.swift
git commit -m "perf: add sub-operation timing to AccountRepo.fetchAll"
```

---

## Phase 2: Measure Under Real Conditions

### Task 4: Capture logs and stack samples during sync

This is a manual measurement task. Launch the app, trigger a sync, and capture what's happening on the main thread.

- [ ] **Step 1: Launch the app with log capture**

```bash
mkdir -p .agent-tmp
just run-mac &
sleep 3
log stream --predicate 'subsystem == "com.moolah.app"' --level info > .agent-tmp/app-logs.txt 2>&1 &
LOG_PID=$!
echo "Log stream PID: $LOG_PID"
```

- [ ] **Step 2: Trigger a sync and capture a stack sample during the freeze**

Navigate to a profile with data to trigger sync. While the app appears to freeze:

```bash
PID=$(pgrep -f "Moolah.app/Contents/MacOS/Moolah")
sample $PID 5 -f .agent-tmp/sample-during-sync.txt
```

- [ ] **Step 3: Stop log capture and analyze**

```bash
kill $LOG_PID 2>/dev/null
```

Analyze the logs — look for the full timing chain:

```bash
grep -E "PERF|Store reloads|reloadFromSync|AccountRepo.fetchAll" .agent-tmp/app-logs.txt
```

Key questions the logs answer:
1. Is `applyRemoteChanges` still showing up in PERF warnings? (Should NOT with off-main fix)
2. How long do store reloads take? Which store is slowest?
3. Inside `AccountRepo.fetchAll`, is it `computeAllBalances()` or `context.fetch()` that dominates?

- [ ] **Step 4: Analyze the stack sample**

```bash
# Find main thread activity
grep -A 50 "com.apple.main-thread" .agent-tmp/sample-during-sync.txt | head -80
```

Look for: What is the deepest frame with the most samples on the main thread? This tells us exactly what code is blocking.

- [ ] **Step 5: Record findings**

Update `plans/2026-04-15-ui-freeze-investigation.md` with the measurement results. Document:
- Each PERF log line and its timing
- The main thread hot path from the stack sample
- Which stage(s) of the pipeline are the actual bottleneck

---

## Phase 3: Fix Based on Measurements

**Important:** The specific fix depends on what Phase 2 reveals. Below are the three most likely scenarios with their fixes. Execute only the one that matches the measurements.

### Task 5a: IF store reloads are the bottleneck — move repository fetches off main

This is the most likely scenario. `CloudKitAccountRepository.fetchAll()` runs `context.fetch()` + `computeAllBalances()` + `computeAllPositions()` inside `MainActor.run`. If this takes > 16ms, it's a freeze.

**Fix approach:** Create a dedicated background `ModelContext` for read-only fetch operations in the repository, so fetches don't need `MainActor.run`. SwiftData `ModelContext` is not `Sendable`, but a `nonisolated` method can create one from the `ModelContainer` (which IS `Sendable`).

**Files:**
- Modify: `Backends/CloudKit/Repositories/CloudKitAccountRepository.swift`
- Modify: `Backends/CloudKit/Repositories/CloudKitCategoryRepository.swift`
- Modify: `Backends/CloudKit/Repositories/CloudKitEarmarkRepository.swift`

- [ ] **Step 1: Refactor CloudKitAccountRepository.fetchAll to use a background ModelContext**

The `ModelContainer` is already stored as a `nonisolated let` property. Create a fresh `ModelContext` inside `fetchAll` instead of using `MainActor.run`:

```swift
func fetchAll() async throws -> [Account] {
    let signpostID = OSSignpostID(log: Signposts.repository)
    os_signpost(
        .begin, log: Signposts.repository, name: "AccountRepo.fetchAll", signpostID: signpostID)
    defer {
        os_signpost(
            .end, log: Signposts.repository, name: "AccountRepo.fetchAll", signpostID: signpostID)
    }
    let descriptor = FetchDescriptor<AccountRecord>(
        sortBy: [SortDescriptor(\.position)]
    )
    // Use a fresh background ModelContext for read-only fetches.
    // This avoids blocking the main thread during sync-triggered reloads.
    let bgContext = ModelContext(modelContainer)
    let records = try bgContext.fetch(descriptor)
    let balances = try computeAllBalances(context: bgContext)
    let allPositions = try computeAllPositions(context: bgContext)

    return try records.map { record in
        let storageValue = balances[record.id] ?? 0
        let balance = InstrumentAmount(storageValue: storageValue, instrument: instrument)
        let investmentValue =
            record.type == AccountType.investment.rawValue
            ? try latestInvestmentValue(for: record.id, context: bgContext)
            : nil
        let positions = allPositions[record.id] ?? []
        return record.toDomain(
            balance: balance, investmentValue: investmentValue, positions: positions)
    }
}
```

**Note:** This requires `computeAllBalances`, `computeAllPositions`, and `latestInvestmentValue` to accept a `context` parameter instead of using `self.context`. Read those methods first to understand their current signatures and adapt accordingly. The key change is: every SwiftData query in the `fetchAll` path uses a background context, not `self.context` (which is `@MainActor`-bound).

**Concurrency safety:** `ModelContext(modelContainer)` creates a new context that is NOT `@MainActor`-isolated. Since `fetchAll` only reads (no writes/saves), this is safe — there's no mutation to conflict with the main context. The returned `[Account]` is a domain model (value type), not a SwiftData managed object.

- [ ] **Step 2: Apply same pattern to CloudKitCategoryRepository.fetchAll**

```swift
func fetchAll() async throws -> [Category] {
    // ... signpost setup same as before ...
    let descriptor = FetchDescriptor<CategoryRecord>(
        sortBy: [SortDescriptor(\.name)]
    )
    let bgContext = ModelContext(modelContainer)
    let records = try bgContext.fetch(descriptor)
    return records.map { $0.toDomain() }
}
```

This requires the repository to have access to `modelContainer`. Check if it already stores it; if not, add it as a `nonisolated let` property initialized from the existing `context`'s container, or pass it in at construction time.

- [ ] **Step 3: Apply same pattern to CloudKitEarmarkRepository.fetchAll**

Same approach — create `ModelContext(modelContainer)` for the read path.

- [ ] **Step 4: Build and run tests**

```bash
mkdir -p .agent-tmp && just test 2>&1 | tee .agent-tmp/test-output.txt
grep -i 'failed\|error:' .agent-tmp/test-output.txt
```

Expected: All tests pass. The tests use `TestBackend` which creates `CloudKitBackend` with in-memory SwiftData, so the background context approach works identically.

- [ ] **Step 5: Commit**

```bash
git add Backends/CloudKit/Repositories/
git commit -m "perf: use background ModelContext for read-only repository fetches

fetchAll() on Account, Category, and Earmark repositories now creates a
fresh ModelContext from the ModelContainer instead of running inside
MainActor.run. This prevents store reloads from blocking the main thread
during sync."
```

### Task 5b: IF SwiftData merge notifications are the bottleneck

If Phase 2 shows that `context.save()` on the background thread in `applyRemoteChanges` triggers expensive merge processing on the main context (you'll see `NSManagedObjectContext` merge frames in the stack sample), the fix is to batch saves less frequently or use a separate `ModelContainer`.

**This is a harder fix.** The evidence needed is: stack sample showing `NSPersistentStoreCoordinator` or `_NSNotificationCenter` or `mergeChanges` frames on the main thread with high sample counts during sync.

**Possible approaches (choose based on measurement):**
1. **Increase batch size in CKSyncEngine** — fewer saves = fewer merge notifications. Check if `CKSyncEngine.Configuration` allows controlling batch size.
2. **Disable automatic merge** on the main context and manually merge at the end of a fetch session, combining all batch merges into one.
3. **Use a separate ModelContainer** (separate SQLite file) for sync writes, then copy to the main store at session end. Heavy-handed but eliminates cross-context notifications entirely.

The specific implementation depends on what's measurable. Instrument first, then pick.

### Task 5c: IF the freeze is in observer notification callbacks

If Phase 2 shows that `notifyObservers` → `scheduleReloadFromSync` → debounce → reload chain itself is the problem (unlikely given the debounce), the fix is simpler: increase debounce during bulk sync or coalesce notifications at the SyncCoordinator level.

---

## Phase 4: Verify the Fix

### Task 6: Re-measure with fix applied

- [ ] **Step 1: Launch app with log capture and trigger sync**

Same as Task 4, Steps 1-2.

- [ ] **Step 2: Capture stack sample during sync**

```bash
PID=$(pgrep -f "Moolah.app/Contents/MacOS/Moolah")
sample $PID 5 -f .agent-tmp/sample-after-fix.txt
```

- [ ] **Step 3: Analyze and confirm fix**

```bash
grep -E "PERF|Store reloads|reloadFromSync|AccountRepo.fetchAll" .agent-tmp/app-logs.txt
```

**Success criteria:**
- No PERF warnings exceeding 16ms on the main thread
- Stack sample shows main thread mostly in `mach_msg2_trap` (idle/waiting) during sync
- App remains responsive while sync processes batches

- [ ] **Step 4: Clean up diagnostic logging**

Remove the verbose sub-operation timing added in Tasks 2-3 if it's too noisy for production. Keep the existing PERF threshold logging (> 16ms warnings) as it was before — that's useful for ongoing monitoring.

- [ ] **Step 5: Update investigation document**

Update `plans/2026-04-15-ui-freeze-investigation.md` with final results and move it to `plans/completed/`.

- [ ] **Step 6: Final commit**

```bash
git add -A
git commit -m "perf: remove diagnostic instrumentation, document fix

UI freezes during CloudKit sync resolved by:
1. Moving applyRemoteChanges off the main thread (Task 1)
2. [Fill in based on actual fix from Task 5a/5b/5c]"
```

- [ ] **Step 7: Clean up temp files**

```bash
rm -f .agent-tmp/sample-during-sync.txt .agent-tmp/sample-after-fix.txt .agent-tmp/app-logs.txt .agent-tmp/build-output.txt .agent-tmp/test-output.txt
pkill -f "Moolah.app/Contents/MacOS/Moolah" 2>/dev/null || true
pkill -f "log stream.*com.moolah.app" 2>/dev/null || true
```
