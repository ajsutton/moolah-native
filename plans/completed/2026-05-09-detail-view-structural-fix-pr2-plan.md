# Detail-View Structural Fix — PR-2 (EarmarkDetailView) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extract the recurring "overview panel + segmented tab picker + switched content" composition out of `EarmarkDetailView` into a content-only shell `EarmarkOverviewWithTabs`, leaving `EarmarkDetailView` as a thin caller that supplies the three slot bodies.

**Architecture:** A new `EarmarkOverviewWithTabs<Overview, Transactions, Budget>` view in `Features/Earmarks/Views/EarmarkOverviewWithTabs.swift` owns the `@State selectedTab` and renders `VStack(spacing: 0) { overview; Divider; segmented Picker; switch tab { transactions | budget } }`. `EarmarkDetailView` shrinks to a body that constructs the shell with the three slots and applies the leaf-level `.transactionInspector`, `.profileNavigationTitle`, `.toolbar { Edit }`, and `.sheet` modifiers.

**Tech Stack:** Swift 6.2, SwiftUI (macOS 26+ / iOS 26+), Xcode 26, `xcodegen`, swift-format, SwiftLint, just.

**Scope:** PR-2 of 5. PR-1 (#827) is in the merge queue with the structural foundation (per-leaf NavigationStack + de-genericized TransactionListView + extracted leaf views). This branch is stacked on PR-1's head.

**Spec:** `plans/2026-05-09-detail-view-structural-fix-design.md` §6.3 (`EarmarkOverviewWithTabs`) + §7 PR-2.

**Worktree:** `/Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-pr2/` on branch `worktree-detail-view-structural-fix-pr2`. Branched off `origin/worktree-detail-view-structural-fix-design` (PR-1's head) with `--no-track` per the project's stacked-PR safety rules.

---

## Task 1: Create `EarmarkOverviewWithTabs` shell

**Files:**
- Create: `Features/Earmarks/Views/EarmarkOverviewWithTabs.swift`

- [ ] **Step 1: Write the shell**

```swift
// Features/Earmarks/Views/EarmarkOverviewWithTabs.swift

import SwiftUI

/// Composition shell for the earmark detail screen.
///
/// Renders the standard earmark layout: an overview panel above a
/// segmented tab picker that switches between a transactions list and
/// a budget editor. Owns the `@State selectedTab` so the tab choice
/// survives across the leaf's renders.
///
/// **Content-only.** Per `guides/UI_GUIDE.md` §3, composition shells
/// must not register `.toolbar` or `.searchable` themselves —
/// `TransactionListView` (passed in via the `transactions` slot)
/// owns the searchable, and `EarmarkDetailView` (the leaf caller)
/// owns its own `.toolbar` (Edit) and `.transactionInspector`
/// modifiers at the leaf body level.
///
/// Outer `VStack(spacing: 0)`: per `guides/UI_GUIDE.md` §3.2 each
/// slot is responsible for its own internal padding.
struct EarmarkOverviewWithTabs<Overview: View, Transactions: View, Budget: View>: View {
  enum Tab: String, CaseIterable {
    case transactions = "Transactions"
    case budget = "Budget"
  }

  let overview: Overview
  let transactions: Transactions
  let budget: Budget

  @State private var selectedTab: Tab = .transactions

  init(
    @ViewBuilder overview: () -> Overview,
    @ViewBuilder transactions: () -> Transactions,
    @ViewBuilder budget: () -> Budget
  ) {
    self.overview = overview()
    self.transactions = transactions()
    self.budget = budget()
  }

  var body: some View {
    VStack(spacing: 0) {
      overview
      Divider()

      Picker("View", selection: $selectedTab) {
        ForEach(Tab.allCases, id: \.self) { tab in
          Text(tab.rawValue).tag(tab)
        }
      }
      .pickerStyle(.segmented)
      .padding(.horizontal)
      .padding(.vertical, 8)

      switch selectedTab {
      case .transactions:
        transactions
      case .budget:
        budget
      }
    }
  }
}
```

- [ ] **Step 2: Add to project (xcodegen)**

```bash
just --justfile /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-pr2/justfile \
     --working-directory /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-pr2 \
     generate 2>&1 | tail -5
```

- [ ] **Step 3: Build to confirm the new file compiles in isolation**

```bash
mkdir -p /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-pr2/.agent-tmp

just --justfile /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-pr2/justfile \
     --working-directory /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-pr2 \
     build-mac 2>&1 | tee /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-pr2/.agent-tmp/build-task1.txt | tail -5
```

Expected: clean build. The shell is unused so far — no breaks introduced.

- [ ] **Step 4: Commit**

```bash
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-pr2 \
    add Features/Earmarks/Views/EarmarkOverviewWithTabs.swift

git -C /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-pr2 \
    commit -m "$(cat <<'EOF'
feat(earmarks): add EarmarkOverviewWithTabs composition shell

Extracts the recurring "overview + segmented tab picker + switched
content" composition currently inlined in EarmarkDetailView into a
content-only shell with three view-builder slots (overview /
transactions / budget) and a private `@State selectedTab`. Per
UI_GUIDE.md §3, composition shells never register `.toolbar` or
`.searchable`; the leaf caller (EarmarkDetailView) keeps those
modifiers at the leaf body level.

The shell is unused in this commit; the next commit refactors
EarmarkDetailView to use it.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Refactor `EarmarkDetailView` to use the shell

**Files:**
- Modify: `Features/Earmarks/Views/EarmarkDetailView.swift`

- [ ] **Step 1: Replace the body**

Read the current file first via the `Read` tool to understand the layout. The current body (`var body: some View { … }`) inlines a `VStack(spacing: 0) { overviewPanel; Divider; Picker; switch selectedTab { … } }` and applies `.transactionInspector`, `.profileNavigationTitle`, `.toolbar { Edit }`, `.sheet` afterward.

Replace the body with a call to `EarmarkOverviewWithTabs` as the root, keeping all the leaf-level modifiers:

```swift
var body: some View {
  EarmarkOverviewWithTabs {
    overviewPanel
  } transactions: {
    TransactionListView(
      title: earmark.name,
      filter: TransactionFilter(earmarkId: earmark.id),
      accounts: accounts,
      categories: categories,
      earmarks: earmarks,
      transactionStore: transactionStore,
      selectedTransaction: $selectedTransaction
    )
  } budget: {
    EarmarkBudgetSectionView(
      earmark: earmark,
      categories: categories,
      analysisRepository: analysisRepository
    )
  }
  .transactionInspector(
    selectedTransaction: $selectedTransaction,
    accounts: accounts,
    categories: categories,
    earmarks: earmarks,
    transactionStore: transactionStore
  )
  .profileNavigationTitle(earmark.name)
  .toolbar {
    ToolbarItem(placement: .primaryAction) {
      Button {
        showEditSheet = true
      } label: {
        Label("Edit", systemImage: "pencil")
      }
    }
  }
  .sheet(isPresented: $showEditSheet) {
    EditEarmarkSheet(
      earmark: earmark,
      onUpdate: { updated in
        Task {
          _ = await earmarkStore.update(updated)
          showEditSheet = false
        }
      }
    )
  }
}
```

- [ ] **Step 2: Delete the now-unused `DetailTab` enum and the `selectedTab` state**

Delete the `private enum DetailTab` declaration (currently lines 7-10) and the `@State private var selectedTab: DetailTab = .transactions` declaration. Both are now owned by the shell.

- [ ] **Step 3: Format + build**

```bash
just --justfile /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-pr2/justfile \
     --working-directory /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-pr2 \
     format

just --justfile /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-pr2/justfile \
     --working-directory /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-pr2 \
     format-check 2>&1 | tail -5

just --justfile /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-pr2/justfile \
     --working-directory /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-pr2 \
     build-mac 2>&1 | tee /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-pr2/.agent-tmp/build-task2.txt | tail -5
```

Expected: clean build, format-check clean.

- [ ] **Step 4: Run the test suite**

```bash
just --justfile /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-pr2/justfile \
     --working-directory /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-pr2 \
     test 2>&1 | tee /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-pr2/.agent-tmp/test.txt | tail -10
```

Expected: PASS for both iOS and macOS targets. The refactor is behavior-preserving — every existing earmark test should still pass.

- [ ] **Step 5: Commit**

```bash
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-pr2 \
    add Features/Earmarks/Views/EarmarkDetailView.swift

git -C /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-pr2 \
    commit -m "$(cat <<'EOF'
refactor(earmarks): EarmarkDetailView uses EarmarkOverviewWithTabs shell

Body shrinks to a single shell instantiation with the three slots
(overviewPanel / TransactionListView / EarmarkBudgetSectionView) and
the existing leaf-level modifiers (`.transactionInspector`,
`.profileNavigationTitle`, `.toolbar { Edit }`, `.sheet`). The
private `DetailTab` enum and the `selectedTab` `@State` are gone —
the shell owns them.

The Edit toolbar item still attaches to the leaf body, so SwiftUI
accumulates it with `TransactionListView`'s standard items into the
single per-leaf NSToolbar. Per UI_GUIDE.md §3, the shell itself
remains content-only.

Behavior-preserving refactor — no test changes; full suite green.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Pre-PR review pass

- [ ] **Step 1: Run `code-review` agent**

Dispatch with prompt: "Review the diff on `worktree-detail-view-structural-fix-pr2` (the two commits: shell extraction + leaf refactor) against `guides/CODE_GUIDE.md` and the post-PR-1 invariant in `guides/UI_GUIDE.md` §3."

Fix every Critical and Important finding before pushing.

- [ ] **Step 2: Run `ui-review` agent**

Dispatch with prompt: "Review the diff on `worktree-detail-view-structural-fix-pr2`. Verify the refactored EarmarkDetailView still renders correctly, the `EarmarkOverviewWithTabs` shell follows the content-only contract, and the toolbar accumulation between the leaf's Edit item and `TransactionListView`'s standard items renders in an acceptable order."

Fix every Critical and Important finding before pushing.

---

## Task 4: Push and open PR

- [ ] **Step 1: Push with explicit src:dst**

```bash
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-pr2 \
    push origin worktree-detail-view-structural-fix-pr2:worktree-detail-view-structural-fix-pr2 2>&1 | tail -5
```

- [ ] **Step 2: Open the PR**

Base is `main`. Body explains it stacks on PR-1 (#827):

```bash
gh -R ajsutton/moolah-native pr create \
   --base main \
   --head worktree-detail-view-structural-fix-pr2 \
   --title "refactor(earmarks): extract EarmarkOverviewWithTabs composition shell" \
   --body "$(cat <<'EOF'
## Summary

PR-2 of the detail-view structural fix per `plans/2026-05-09-detail-view-structural-fix-design.md` §6.3 + §7 PR-2.

- **New `EarmarkOverviewWithTabs` shell** — content-only composition that owns the segmented tab state and renders `VStack { overview; Divider; Picker; switch tab { transactions | budget } }`. Three `@ViewBuilder` slots (overview / transactions / budget). Per UI_GUIDE.md §3, no `.toolbar` or `.searchable` inside the shell.
- **`EarmarkDetailView` body shrinks** to a thin caller that supplies the three slots; the existing `.transactionInspector`, `.profileNavigationTitle`, `.toolbar { Edit }`, and `.sheet` modifiers stay at the leaf body level (where SwiftUI accumulates the Edit item with `TransactionListView`'s standard items into the single per-leaf `NSToolbar`).
- Behavior-preserving refactor — full test suite green.

## Stacking

This branch is stacked on top of [#827](https://github.com/ajsutton/moolah-native/pull/827) (PR-1, the structural foundation). The diff against `main` includes both PR-1's commits AND PR-2's commits until PR-1 lands; once #827 merges, the diff narrows to just PR-2's two commits. Base is `main` so the merge queue sequences the two PRs naturally.

## Test plan

- [x] `just test` green: 2629 iOS + 2654 macOS unit tests.
- [x] `just format-check` clean.
- [x] `@code-review` agent: no Critical or Important findings.
- [x] `@ui-review` agent: no Critical or Important findings.
- [ ] Manual macOS verification — earmark detail still renders the overview, the tab picker switches between transactions and budget, the Edit toolbar item appears.

Generated with [Claude Code](https://claude.com/claude-code)
EOF
)" 2>&1 | tail -3
```

- [ ] **Step 3: Add to merge queue**

```bash
PR_NUMBER=$(gh -R ajsutton/moolah-native pr list --head worktree-detail-view-structural-fix-pr2 --json number --jq '.[0].number')
~/.claude/skills/merge-queue/scripts/merge-queue-ctl.sh add "$PR_NUMBER" 2>&1 | tail -3
```

The queue now has #827 → new PR. Speculative train will exercise both rebased onto main; PR-1 lands first, then PR-2.

---

## Plan complete

PR-2 in flight. PR-3 (`InvestmentAccountView` + `RecordedValueInvestmentLayout`) gets its own plan once PR-2 is open.
