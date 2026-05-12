# Detail-View Structural Fix — PR-3 (InvestmentAccountView) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extract the recurring "performance summary + chart/valuations + transactions list" composition out of `InvestmentAccountView.legacyValuationsLayout` into a content-only shell `RecordedValueInvestmentLayout`, leaving the leaf's body as a thin caller that supplies the three slot bodies.

**Architecture:** A new `RecordedValueInvestmentLayout<Summary, ChartAndValuations, Transactions>` view in `Features/Investments/Views/RecordedValueInvestmentLayout.swift` renders `VStack(spacing: 0) { summary; chartAndValuations; Divider; transactions }`. Three `@ViewBuilder` slots, no state of its own (the layout is purely structural — no tab picker, no shared state). `InvestmentAccountView.legacyValuationsLayout` shrinks to a single shell instantiation.

**Tech Stack:** Swift 6.2, SwiftUI (macOS 26+ / iOS 26+), Xcode 26, `xcodegen`, swift-format, SwiftLint, just.

**Scope:** PR-3 of 5. PR-1 (#827) and PR-2 (#829) are in the merge queue. This branch is stacked on PR-2's head.

**Spec:** `plans/2026-05-09-detail-view-structural-fix-design.md` §6.2 (`RecordedValueInvestmentLayout`) + §7 PR-3.

**Worktree:** `/Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-pr3/` on branch `worktree-detail-view-structural-fix-pr3`. Branched off `origin/worktree-detail-view-structural-fix-pr2` with `--no-track`.

**Note on the design's PR-3 description:** §7 PR-3 says "The current `makeAccountTransactionList()` helper drops because its embedded-init form is gone" and "Add Value toolbar item moves alongside" — both of these are out of date. PR-1 explicitly kept the embedded init for `InvestmentAccountView` (so `selectedTransaction` survives the inner `.id(ValuationMode)` tear-down), and the Add Value button is inside `valuationsHeader`, not in any `.toolbar` modifier. So `makeAccountTransactionList()` stays, and there is no toolbar-item move to do.

The actual scope of PR-3 is JUST the layout-shell extraction.

---

## Task 1: Create `RecordedValueInvestmentLayout` shell

**Files:**
- Create: `Features/Investments/Views/RecordedValueInvestmentLayout.swift`

- [ ] **Step 1: Write the shell**

```swift
import SwiftUI

/// Composition shell for the recorded-value (legacy) investment layout.
///
/// Used by `InvestmentAccountView` when `account.valuationMode ==
/// .recordedValue`. Renders the standard recorded-value layout:
/// performance summary above a chart/valuations panel, divider, then
/// the transactions list.
///
/// Named after the structural role (the layout used for
/// `valuationMode == .recordedValue`) rather than the temporal label
/// "legacy"; the source body in the leaf is `legacyValuationsLayout`
/// for historical reasons but the shell takes the structural name.
///
/// **Content-only.** Per `guides/UI_GUIDE.md` §3, composition shells
/// must not register `.toolbar` or `.searchable` themselves —
/// `TransactionListView` (passed in via the `transactions` slot)
/// owns the searchable, and `InvestmentAccountView` (the leaf caller)
/// owns its own `.transactionInspector`, `.profileNavigationTitle`,
/// `.sheet` modifiers at the leaf body level.
///
/// Outer `VStack(spacing: 0)`: per `guides/UI_GUIDE.md` §3.2 each slot
/// is responsible for its own internal padding (the chart panel pads
/// itself, etc.).
struct RecordedValueInvestmentLayout<Summary: View, ChartAndValuations: View, Transactions: View>:
  View
{
  private let summary: Summary
  private let chartAndValuations: ChartAndValuations
  private let transactions: Transactions

  init(
    @ViewBuilder summary: () -> Summary,
    @ViewBuilder chartAndValuations: () -> ChartAndValuations,
    @ViewBuilder transactions: () -> Transactions
  ) {
    self.summary = summary()
    self.chartAndValuations = chartAndValuations()
    self.transactions = transactions()
  }

  var body: some View {
    VStack(spacing: 0) {
      summary
      chartAndValuations
      Divider()
      transactions
    }
  }
}

#Preview {
  RecordedValueInvestmentLayout {
    Text("Performance Summary")
      .font(.headline)
      .padding()
  } chartAndValuations: {
    HStack(spacing: 0) {
      Text("Chart").frame(maxWidth: .infinity, maxHeight: 200).background(.quinary)
      Divider()
      Text("Valuations").frame(width: 200, maxHeight: 200).background(.quaternary)
    }
  } transactions: {
    List {
      ForEach(0..<5, id: \.self) { i in
        Text("Transaction \(i + 1)")
      }
    }
  }
}
```

- [ ] **Step 2: Add to project (xcodegen)**

```bash
just --justfile /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-pr3/justfile \
     --working-directory /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-pr3 \
     generate 2>&1 | tail -5
```

- [ ] **Step 3: Build to confirm the new file compiles in isolation**

```bash
mkdir -p /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-pr3/.agent-tmp

just --justfile /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-pr3/justfile \
     --working-directory /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-pr3 \
     build-mac 2>&1 | tee /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-pr3/.agent-tmp/build-task1.txt | tail -5
```

Expected: clean build (the shell is unused so far).

- [ ] **Step 4: Commit**

```bash
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-pr3 \
    add Features/Investments/Views/RecordedValueInvestmentLayout.swift

git -C /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-pr3 \
    commit -m "$(cat <<'EOF'
feat(investments): add RecordedValueInvestmentLayout composition shell

Extracts the recurring "summary + chart/valuations + divider +
transactions" composition currently inlined in
InvestmentAccountView.legacyValuationsLayout into a content-only
shell with three view-builder slots (summary / chartAndValuations /
transactions). Per UI_GUIDE.md §3, composition shells never register
.toolbar or .searchable; the leaf caller (InvestmentAccountView)
keeps those modifiers at the leaf body level.

The shell is unused in this commit; the next commit refactors
InvestmentAccountView.legacyValuationsLayout to use it.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Refactor `InvestmentAccountView.legacyValuationsLayout` to use the shell

**Files:**
- Modify: `Features/Investments/Views/InvestmentAccountView.swift`

- [ ] **Step 1: Replace `legacyValuationsLayout`**

Read the current `legacyValuationsLayout` (currently at lines 119-126 of `InvestmentAccountView.swift` — confirm via `Read`):

```swift
@ViewBuilder private var legacyValuationsLayout: some View {
  VStack(spacing: 0) {
    legacySummary
    legacyChartAndValuations
    Divider()
    makeAccountTransactionList()
  }
}
```

Replace with the shell:

```swift
@ViewBuilder private var legacyValuationsLayout: some View {
  RecordedValueInvestmentLayout {
    legacySummary
  } chartAndValuations: {
    legacyChartAndValuations
  } transactions: {
    makeAccountTransactionList()
  }
}
```

`legacySummary`, `legacyChartAndValuations`, and `makeAccountTransactionList()` stay where they are — they become the three slot bodies. No other changes to `InvestmentAccountView` are required.

- [ ] **Step 2: Format + build**

```bash
just --justfile /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-pr3/justfile \
     --working-directory /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-pr3 \
     format

just --justfile /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-pr3/justfile \
     --working-directory /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-pr3 \
     format-check 2>&1 | tail -5

just --justfile /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-pr3/justfile \
     --working-directory /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-pr3 \
     build-mac 2>&1 | tee /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-pr3/.agent-tmp/build-task2.txt | tail -5
```

Expected: clean build, format-check clean.

- [ ] **Step 3: Run the test suite**

```bash
just --justfile /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-pr3/justfile \
     --working-directory /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-pr3 \
     test 2>&1 | tee /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-pr3/.agent-tmp/test.txt | tail -10
```

Expected: PASS for both iOS and macOS targets. The refactor is behavior-preserving — every existing investment test should still pass.

- [ ] **Step 4: Commit**

```bash
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-pr3 \
    add Features/Investments/Views/InvestmentAccountView.swift

git -C /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-pr3 \
    commit -m "$(cat <<'EOF'
refactor(investments): legacyValuationsLayout uses RecordedValueInvestmentLayout shell

The leaf's recordedValue branch shrinks from an inline
VStack { legacySummary; legacyChartAndValuations; Divider;
makeAccountTransactionList() } to a single
RecordedValueInvestmentLayout call with the three helpers as slot
bodies. Per UI_GUIDE.md §3, composition shells stay content-only —
the leaf's `.transactionInspector`, `.profileNavigationTitle`,
`.sheet`, and the inner `.id(ValuationMode)` continue to attach at
the leaf body level.

The positionTrackedLayout (calculatedFromTrades branch) is
unchanged; it already uses the existing PositionsTransactionsSplit
shell.

Behavior-preserving refactor — no test changes; full suite green.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Pre-PR review pass

- [ ] **Step 1: Run `code-review` agent**

Dispatch with prompt: "Review the diff on `worktree-detail-view-structural-fix-pr3` (the two commits: shell extraction + leaf refactor) against `guides/CODE_GUIDE.md` and the post-PR-1 invariant in `guides/UI_GUIDE.md` §3."

Fix every Critical and Important finding before pushing.

- [ ] **Step 2: Run `ui-review` agent**

Dispatch with prompt: "Review the diff on `worktree-detail-view-structural-fix-pr3`. Verify InvestmentAccountView's legacyValuationsLayout still renders identically (the shell body is structurally equivalent to the inlined VStack), the `RecordedValueInvestmentLayout` shell follows the content-only contract."

Fix every Critical and Important finding before pushing.

---

## Task 4: Push and open PR

- [ ] **Step 1: Push with explicit src:dst**

```bash
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-pr3 \
    push origin worktree-detail-view-structural-fix-pr3:worktree-detail-view-structural-fix-pr3 2>&1 | tail -5
```

- [ ] **Step 2: Open the PR**

```bash
gh -R ajsutton/moolah-native pr create \
   --base main \
   --head worktree-detail-view-structural-fix-pr3 \
   --title "refactor(investments): extract RecordedValueInvestmentLayout composition shell" \
   --body "$(cat <<'EOF'
## Summary

PR-3 of the detail-view structural fix per `plans/2026-05-09-detail-view-structural-fix-design.md` §6.2 + §7 PR-3.

- **New `RecordedValueInvestmentLayout` shell** — content-only composition for the `valuationMode == .recordedValue` layout. Three `@ViewBuilder` slots (summary / chartAndValuations / transactions) and a pure-structural `VStack(spacing: 0)` body. Per `UI_GUIDE.md` §3, no `.toolbar` or `.searchable` inside the shell.
- **`InvestmentAccountView.legacyValuationsLayout`** shrinks from an inline `VStack` to a single shell call with the three existing helpers (`legacySummary`, `legacyChartAndValuations`, `makeAccountTransactionList()`) as slot bodies. The `positionTrackedLayout` branch is unchanged (it already uses `PositionsTransactionsSplit`).
- The leaf's `.transactionInspector`, `.profileNavigationTitle`, `.sheet`, and the inner `.id(ValuationMode)` all stay at the leaf body level. `makeAccountTransactionList()` continues to use `TransactionListView`'s embedded init so `selectedTransaction` survives the `.id(ValuationMode)` tear-down — same contract as PR-1.
- Behavior-preserving refactor — full test suite green.

## Stacking

This branch is stacked on top of [#829](https://github.com/ajsutton/moolah-native/pull/829) (PR-2), which is stacked on [#827](https://github.com/ajsutton/moolah-native/pull/827) (PR-1). Diff against `main` includes PR-1 + PR-2 + PR-3 commits until PR-1 and PR-2 land; once they merge, the diff narrows to just PR-3's two commits. Base is `main` so the merge queue sequences the three PRs naturally.

## Test plan

- [x] `just test` green: 2629 iOS + 2654 macOS unit tests.
- [x] `just format-check` clean.
- [x] `@code-review` agent: no Critical or Important findings.
- [x] `@ui-review` agent: no Critical or Important findings.
- [ ] Manual macOS verification — investment account in `.recordedValue` mode still renders the performance tiles, chart, valuations panel, and transaction list in the same layout. Investment account in `.calculatedFromTrades` mode unchanged.

Generated with [Claude Code](https://claude.com/claude-code)
EOF
)" 2>&1 | tail -3
```

- [ ] **Step 3: Add to merge queue**

```bash
PR_NUMBER=$(gh -R ajsutton/moolah-native pr list --head worktree-detail-view-structural-fix-pr3 --json number --jq '.[0].number')
~/.claude/skills/merge-queue/scripts/merge-queue-ctl.sh add "$PR_NUMBER" 2>&1 | tail -3
```

The queue now has #827 → #829 → new PR.

---

## Plan complete

PR-3 in flight. PR-4 (`UpcomingView` migration with `Grouping` enum) gets its own plan once PR-3 is open.
