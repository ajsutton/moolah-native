# Responsive Investment Load (Plan A — Responsiveness) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the investment account screen interactive immediately — the transactions list and positions table render without waiting for the historic chart, which loads behind a spinner.

**Architecture:** Split `InvestmentStore`'s monolithic `positionsViewInput` into a fast phase 1 (positions + cost basis, no history) and a slow phase 2 (`PositionsHistoryBuilder` series, reusing transactions cached by phase 1). `InvestmentAccountView` flips its full-screen gate after phase 1; `PositionsView` shows a chart-area spinner while `PositionsViewInput.historyLoading` is true. No price-cache changes here — that is Plan B.

**Tech Stack:** Swift 6, SwiftUI, Swift Testing (`import Testing`), GRDB-backed `TestBackend`. Build/test via `just`.

**Scope note:** This is Plan A of two. Plan B (sorted-array price/rate caches) is independent and tracked separately. This plan delivers the responsiveness win even with the current (slow) cache — the slow build just moves off the critical path.

**Spec:** `plans/2026-05-16-responsive-investment-load-design.md`

---

### Task 1: `PositionsViewInput.historyLoading` + `applyingHistory`

**Files:**
- Modify: `Domain/Models/PositionsViewInput.swift`
- Test: `MoolahTests/Domain/PositionsViewInputHistoryLoadingTests.swift` (create)

- [ ] **Step 1: Write the failing test**

Create `MoolahTests/Domain/PositionsViewInputHistoryLoadingTests.swift`:

```swift
import Foundation
import Testing

@testable import Moolah

@Suite("PositionsViewInput history loading")
struct PositionsViewInputHistoryLoadingTests {
  private let aud = Instrument.AUD

  @Test("historyLoading defaults to false")
  func defaultsFalse() {
    let input = PositionsViewInput(
      title: "X", hostCurrency: aud, positions: [], historicalValue: nil)
    #expect(input.historyLoading == false)
  }

  @Test("historyLoading can be set true via the designated init")
  func canBeTrue() {
    let input = PositionsViewInput(
      title: "X", hostCurrency: aud, positions: [], historicalValue: nil,
      historyLoading: true)
    #expect(input.historyLoading == true)
  }

  @Test("applyingHistory merges the series and clears the loading flag")
  func applyingHistoryMergesAndClears() {
    let loading = PositionsViewInput(
      title: "X", hostCurrency: aud, positions: [], historicalValue: nil,
      hasAnyHistoricalActivity: true, alwaysShowsFullSurface: true,
      historyLoading: true)
    let series = HistoricalValueSeries(
      perInstrument: [:],
      total: [
        HistoricalValueSeries.Point(
          date: Date(), value: 100, cost: 80, contributions: nil)
      ])

    let merged = loading.applyingHistory(series)

    #expect(merged.historyLoading == false)
    #expect(merged.historicalValue != nil)
    #expect(merged.hasAnyHistoricalActivity == true)
    #expect(merged.alwaysShowsFullSurface == true)
    #expect(merged.title == "X")
  }

  @Test("applyingHistory with nil keeps no series and clears loading")
  func applyingNilClearsLoading() {
    let loading = PositionsViewInput(
      title: "X", hostCurrency: aud, positions: [], historicalValue: nil,
      historyLoading: true)

    let merged = loading.applyingHistory(nil)

    #expect(merged.historyLoading == false)
    #expect(merged.historicalValue == nil)
  }
}
```

> Note: confirm `HistoricalValueSeries` / `HistoricalValueSeries.Point` initializer argument labels against `Domain/Models/HistoricalValueSeries.swift` when writing the test; the snippet uses `perInstrument:` / `total:` and `Point(date:value:cost:contributions:)` (the shape `PositionsHistoryBuilder` builds). Adjust labels if the source differs — do not change the production types.

- [ ] **Step 2: Run test to verify it fails**

Run: `just test-mac PositionsViewInputHistoryLoadingTests 2>&1 | tee .agent-tmp/t1.txt`
Expected: FAIL — `value of type 'PositionsViewInput' has no member 'historyLoading'` / `no member 'applyingHistory'`.

- [ ] **Step 3: Add the field, init parameter, and helper**

In `Domain/Models/PositionsViewInput.swift`, add the stored property after `alwaysShowsFullSurface` (after line 41):

```swift
  /// `true` while phase 2 (the historic-series build) is still running.
  /// Phase 1 returns the input with this `true`; `applyingHistory(_:)`
  /// clears it once the series lands (or fails). `PositionsView` renders
  /// a chart-area spinner while it is `true`. Defaults to `false` so
  /// non-investment callers and previews are unaffected.
  let historyLoading: Bool
```

Add `historyLoading: Bool = false` as the final parameter of the designated init (after `alwaysShowsFullSurface: Bool = false`) and assign it. The init becomes:

```swift
  init(
    title: String,
    hostCurrency: Instrument,
    positions: [ValuedPosition],
    historicalValue: HistoricalValueSeries?,
    performance: AccountPerformance? = nil,
    hasAnyHistoricalActivity: Bool = false,
    alwaysShowsFullSurface: Bool = false,
    historyLoading: Bool = false
  ) {
    self.title = title
    self.hostCurrency = hostCurrency
    self.positions = positions
    self.historicalValue = historicalValue
    self.performance = performance
    self.hasAnyHistoricalActivity = hasAnyHistoricalActivity
    self.alwaysShowsFullSurface = alwaysShowsFullSurface
    self.historyLoading = historyLoading
  }
```

Add this method inside the struct body, after `rendersNothing` (after line 159):

```swift
  /// Returns a copy with the historic series merged in and the loading
  /// flag cleared. Used by the two-phase investment load: phase 1 returns
  /// the input with `historyLoading == true`; phase 2 calls this once the
  /// `PositionsHistoryBuilder` series is ready (or `nil` on failure).
  func applyingHistory(_ series: HistoricalValueSeries?) -> PositionsViewInput {
    PositionsViewInput(
      title: title,
      hostCurrency: hostCurrency,
      positions: positions,
      historicalValue: series,
      performance: performance,
      hasAnyHistoricalActivity: hasAnyHistoricalActivity,
      alwaysShowsFullSurface: alwaysShowsFullSurface,
      historyLoading: false)
  }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `just test-mac PositionsViewInputHistoryLoadingTests 2>&1 | tee .agent-tmp/t1.txt`
Expected: PASS (all 4 tests).

- [ ] **Step 5: Commit**

```bash
git -C "$PWD" add Domain/Models/PositionsViewInput.swift MoolahTests/Domain/PositionsViewInputHistoryLoadingTests.swift
git -C "$PWD" commit -m "feat(positions): add PositionsViewInput.historyLoading + applyingHistory"
```

---

### Task 2: `InvestmentStore.loadedTransactions` cache state

**Files:**
- Modify: `Features/Investments/InvestmentStore.swift`

- [ ] **Step 1: Add the stored property**

In `Features/Investments/InvestmentStore.swift`, add after `loadedHostCurrency` (after line 29):

```swift
  /// Transactions fetched by phase 1 (`loadPositionsInput`) and reused by
  /// phase 2 (`historicalSeries`) so the series build does not re-fetch.
  /// Implicitly scoped to `loadedAccountId`; overwritten on each phase-1
  /// load.
  private(set) var loadedTransactions: [Transaction] = []
```

- [ ] **Step 2: Add the setter**

Add next to the other setters (after `setLoadedHostCurrency`, after line 197):

```swift
  func setLoadedTransactions(_ transactions: [Transaction]) {
    loadedTransactions = transactions
  }
```

- [ ] **Step 3: Build to verify it compiles**

Run: `just build-mac 2>&1 | tail -5`
Expected: build succeeds (no callers yet — this is plumbing for Task 3).

- [ ] **Step 4: Commit**

```bash
git -C "$PWD" add Features/Investments/InvestmentStore.swift
git -C "$PWD" commit -m "feat(investments): cache loadedTransactions on InvestmentStore"
```

---

### Task 3: Split `positionsViewInput` into phase 1 + phase 2

**Files:**
- Modify: `Features/Investments/InvestmentStore+PositionsInput.swift:39-88`
- Test: `MoolahTests/Features/InvestmentStoreTwoPhaseLoadTests.swift` (create)

- [ ] **Step 1: Write the failing test**

Create `MoolahTests/Features/InvestmentStoreTwoPhaseLoadTests.swift`:

```swift
import Foundation
import Testing

@testable import Moolah

@MainActor
@Suite("InvestmentStore two-phase load")
struct InvestmentStoreTwoPhaseLoadTests {
  let aud = Instrument.AUD
  let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")

  private func makeStoreWithTrade() async throws -> (InvestmentStore, Account) {
    let (backend, _) = try TestBackend.create()
    let store = InvestmentStore(
      repository: backend.investments,
      transactionRepository: backend.transactions,
      conversionService: backend.conversionService
    )
    let account = Account(
      name: "Brokerage", type: .investment, instrument: aud,
      valuationMode: .calculatedFromTrades)
    _ = try await backend.accounts.create(
      account, openingBalance: InstrumentAmount(quantity: 0, instrument: aud))
    _ = try await backend.transactions.create(
      Transaction(
        date: Date(),
        legs: [
          TransactionLeg(accountId: account.id, instrument: bhp, quantity: 100, type: .trade),
          TransactionLeg(accountId: account.id, instrument: aud, quantity: -4_000, type: .trade),
        ]
      )
    )
    return (store, account)
  }

  @Test("phase 1 returns positions+cost basis, no series, history loading")
  func phase1FastInput() async throws {
    let (store, account) = try await makeStoreWithTrade()

    let input = try await store.loadPositionsInput(
      account: account, profileCurrency: aud)

    #expect(input.historicalValue == nil)
    #expect(input.historyLoading == true)
    #expect(input.positions.contains(where: { $0.instrument == bhp }))
    let bhpRow = input.positions.first(where: { $0.instrument == bhp })!
    #expect(bhpRow.costBasis == InstrumentAmount(quantity: 4_000, instrument: aud))
    #expect(store.loadedTransactions.count == 1)
  }

  @Test("historicalSeries is nil without a transaction repository")
  func historicalSeriesNilWithoutRepo() async throws {
    let (backend, _) = try TestBackend.create()
    let store = InvestmentStore(
      repository: backend.investments,
      transactionRepository: nil,
      conversionService: backend.conversionService
    )
    let series = await store.historicalSeries(range: .all)
    #expect(series == nil)
  }

  @Test("composed positionsViewInput still returns a built input, not loading")
  func composedStillWorks() async throws {
    let (store, account) = try await makeStoreWithTrade()
    await store.loadAllData(account: account, profileCurrency: aud)

    let input = try await store.positionsViewInput(
      title: account.name, range: .threeMonths)

    #expect(input.historyLoading == false)
    #expect(input.positions.contains(where: { $0.instrument == bhp }))
  }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `just test-mac InvestmentStoreTwoPhaseLoadTests 2>&1 | tee .agent-tmp/t3.txt`
Expected: FAIL — `value of type 'InvestmentStore' has no member 'loadPositionsInput'` / `'historicalSeries'`.

- [ ] **Step 3: Replace `positionsViewInput` with the split implementation**

In `Features/Investments/InvestmentStore+PositionsInput.swift`, replace the entire `positionsViewInput(title:range:)` method (lines 31–88, the doc comment through the closing brace of the method) with:

```swift
  /// Phase 1 of the two-phase load: runs `loadAllData` then assembles the
  /// positions/cost-basis half of the input. No historic series — the
  /// returned input has `historicalValue == nil` and (for hosts that
  /// will build a series) `historyLoading == true`. The caller runs
  /// phase 2 (`historicalSeries`) off the critical path.
  func loadPositionsInput(
    account: Account,
    profileCurrency: Instrument
  ) async throws -> PositionsViewInput {
    await loadAllData(account: account, profileCurrency: profileCurrency)
    return try await positionsInputWithoutHistory(title: account.name)
  }

  /// Builds the positions + cost-basis half of `PositionsViewInput` from
  /// the already-loaded `valuedPositions` and a fresh transaction fetch.
  /// Caches the fetched transactions on the store so phase 2 reuses them.
  /// `historicalValue` is `nil`; `historyLoading` is `true` whenever a
  /// series build will follow (a transaction repository exists).
  func positionsInputWithoutHistory(
    title: String
  ) async throws -> PositionsViewInput {
    guard let transactionRepository else {
      let hostCurrency = loadedHostCurrency ?? .AUD
      return PositionsViewInput(
        title: title,
        hostCurrency: hostCurrency,
        positions: valuedPositions,
        historicalValue: nil,
        performance: accountPerformance,
        alwaysShowsFullSurface: true)
    }

    let txns: [Transaction]
    do {
      txns = try await fetchAllTransactions(
        repository: transactionRepository,
        accountId: loadedAccountId ?? UUID())
    } catch is CancellationError {
      setLoadedTransactions([])
      throw CancellationError()
    } catch {
      logger.warning(
        "fetchAllTransactions failed, cost basis will be empty: \(error.localizedDescription, privacy: .public)"
      )
      txns = []
    }
    setLoadedTransactions(txns)
    let hostCurrency = loadedHostCurrency ?? valuedPositions.first?.value?.instrument ?? .AUD
    let costSnapshot = await costBasisSnapshot(
      transactions: txns, hostCurrency: hostCurrency)
    let rowsWithCost = applyingCostBasis(costSnapshot, hostCurrency: hostCurrency)

    return PositionsViewInput(
      title: title,
      hostCurrency: hostCurrency,
      positions: rowsWithCost,
      historicalValue: nil,
      performance: accountPerformance,
      hasAnyHistoricalActivity: Self.hasAnyTradeLeg(
        in: txns, accountId: loadedAccountId, hostCurrency: hostCurrency),
      alwaysShowsFullSurface: true,
      historyLoading: true)
  }

  /// Phase 2 of the two-phase load: builds the historic chart series from
  /// the transactions cached by phase 1. Returns `nil` for hosts without
  /// a transaction repository (previews / embeddings). Range-only — does
  /// not re-fetch transactions or re-run `loadAllData`.
  func historicalSeries(
    range: PositionsTimeRange
  ) async -> HistoricalValueSeries? {
    guard transactionRepository != nil else { return nil }
    let hostCurrency = loadedHostCurrency ?? valuedPositions.first?.value?.instrument ?? .AUD
    return await PositionsHistoryBuilder(conversionService: conversionService).build(
      transactions: loadedTransactions,
      accountId: loadedAccountId ?? UUID(),
      hostCurrency: hostCurrency,
      range: range
    )
  }

  /// Backwards-compatible composition of phase 1 + phase 2. Retained so
  /// existing callers/tests (`loadAndBuildPositionsInput`, store tests)
  /// keep returning a fully-built input. The two-phase view path calls
  /// `loadPositionsInput` / `historicalSeries` directly instead.
  func positionsViewInput(
    title: String,
    range: PositionsTimeRange
  ) async throws -> PositionsViewInput {
    let base = try await positionsInputWithoutHistory(title: title)
    let series = await historicalSeries(range: range)
    return base.applyingHistory(series)
  }
```

> `loadAndBuildPositionsInput` (lines 22–29) is unchanged: it still calls `loadAllData` then the composed `positionsViewInput`, which now routes through the split internally. `applyingCostBasis`, `hasAnyTradeLeg`, `fetchAllTransactions`, `costBasisSnapshot` are unchanged and remain in this file.

- [ ] **Step 4: Run test to verify it passes**

Run: `just test-mac InvestmentStoreTwoPhaseLoadTests InvestmentStorePositionsInputTests 2>&1 | tee .agent-tmp/t3.txt`
Expected: PASS — new suite passes and the pre-existing `InvestmentStorePositionsInputTests` still passes (composed-path regression).

- [ ] **Step 5: Commit**

```bash
git -C "$PWD" add Features/Investments/InvestmentStore+PositionsInput.swift MoolahTests/Features/InvestmentStoreTwoPhaseLoadTests.swift
git -C "$PWD" commit -m "feat(investments): split positionsViewInput into fast phase 1 + phase 2"
```

---

### Task 4: `PositionsView` chart-loading placeholder

**Files:**
- Modify: `Shared/Views/Positions/PositionsView.swift:35-43`

- [ ] **Step 1: Add the loading branch**

In `Shared/Views/Positions/PositionsView.swift`, replace the chart block (lines 35–43, the `if input.showsChart { … }` block) with:

```swift
        if input.historyLoading {
          Divider()
          ProgressView()
            .controlSize(.small)
            .frame(maxWidth: .infinity)
            .frame(height: 260)
            .padding(.vertical, 8)
            .accessibilityLabel("Loading chart")
        } else if input.showsChart {
          Divider()
          PositionsChart(
            input: input,
            range: $range,
            selectedInstrument: $selection
          )
          .padding(.vertical, 8)
        }
```

> The fixed 260 pt height ≈ the chart's rendered height (`InvestmentAccountView` budgets "chart (~250pt with padding)") so the layout does not jump when phase 2 lands and the real chart replaces the spinner.

- [ ] **Step 2: Build to verify it compiles**

Run: `just build-mac 2>&1 | tail -5`
Expected: build succeeds.

- [ ] **Step 3: Visual check via preview (optional but recommended)**

Render the existing `PositionsView` preview that has a chart, plus a temporary preview passing `historyLoading: true`, using `mcp__xcode__RenderPreview` (worktree-aware: `just generate` then open the worktree's `Moolah.xcodeproj` per CLAUDE.md). Confirm the spinner occupies the chart's space without layout jump. Remove the temporary preview before committing if added.

- [ ] **Step 4: Commit**

```bash
git -C "$PWD" add Shared/Views/Positions/PositionsView.swift
git -C "$PWD" commit -m "feat(positions): show chart-area spinner while history loads"
```

---

### Task 5: Rewire `InvestmentAccountView+Loading` for two-phase load

**Files:**
- Modify: `Features/Investments/Views/InvestmentAccountView+Loading.swift:20-69`

- [ ] **Step 1: Replace `reloadPositions` and `maybeAutoWidenRange`, add `loadHistory`**

In `Features/Investments/Views/InvestmentAccountView+Loading.swift`, replace `reloadPositions()` (lines 20–35) and `maybeAutoWidenRange()` (lines 52–69) and insert `loadHistory(range:)` between them. The extension body becomes:

```swift
  /// Phase 1 of the two-phase load (positions + cost basis only). Sets
  /// `isLoadingPositions` across the work so progress UI binds correctly.
  /// The historic series is built separately by `loadHistory(range:)`.
  func reloadPositions() async {
    isLoadingPositions = true
    defer { isLoadingPositions = false }
    do {
      positionsInput = try await investmentStore.loadPositionsInput(
        account: account,
        profileCurrency: profileCurrencyInstrument)
    } catch is CancellationError {
      return
    } catch {
      Self.logger.error(
        "Unexpected error from loadPositionsInput: \(error.localizedDescription, privacy: .public)"
      )
    }
  }

  /// Phase 2: build the historic chart series off the critical path and
  /// merge it into `positionsInput`. The screen is already interactive by
  /// the time this runs; the chart pane shows a spinner
  /// (`PositionsViewInput.historyLoading`) until this lands. A
  /// `CancellationError` (navigation away / range change) is observed via
  /// `Task.isCancelled` and drops the stale result.
  func loadHistory(range: PositionsTimeRange) async {
    guard investmentStore.loadedAccountId != nil else { return }
    let series = await investmentStore.historicalSeries(range: range)
    if Task.isCancelled { return }
    positionsInput = positionsInput.applyingHistory(series)
  }

  /// If the account loaded with no remaining positions but the active
  /// range carries no points (the last trade pre-dates it), default the
  /// range to `.all` so the historic chart populates instead of stranding
  /// the user on "No chart data yet". Runs in phase 2 — it no longer
  /// blocks first paint. The chart's range picker stays bound to
  /// `positionsRange`, so the user can still narrow back afterwards.
  ///
  /// Flipping `positionsRange` also fires `.task(id: positionsRange)`,
  /// which rebuilds the `.all` series a second time; for the expected
  /// use case (idle, conversion cache warm) it is sub-second. This
  /// redundancy pre-dates this change and is intentionally preserved.
  func maybeAutoWidenRange() async {
    guard positionsInput.shouldHide,
      positionsInput.hasAnyHistoricalActivity,
      !positionsInput.hasHistoricalSeries,
      positionsRange != .all
    else { return }
    let series = await investmentStore.historicalSeries(range: .all)
    if Task.isCancelled { return }
    positionsInput = positionsInput.applyingHistory(series)
    positionsRange = .all
  }
```

> `profileCurrencyInstrument` and `Self.logger` are existing members of this extension / the view; unchanged. `reloadPositions` no longer reads `positionsRange` (phase 1 is range-independent).

- [ ] **Step 2: Build to verify it compiles**

Run: `just build-mac 2>&1 | tail -5`
Expected: FAIL — `InvestmentAccountView.swift` still calls the old single-phase `.task` flow referencing `positionsViewInput`; fixed in Task 6. (If it compiles because the call sites still resolve, proceed; the behavior wiring is Task 6.)

- [ ] **Step 3: Commit**

```bash
git -C "$PWD" add Features/Investments/Views/InvestmentAccountView+Loading.swift
git -C "$PWD" commit -m "feat(investments): two-phase reloadPositions + loadHistory + phase-2 auto-widen"
```

---

### Task 6: Rewire `InvestmentAccountView` task flow

**Files:**
- Modify: `Features/Investments/Views/InvestmentAccountView.swift:209-233`

- [ ] **Step 1: Replace the two `.task` modifiers**

In `Features/Investments/Views/InvestmentAccountView.swift`, replace the `.task(id: LoadKey…)` block (lines 209–217) and the `.task(id: positionsRange)` block (lines 218–233) with:

```swift
    .task(id: LoadKey(id: account.id, mode: account.valuationMode)) {
      initialLoadComplete = false
      await reloadPositions()
      // Screen is now interactive — transactions list + positions table
      // render while the historic series builds in phase 2 below.
      initialLoadComplete = true
      focusAnchor = .content
      await loadHistory(range: positionsRange)
      await maybeAutoWidenRange()
    }
    .task(id: positionsRange) {
      // Skip until phase 1 has populated the store; the `.task(id:)` keyed
      // on (account.id, valuationMode) runs the first history build. We
      // only fire phase-2 rebuilds for subsequent range changes here.
      guard investmentStore.loadedAccountId != nil else { return }
      await loadHistory(range: positionsRange)
    }
```

- [ ] **Step 2: Build to verify it compiles**

Run: `just build-mac 2>&1 | tail -5`
Expected: build succeeds.

- [ ] **Step 3: Run the investment view + store regression suites**

Run: `just test-mac InvestmentStoreTwoPhaseLoadTests InvestmentStorePositionsInputTests InvestmentStoreTests InvestmentStoreFullySoldChartTests 2>&1 | tee .agent-tmp/t6.txt`
Expected: PASS (all suites). The fully-sold/auto-widen suite pins the relocated `maybeAutoWidenRange` behavior.

- [ ] **Step 4: Commit**

```bash
git -C "$PWD" add Features/Investments/Views/InvestmentAccountView.swift
git -C "$PWD" commit -m "feat(investments): flip the screen gate after phase 1, build history in phase 2"
```

---

### Task 7: Full verification, format, agent reviews

**Files:** none (verification only)

- [ ] **Step 1: Format**

Run: `just format`
Then: `just format-check`
Expected: `format-check` exits 0 (no diff, no new SwiftLint violations beyond baseline). If it fails, fix the underlying code — never edit `.swiftlint-baseline.yml`.

- [ ] **Step 2: Compiler warnings check**

Run: `just build-mac 2>&1 | grep -i "warning:" | grep -v "#Preview" || echo "no warnings"`
Expected: `no warnings` (project treats warnings as errors).

- [ ] **Step 3: Full investment + positions test sweep, both platforms**

Run: `just test InvestmentStoreTwoPhaseLoadTests InvestmentStorePositionsInputTests InvestmentStoreTests PositionsViewInputHistoryLoadingTests PositionsViewInputChartTests PositionsHistoryBuilderTests 2>&1 | tee .agent-tmp/t7.txt`
Then check: `grep -i 'failed\|error:' .agent-tmp/t7.txt || echo "all green"`
Expected: `all green`.

- [ ] **Step 4: Agent reviews**

Run, in order, and address every Critical/Important/Minor finding before proceeding (do not rationalise findings away):
- `@code-review` — naming, thin-view discipline, optional/error handling, `TODO(#N)` format on the changed Swift files.
- `@concurrency-review` — `InvestmentStore` is `@MainActor`; verify the new `async` methods and the `Task.isCancelled` checks in `loadHistory`/`maybeAutoWidenRange` follow `guides/CONCURRENCY_GUIDE.md`.
- `@ui-review` — `PositionsView` chart-loading placeholder (accessibility label, no layout jump, HIG).

- [ ] **Step 5: Re-profile the original repro (responsiveness verification)**

Using the `profile-performance` + `automate-app` skills (worktree app build): `just run-mac-with-logs`, navigate to "Shares" in "Large Test Profile", and confirm the transactions list is visible and interactive within a frame or two of navigation (the chart shows a spinner and fills in afterward). Capture a stack sample during the chart build to confirm the slow build is now off the main critical path. Note: the build itself is still slow until Plan B — that is expected and acceptable for Plan A.

- [ ] **Step 6: Commit any review fixes**

```bash
git -C "$PWD" add -A
git -C "$PWD" commit -m "chore(investments): address review findings for two-phase load"
```

---

### Task 8: Open PR and queue it

**Files:** none

- [ ] **Step 1: Push the branch**

```bash
git -C "$PWD" push origin perf/responsive-investment-load:perf/responsive-investment-load
```

- [ ] **Step 2: Open the PR**

```bash
gh pr create --title "perf(investments): responsive two-phase investment account load" \
  --body "$(cat <<'EOF'
Decouples the historic-graph build from the investment account screen so
transactions/positions render immediately and the chart loads behind a
spinner. Approach 2, Plan A (responsiveness).

Spec: plans/2026-05-16-responsive-investment-load-design.md
Plan: plans/2026-05-16-responsive-investment-load-plan-A-responsiveness.md

Plan B (sorted-array price/rate caches — the build-speed fix) is a
separate follow-up PR.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

- [ ] **Step 3: Add the PR to the merge queue**

Use the `merge-queue` skill to enqueue the new PR (never merge manually).

---

### Task 9: Move spec + plan to `plans/completed/` when merged

**Files:**
- Move: `plans/2026-05-16-responsive-investment-load-plan-A-responsiveness.md` → `plans/completed/`
- Move: `plans/2026-05-16-responsive-investment-load-design.md` → `plans/completed/` **only if Plan B is also complete** (the spec covers both plans; if Plan B is still outstanding, leave the spec in `plans/` and move only this plan).

- [ ] **Step 1: After this PR merges, move this plan doc**

```bash
git -C "$PWD" mv plans/2026-05-16-responsive-investment-load-plan-A-responsiveness.md plans/completed/
```

- [ ] **Step 2: Move the spec only if Plan B is done**

If Plan B (`plans/2026-05-16-responsive-investment-load-plan-B-caches.md`) has also merged:

```bash
git -C "$PWD" mv plans/2026-05-16-responsive-investment-load-design.md plans/completed/
```

Otherwise leave the spec in `plans/` for Plan B to reference, and Plan B's final task moves it.

- [ ] **Step 3: Commit and ship via the normal PR + merge-queue flow**

```bash
git -C "$PWD" commit -m "chore(plans): move responsive investment load plan A to completed"
```

(Push + PR + merge-queue as in Task 8; a docs-only PR.)

---

## Self-Review

**Spec coverage (Plan A subset):**
- Spec §1 "Two-phase load" → Tasks 2, 3, 5, 6. ✓
- Spec §2 "Chart loading contract" (`historyLoading` + `PositionsView` placeholder) → Tasks 1, 4. ✓
- Spec §4 "Error handling & cancellation" → Task 3 (CancellationError rethrow), Task 5 (`Task.isCancelled` in `loadHistory`/`maybeAutoWidenRange`), Task 6 (gate after phase 1). ✓
- Spec §5 "Testing" — store split + composed regression + model helper → Tasks 1, 3; relocated auto-widen pinned by existing `InvestmentStoreFullySoldChartTests` in Task 6; optional UI-test stretch item intentionally omitted (spec marks it non-gating). ✓
- Spec §3 "Sorted-array caches" → **out of scope for Plan A**; Plan B. Stated in the header. ✓
- Spec "Verification" → Task 7 Step 5. ✓
- User instruction "move plans + spec to completed when done" → Task 9. ✓

**Placeholder scan:** No TBD/TODO/"handle errors"/"similar to". The one annotated caveat (HistoricalValueSeries init labels in Task 1 Step 1) instructs verification against a named source file, not deferred work. ✓

**Type consistency:** `historyLoading` (Bool, default false) and `applyingHistory(_:) -> PositionsViewInput` defined in Task 1 and used identically in Tasks 3, 5. `loadPositionsInput(account:profileCurrency:) async throws`, `positionsInputWithoutHistory(title:) async throws`, `historicalSeries(range:) async -> HistoricalValueSeries?` defined in Task 3 and called with matching signatures in Tasks 5/6. `setLoadedTransactions(_:)` / `loadedTransactions` defined Task 2, used Task 3. ✓
