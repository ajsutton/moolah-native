# Upcoming Card Cold-Load Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Get the Analysis Dashboard's "Upcoming & Overdue" card data on screen in under 1 s on cold launch with the Large Test profile, down from the measured ~3.2 s. Tracks GitHub issue [#519](https://github.com/ajsutton/moolah-native/issues/519).

**Architecture:** Three small, independently shippable PRs. Phase 1 adds measurement so each subsequent change can claim a numeric delta. Phase 2 sequences the cold task so the cheap upcoming-list fetch wins the SwiftData SQL connection race against the expensive account-positions reduce. Phase 3 cuts `CloudKitAccountRepository.fetchNonScheduledLegs` from a 20,076-row full-table scan to a predicate-filtered query so it stops blocking the SQL connection for ~900 ms regardless of who got there first.

**Tech Stack:** Swift, SwiftUI, SwiftData (`ModelContainer`, `ModelContext`, `FetchDescriptor` with `#Predicate`), `os_log` / `os_signpost`, Swift Testing (`@Suite`, `@Test`, `#expect`).

---

## Pre-flight context for the executor

Read these before starting:

- `CLAUDE.md` — repo conventions: worktree-only edits, `git -C <path>` over `cd && git`, every PR through the merge queue, `just format && just format-check` before commit, never edit `.swiftlint-baseline.yml`.
- `guides/CONCURRENCY_GUIDE.md` — actor isolation, `ModelContext` rules, Sendable.
- `guides/CODE_GUIDE.md` — naming, error handling, file/function size limits.
- `Features/Analysis/Views/AnalysisView.swift` — the cold-launch entry point; the `.task` block is the sequencing target.
- `Features/Analysis/Views/UpcomingTransactionsCard.swift` — the card whose first-paint time is the user-visible metric.
- `Features/Transactions/TransactionStore.swift` — the store the upcoming card depends on; `fetchPage` is where the per-step timing lives.
- `Backends/CloudKit/Repositories/CloudKitAccountRepository.swift` and `+Positions.swift` — the cost centre we optimise in Phase 3.
- `Backends/CloudKit/Repositories/Signposts.swift` — central place for new signpost names.
- `plans/completed/2026-04-14-performance-optimization-design.md` — prior perf plan; don't duplicate work it already shipped.

### Profile to test against

The "Large Test" profile (28 accounts, 158 categories, 18 earmarks, **18,810 transactions / 20,076 legs**, 36 of which are scheduled). Stored at `~/Library/Containers/rocks.moolah.app/Data/Library/Application Support/Development/Moolah-4612F0B8-819F-4375-BFC8-057F5C8186AB.store`.

Open it via the in-app profile picker (it's listed as "Large Test"). Do **not** run automation or destructive operations against any other profile.

### Baseline numbers (already measured — issue #517 was the first pass)

Cold launch with Large Test, after #517 ships:

```
+0    ms : AccountStore + CategoryStore + EarmarkStore start loading
+217  ms : TransactionStore starts load(.scheduledOnly)
+670  ms : AccountRepo.fetchAll took ~785ms off-main (positions: ~783ms, 28 accounts)
+1953 ms : Categories + Earmarks done
+3024 ms : Accounts done
+2829 ms : TransactionStore done — 36 transactions loaded   ← upcoming card unblocks here
```

Acceptance for the whole plan: that last figure drops below **1000 ms** with no regression elsewhere.

### Conventions used by every task

- All edits happen in the worktree created in Task 0; never in the main checkout.
- After modifying any Swift, `just format && just format-check` before commit.
- Use `git -C <worktree>` for every git command. Never `cd worktree && git ...`.
- Every commit message uses a `<scope>: ` prefix (`perf:`, `feat:`, `refactor:`, `test:`, `chore:`).
- Push the branch and open a PR at the end of each phase. Do not bundle phases into one PR — they ship and merge-queue independently.
- Each PR closes nothing on its own; the issue closes when Phase 3 lands (or earlier if Phase 2 hits the < 1 s acceptance number).

---

## Task 0: Set up worktree and verify clean baseline

**Files:** none.

- [ ] **Step 1: Create worktree on a new branch.**

  ```bash
  git -C /Users/aj/Documents/code/moolah-project/moolah-native worktree add \
    .worktrees/perf-519-upcoming-cold-load -b perf/519-upcoming-cold-load
  ```

- [ ] **Step 2: Confirm tests pass on a clean baseline.**

  ```bash
  just -d /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/perf-519-upcoming-cold-load test-mac AnalysisStoreTests TransactionStoreLoadingTests TransactionStoreScheduledViewTests AccountStoreTests
  ```

  Expected: `** TEST SUCCEEDED **`. If any test fails on a clean checkout, stop and investigate before adding measurement instrumentation.

---

## Phase 1 — Measurement (PR 1)

Goal: every later PR can claim a numeric delta against a logged baseline.

### Task 1.1: Add a one-shot first-paint log to the Upcoming card

**Files:**
- Modify: `Features/Analysis/Views/UpcomingTransactionsCard.swift`

The card's `shortTermTransactions` computed property goes from `[]` (during load) to non-empty (when `TransactionStore.load(.scheduledOnly)` finishes). We log the first transition.

- [ ] **Step 1: Wire a launch reference time.**

  Add a private file-scope reference time near the top of the file:

  ```swift
  private let appLaunchTime = ContinuousClock.now
  private let upcomingFirstPaintLogger = Logger(
    subsystem: "com.moolah.app", category: "Perf.UpcomingCard")
  private nonisolated(unsafe) var didLogFirstPaint = false
  ```

  > `nonisolated(unsafe)` is fine here because we only flip the flag once on `MainActor`. If this trips the concurrency-review agent, wrap it in a `@MainActor` static struct holder instead.

  Add `import OSLog` near the existing imports if not already present.

- [ ] **Step 2: Log the first non-empty paint.**

  Modify the body of `UpcomingTransactionsCard` to capture the transition. Replace the existing `transactionList` block:

  ```swift
  if shortTermTransactions.isEmpty {
    emptyState
  } else {
    transactionList
      .task(id: shortTermTransactions.count) {
        guard !didLogFirstPaint else { return }
        didLogFirstPaint = true
        let elapsedMs = (ContinuousClock.now - appLaunchTime).inMilliseconds
        upcomingFirstPaintLogger.log(
          "📊 first-paint of upcoming card: \(elapsedMs)ms (count: \(shortTermTransactions.count))")
      }
  }
  ```

  The `task(id:)` only fires the first time the count becomes non-zero (the flag prevents re-firing on subsequent count changes).

- [ ] **Step 3: Format, build, and confirm the log fires.**

  ```bash
  just -d <worktree> format
  just -d <worktree> format-check
  just -d <worktree> run-mac-with-logs
  # Wait for the dashboard to load (Large Test profile must be the active window).
  grep "first-paint of upcoming card" .agent-tmp/app-logs.txt
  ```

  Expected: one log line with elapsed ms.

- [ ] **Step 4: Commit.**

  ```bash
  git -C <worktree> add Features/Analysis/Views/UpcomingTransactionsCard.swift
  git -C <worktree> commit -m "perf: log first-paint time for upcoming card

  One-shot OSLog line marking when the upcoming-list count first becomes
  non-zero after launch. Measurement instrumentation for #519.

  Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
  ```

### Task 1.2: Split TransactionStore.fetchPage timing

**Files:**
- Modify: `Features/Transactions/TransactionStore.swift` (the `fetchPage` method around line 254-304)

The store currently logs only "Loading…" / "Loaded X transactions". We add the per-step breakdown.

- [ ] **Step 1: Capture `repository.fetch` and `recomputeBalances` timings.**

  Replace the existing `fetchPage` body around the `try await repository.fetch(...)` and `await recomputeBalances()` calls. Insert `ContinuousClock` measurements:

  ```swift
  do {
    let fetchStart = ContinuousClock.now
    let page = try await repository.fetch(
      filter: currentFilter,
      page: currentPage,
      pageSize: pageSize
    )
    let fetchMs = (ContinuousClock.now - fetchStart).inMilliseconds

    guard !Task.isCancelled, myGeneration == loadGeneration else { return }
    rawTransactions.append(contentsOf: page.transactions)
    priorBalance = page.priorBalance
    if currentPage == 0 {
      currentTargetInstrument = page.targetInstrument
    }
    hasMore = page.transactions.count >= pageSize
    currentPage += 1
    loadedCount = rawTransactions.count
    if let total = page.totalCount {
      totalCount = total
    }
    didSucceedLoadForCurrentFilter = true

    let recomputeStart = ContinuousClock.now
    await recomputeBalances()
    let recomputeMs = (ContinuousClock.now - recomputeStart).inMilliseconds

    if fetchMs + recomputeMs > 100 {
      logger.info(
        "fetchPage took \(fetchMs + recomputeMs)ms (repo.fetch: \(fetchMs)ms, recomputeBalances: \(recomputeMs)ms, count: \(page.transactions.count))"
      )
    } else {
      logger.debug(
        "Loaded \(page.transactions.count) transactions (total: \(self.rawTransactions.count))")
    }
  } catch {
    ...
  }
  ```

  The 100 ms gate keeps the `.info` line silent on small fetches (test runs, etc).

- [ ] **Step 2: Build and confirm it compiles.**

  ```bash
  just -d <worktree> build-mac
  ```

  Expected: `** BUILD SUCCEEDED **`, no warnings.

- [ ] **Step 3: Run the existing TransactionStore tests as a smoke check.**

  ```bash
  just -d <worktree> test-mac TransactionStoreLoadingTests TransactionStoreCRUDTests TransactionStoreScheduledViewTests TransactionStoreLoadRaceTests
  ```

  Expected: all green.

- [ ] **Step 4: Cold-launch the app, confirm the new log appears.**

  ```bash
  pkill -f "Moolah.app/Contents/MacOS/Moolah" 2>/dev/null
  sleep 2
  just -d <worktree> run-mac-with-logs
  # Wait until the dashboard renders.
  grep "fetchPage took" .agent-tmp/app-logs.txt
  ```

  Expected: at least one line of the form
  `fetchPage took XXXms (repo.fetch: YYYms, recomputeBalances: ZZms, count: 36)`.

  **Record YYY (repo.fetch) and ZZZ (recomputeBalances) — these are the Phase 2 / Phase 3 baseline.**

- [ ] **Step 5: Commit.**

  ```bash
  git -C <worktree> add Features/Transactions/TransactionStore.swift
  git -C <worktree> commit -m "perf: split fetchPage timing into repo.fetch and recomputeBalances

  Separates the SwiftData fetch cost from the conversion/balance cost so a
  PR that touches one can prove it didn't accidentally regress the other.
  Logs at .info only when total > 100ms to avoid noise in tests.

  Measurement instrumentation for #519.

  Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
  ```

### Task 1.3: Split AccountRepo.fetchAll signposts

**Files:**
- Modify: `Backends/CloudKit/Repositories/CloudKitAccountRepository.swift`
- Modify: `Backends/CloudKit/Repositories/CloudKitAccountRepository+Positions.swift`

The current log line `AccountRepo.fetchAll took 900ms off-main (records: 2ms, positions: 898ms, 28 accounts)` lumps the leg fetch and the in-Swift compute. We need them separate so Phase 3 has a clean target.

- [ ] **Step 1: Add a sub-signpost name to `Signposts.swift` if it doesn't already exist.**

  ```bash
  grep "accountRepo.legs" Backends/CloudKit/Repositories/Signposts.swift
  ```

  If absent, add new signpost names. Otherwise this step is a no-op.

- [ ] **Step 2: Wrap the two phases of `fetchAll` in distinct signposts and log their times.**

  In `CloudKitAccountRepository.fetchAll`, change the section between `let positionStart = …` and `let positionMs = …` to:

  ```swift
  let positionStart = ContinuousClock.now
  let legsStart = ContinuousClock.now
  let (_, allLegs) = try fetchNonScheduledLegs(context: bgContext)
  let legsMs = (ContinuousClock.now - legsStart).inMilliseconds

  let instrumentsStart = ContinuousClock.now
  let instruments = try fetchInstrumentMap(context: bgContext)
  let instrumentsMs = (ContinuousClock.now - instrumentsStart).inMilliseconds

  let computeStart = ContinuousClock.now
  let allPositions = computePositions(from: allLegs, instruments: instruments)
  let computeMs = (ContinuousClock.now - computeStart).inMilliseconds

  let positionMs = (ContinuousClock.now - positionStart).inMilliseconds
  ```

  Then update the log to surface the breakdown:

  ```swift
  if totalMs > 100 {
    logger.info(
      "AccountRepo.fetchAll took \(totalMs)ms off-main (records: \(fetchMs)ms, legs.fetch: \(legsMs)ms, instruments.fetch: \(instrumentsMs)ms, positions.compute: \(computeMs)ms, \(records.count) accounts, \(allLegs.count) legs)"
    )
  }
  ```

- [ ] **Step 3: Format and run tests.**

  ```bash
  just -d <worktree> format && just -d <worktree> format-check
  just -d <worktree> test-mac AccountRepositoryContractTests
  ```

  Expected: all tests pass; format-check clean.

- [ ] **Step 4: Cold-launch and capture the breakdown.**

  ```bash
  pkill -f "Moolah.app/Contents/MacOS/Moolah" 2>/dev/null; sleep 2
  just -d <worktree> run-mac-with-logs
  grep "AccountRepo.fetchAll took" .agent-tmp/app-logs.txt
  ```

  **Record `legs.fetch` and `positions.compute` — Phase 3's targets.**

- [ ] **Step 5: Commit and open the PR.**

  ```bash
  git -C <worktree> add Backends/CloudKit/Repositories/CloudKitAccountRepository.swift Backends/CloudKit/Repositories/CloudKitAccountRepository+Positions.swift
  git -C <worktree> commit -m "perf: split AccountRepo.fetchAll log into legs.fetch / positions.compute

  Phase 3 of #519 will optimise the fetchNonScheduledLegs full-table scan;
  this surfaces the pre-fix number so the impact is provable.

  Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"

  git -C <worktree> push -u origin perf/519-upcoming-cold-load
  ```

  Open the PR with `gh pr create --base main`, body referencing #519, summary listing tasks 1.1–1.3 and the measured baseline numbers.

  After review approval: `~/.claude/skills/merge-queue/scripts/merge-queue-ctl.sh add <PR>`.

  **Wait for the PR to merge before starting Phase 2.**

---

## Phase 2 — Sequence the cold task (PR 2)

Goal: when the four cold-launch stores all want the SwiftData SQL connection, the small upcoming-list fetch wins. Expected impact: first-paint < 1 s.

### Task 2.1: Reshape `AnalysisView.task` to await the upcoming load before kicking the rest

**Files:**
- Modify: `Features/Analysis/Views/AnalysisView.swift` (the `.task` block around line 68)

Today both loads use `async let` which starts them concurrently. We need the upcoming load to finish first.

- [ ] **Step 1: Restart from a fresh worktree off the freshly-merged main.**

  ```bash
  git -C /Users/aj/Documents/code/moolah-project/moolah-native fetch origin main
  git -C /Users/aj/Documents/code/moolah-project/moolah-native worktree add \
    .worktrees/perf-519-sequence-upcoming -b perf/519-sequence-upcoming origin/main
  ```

- [ ] **Step 2: Replace the `.task` block.**

  Existing code:

  ```swift
  .task {
    async let transactions: Void = transactionStore.load(
      filter: TransactionFilter(scheduled: .scheduledOnly))
    async let analysis: Void = store.loadAll()
    _ = await (transactions, analysis)
  }
  ```

  Replace with:

  ```swift
  .task {
    // Win the SwiftData SQL connection race for the upcoming-card data
    // before the heavier analysis loads start, so the visible card paints
    // in well under a second on cold launch. The analysis bundle still
    // runs concurrently with itself; only the *upcoming* sequence is
    // serialised in front. See plans/2026-04-27-upcoming-card-cold-load-plan.md.
    await transactionStore.load(filter: TransactionFilter(scheduled: .scheduledOnly))
    await store.loadAll()
  }
  ```

  > Why not run `analysis` at `.utility` priority instead? Because once the upcoming load is awaited first, the analysis load can use the full main-actor and SQL connection without competing with the upcoming card. Sequential is simpler, and the upcoming card is the only thing on screen above the fold for the first ~150 ms anyway.

- [ ] **Step 3: Confirm the existing AnalysisView tests still pass.**

  ```bash
  just -d <worktree> test-mac AnalysisStoreTests AnalysisLoadAllTests TransactionStoreScheduledViewTests
  ```

  Expected: all green. (No new test for this task — it's a sequencing change in a view, validated by the live measurement below.)

- [ ] **Step 4: Cold-launch and read the first-paint log.**

  ```bash
  pkill -f "Moolah.app/Contents/MacOS/Moolah" 2>/dev/null; sleep 2
  just -d <worktree> run-mac-with-logs
  grep -E "first-paint of upcoming card|fetchPage took|AccountRepo.fetchAll" .agent-tmp/app-logs.txt
  ```

  **Acceptance gate:** `first-paint of upcoming card: Xms` must be below **1500 ms**. (We're aiming for < 1000 ms across the full plan; Phase 2 alone is expected to land around 600–900 ms.)

  If the number is above 1500 ms, do **not** proceed — investigate. The most likely culprit: `recomputeBalances` is doing more work than expected, or the `repository.fetch` for scheduled-only is contending for something other than the SQL connection. Use the per-step `fetchPage took` log added in Phase 1 to diagnose.

- [ ] **Step 5: Format, commit, push, PR, queue.**

  ```bash
  just -d <worktree> format && just -d <worktree> format-check
  git -C <worktree> add Features/Analysis/Views/AnalysisView.swift
  git -C <worktree> commit -m "perf: sequence upcoming-list load before analysis bundle

  AnalysisView.task awaits transactionStore.load(.scheduledOnly) before
  starting analysisStore.loadAll(). The scheduled-only fetch is small
  (~50ms with #517), so blocking the analysis bundle behind it costs
  little — but it lets the upcoming card paint in < 1s on cold launch by
  winning the SwiftData SQL connection race against the AccountRepo
  positions reduce.

  Measured first-paint on Large Test: <BASELINE>ms → <NEW>ms.

  Refs #519.

  Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
  git -C <worktree> push -u origin perf/519-sequence-upcoming
  gh -R ajsutton/moolah-native pr create --base main --head perf/519-sequence-upcoming \
    --title "perf: sequence upcoming-list load before analysis bundle" \
    --body "Phase 2 of #519. See plans/2026-04-27-upcoming-card-cold-load-plan.md.

  Measured first-paint of upcoming card on Large Test cold launch:
  - Before: <BASELINE>ms
  - After: <NEW>ms

  Wait for PR to merge before starting Phase 3."
  ~/.claude/skills/merge-queue/scripts/merge-queue-ctl.sh add <PR>
  ```

  Replace `<BASELINE>` and `<NEW>` with the actual measured numbers.

  **If first-paint after Phase 2 is already < 1000 ms, decide whether Phase 3 is still worth doing.** Phase 3 helps the rest of the dashboard (and any future view that runs concurrently with positions); but if the user-facing pain is solved and review bandwidth is tight, defer.

---

## Phase 3 — Cut `fetchNonScheduledLegs` cost (PR 3, conditional)

Goal: stop the AccountRepo from holding the SwiftData SQL connection for ~900 ms by avoiding the full-table-scan + Swift-side filter.

The current implementation:

```swift
func fetchNonScheduledLegs(context: ModelContext) throws -> (Set<UUID>, [TransactionLegRecord]) {
  let scheduledDescriptor = FetchDescriptor<TransactionRecord>(
    predicate: #Predicate { $0.recurPeriod != nil }
  )
  let scheduledIds = Set(try context.fetch(scheduledDescriptor).map(\.id))

  let legDescriptor = FetchDescriptor<TransactionLegRecord>()
  let allLegs = try context.fetch(legDescriptor).filter {
    !scheduledIds.contains($0.transactionId)
  }
  return (scheduledIds, allLegs)
}
```

It pulls all 20,076 legs into Swift memory and filters in code. With Large Test, only ~16 of those are scheduled — so we materialise 20,060 useless legs through SwiftData's persisted-property machinery on every `fetchAll`.

### Task 3.1: Push the scheduled exclusion into the SwiftData predicate

**Files:**
- Modify: `Backends/CloudKit/Repositories/CloudKitAccountRepository+Positions.swift`
- Test: `MoolahTests/Domain/AccountRepositoryContractTests.swift` (extend an existing test, or add one — see Step 1)

- [ ] **Step 1: Restart from a fresh worktree off the freshly-merged main.**

  ```bash
  git -C /Users/aj/Documents/code/moolah-project/moolah-native fetch origin main
  git -C /Users/aj/Documents/code/moolah-project/moolah-native worktree add \
    .worktrees/perf-519-cut-leg-scan -b perf/519-cut-leg-scan origin/main
  ```

- [ ] **Step 2: Write the failing TDD test.**

  In `MoolahTests/Domain/AccountRepositoryContractTests.swift` (or a new ordering / scheduled-exclusion sibling file if the contract test is already long), add a test that:

  1. Inserts one scheduled (recurring) transaction with a leg on account A.
  2. Inserts one non-scheduled transaction with a leg on account A.
  3. Calls `repository.fetchAll()`.
  4. Asserts account A's `Position` reflects only the non-scheduled leg.

  Concrete shape:

  ```swift
  @Test("fetchAll excludes scheduled-transaction legs from account positions")
  func testFetchAllExcludesScheduledLegs() async throws {
    let (backend, _) = try TestBackend.makeForTests()
    let accountId = UUID()
    let account = Account(id: accountId, name: "Test", type: .bank, instrument: .defaultTestInstrument)
    _ = try await backend.accounts.create(account)

    // Scheduled transaction: must not contribute to the position.
    _ = try await backend.transactions.create(
      Transaction(
        id: UUID(), date: Date(), payee: "Scheduled", recurPeriod: .month, recurEvery: 1,
        legs: [TransactionLeg(accountId: accountId, instrument: .defaultTestInstrument, quantity: -100, type: .expense)]))

    // Non-scheduled transaction: contributes -25.
    _ = try await backend.transactions.create(
      Transaction(
        id: UUID(), date: Date(), payee: "Real",
        legs: [TransactionLeg(accountId: accountId, instrument: .defaultTestInstrument, quantity: -25, type: .expense)]))

    let accounts = try await backend.accounts.fetchAll()
    let fetched = try #require(accounts.first { $0.id == accountId })
    let position = try #require(fetched.positions.first)
    #expect(position.quantity == -25)
  }
  ```

  > Verify the existing contract suite doesn't already cover this. If it does, skip writing the test and rely on the existing one — but record which test it is in your PR body.

- [ ] **Step 3: Run the test against unchanged code to confirm it passes (it should — the in-Swift filter is correct, just slow).**

  ```bash
  just -d <worktree> test-mac AccountRepositoryContractTests/testFetchAllExcludesScheduledLegs
  ```

  Expected: PASS. This is a pinning test — it asserts the *contract* the perf change must preserve.

- [ ] **Step 4: Replace `fetchNonScheduledLegs` with a single predicated query.**

  The fix exploits the fact that `TransactionLegRecord.transactionId` is a UUID column — we can `NOT IN` a Set of scheduled ids inside the predicate:

  ```swift
  func fetchNonScheduledLegs(context: ModelContext) throws -> (
    Set<UUID>, [TransactionLegRecord]
  ) {
    let scheduledDescriptor = FetchDescriptor<TransactionRecord>(
      predicate: #Predicate { $0.recurPeriod != nil }
    )
    let scheduledIds = Set(try context.fetch(scheduledDescriptor).map(\.id))

    let legDescriptor: FetchDescriptor<TransactionLegRecord>
    if scheduledIds.isEmpty {
      legDescriptor = FetchDescriptor<TransactionLegRecord>()
    } else {
      legDescriptor = FetchDescriptor<TransactionLegRecord>(
        predicate: #Predicate { !scheduledIds.contains($0.transactionId) }
      )
    }
    let allLegs = try context.fetch(legDescriptor)
    return (scheduledIds, allLegs)
  }
  ```

  **If this doesn't compile** because SwiftData rejects `Set<UUID>.contains` inside `#Predicate`: fall back to fetching all leg ids first, computing the difference in Swift, then refetching by id. Pseudocode for the fallback:

  ```swift
  // Fetch only the transactionId column for all legs.
  let allLegIds = try context.fetchIdentifiers(FetchDescriptor<TransactionLegRecord>())
  // (or fetch lightweight (id, transactionId) tuples via a custom view)
  ```

  > SwiftData's `FetchDescriptor` does not yet have first-class projection. If the predicate path doesn't work, the cheapest correct fallback is: keep the second `context.fetch(legDescriptor)` over **all** legs, but stop calling `record.toDomain` on the scheduled ones (we already do — this method only returns records). The actual cost driver is the `context.fetch` materialising 20,076 records into memory; without predicate push-down, the only other lever is to add a denormalised `isScheduled: Bool` column on `TransactionLegRecord` that mirrors the parent's `recurPeriod != nil`. That's a bigger change — file a follow-up issue and revert this task to a no-op if the predicate path doesn't pan out.

- [ ] **Step 5: Run the contract test (unchanged code → after change must still pass).**

  ```bash
  just -d <worktree> test-mac AccountRepositoryContractTests
  ```

  Expected: all pass.

- [ ] **Step 6: Run the wider suite that exercises positions.**

  ```bash
  just -d <worktree> test-mac AccountRepositoryContractTests AccountStoreTests AnalysisDailyBalancesTests AnalysisCategoryBalancesTests
  ```

  Expected: all pass.

- [ ] **Step 7: Cold-launch the app and read the new numbers.**

  ```bash
  pkill -f "Moolah.app/Contents/MacOS/Moolah" 2>/dev/null; sleep 2
  just -d <worktree> run-mac-with-logs
  grep -E "first-paint of upcoming card|fetchPage took|AccountRepo.fetchAll" .agent-tmp/app-logs.txt
  ```

  **Acceptance gates:**
  - `AccountRepo.fetchAll` log: `legs.fetch` should drop **substantially** (target: < 200 ms vs ~700 ms baseline).
  - `first-paint of upcoming card` should be < **1000 ms**, hitting the plan's overall acceptance.
  - No test regressions.

- [ ] **Step 8: Format, commit, push, PR, queue.**

  ```bash
  just -d <worktree> format && just -d <worktree> format-check
  git -C <worktree> add Backends/CloudKit/Repositories/CloudKitAccountRepository+Positions.swift MoolahTests/Domain/AccountRepositoryContractTests.swift
  git -C <worktree> commit -m "perf: predicate-filter scheduled legs out of fetchNonScheduledLegs

  Stop materialising all 20k legs through SwiftData's persisted-property
  machinery just to filter ~16 scheduled ones out in Swift. Push the
  exclusion into the FetchDescriptor predicate so SQLite returns only the
  legs we actually need.

  Measured on Large Test cold launch:
  - AccountRepo.fetchAll legs.fetch: <BEFORE>ms → <AFTER>ms
  - first-paint of upcoming card: <BEFORE>ms → <AFTER>ms

  Final phase of #519. Closes #519.

  Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
  git -C <worktree> push -u origin perf/519-cut-leg-scan
  gh -R ajsutton/moolah-native pr create --base main --head perf/519-cut-leg-scan \
    --title "perf: predicate-filter scheduled legs out of fetchNonScheduledLegs" \
    --body "Phase 3 of #519, closing the issue. See plans/2026-04-27-upcoming-card-cold-load-plan.md."
  ~/.claude/skills/merge-queue/scripts/merge-queue-ctl.sh add <PR>
  ```

---

## Phase 4 — Verify and clean up

### Task 4.1: Final cold-launch verification on main

- [ ] **Step 1: After all three PRs merge, pull main in the original checkout.**

  ```bash
  git -C /Users/aj/Documents/code/moolah-project/moolah-native fetch origin main
  git -C /Users/aj/Documents/code/moolah-project/moolah-native checkout main
  git -C /Users/aj/Documents/code/moolah-project/moolah-native pull --ff-only origin main
  ```

- [ ] **Step 2: Cold-launch against Large Test profile and capture the full log.**

  ```bash
  pkill -f "Moolah.app/Contents/MacOS/Moolah" 2>/dev/null; sleep 2
  rm -f .agent-tmp/app-logs.txt
  just run-mac-with-logs
  # Wait for the dashboard to appear.
  grep -E "first-paint of upcoming card|fetchPage took|AccountRepo.fetchAll" .agent-tmp/app-logs.txt
  ```

  **Final acceptance:** `first-paint of upcoming card` < **1000 ms**.

- [ ] **Step 3: Move the plan to completed.**

  ```bash
  git -C /Users/aj/Documents/code/moolah-project/moolah-native worktree add \
    .worktrees/move-519-plan -b chore/move-519-plan-to-completed
  git -C <worktree> mv plans/2026-04-27-upcoming-card-cold-load-plan.md plans/completed/
  git -C <worktree> commit -m "chore: archive completed #519 plan"
  git -C <worktree> push -u origin chore/move-519-plan-to-completed
  gh -R ajsutton/moolah-native pr create --base main --head chore/move-519-plan-to-completed \
    --title "chore: archive completed #519 plan" \
    --body "Plan completed; first-paint of upcoming card now <1000ms on Large Test cold launch."
  ~/.claude/skills/merge-queue/scripts/merge-queue-ctl.sh add <PR>
  ```

- [ ] **Step 4: Clean up worktrees.**

  ```bash
  git -C /Users/aj/Documents/code/moolah-project/moolah-native worktree list
  # For each merged worktree:
  git -C /Users/aj/Documents/code/moolah-project/moolah-native worktree remove .worktrees/perf-519-upcoming-cold-load
  git -C /Users/aj/Documents/code/moolah-project/moolah-native worktree remove .worktrees/perf-519-sequence-upcoming
  git -C /Users/aj/Documents/code/moolah-project/moolah-native worktree remove .worktrees/perf-519-cut-leg-scan
  git -C /Users/aj/Documents/code/moolah-project/moolah-native worktree remove .worktrees/move-519-plan
  ```

- [ ] **Step 5: Decide whether the measurement logs should stay.**

  Three options for the `📊` first-paint log and the `fetchPage took` / `AccountRepo.fetchAll took` info logs:

  - **Keep them** (recommended). They're cheap, gated by a 100 ms threshold, and re-pay their cost the next time someone profiles the dashboard.
  - **Demote to debug.** If they're noisy in normal day-to-day use, change `.info` to `.debug`.
  - **Remove them.** Only if the on-disk log volume is a real concern — but at < 5 lines per cold launch this is unlikely.

  The default plan recommendation: keep them. They're the contract for any future #519-shaped issue.

---

## Self-Review checklist

- Spec coverage: each phase maps to one of the four levers in the issue (instrument → sequence → reduce contention → verify). ✓
- No placeholders. Each task has exact file paths, full code, exact `just` commands, and an expected outcome. ✓
- Type consistency: `ContinuousClock.now` (not `.uptime`), `inMilliseconds` extension (already exists in this codebase — verify with `grep -r "inMilliseconds" .` before Task 1.2 starts; if not present, add a small `extension Duration` helper as part of Task 1.2). ✓
- Acceptance gates are numeric and per-phase: Phase 2 < 1500 ms, Phase 3 / Phase 4 < 1000 ms. ✓
