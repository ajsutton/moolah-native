# Detail-View Structural Fix — PR-4 (UpcomingView migration) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fold `UpcomingView`'s sectioned scheduled-transactions list into the canonical `TransactionListView` via a new `Grouping` enum (`.flat` / `.byDate` / `.scheduledStatus(today:, pendingPayId:)`), and migrate `UpcomingView` to a thin wrapper. `UpcomingTransactionRow`'s special UX (overdue / due-today styling, recurrence meta, inline Pay button) folds into `TransactionRowView` via optional parameters; `UpcomingTransactionRow.swift` is deleted.

**Architecture:** `TransactionListView` gains a non-optional `grouping: Grouping = .flat` parameter; the `.scheduledStatus` case bundles a `pendingPayId: Binding<Transaction.ID?>` so the binding is structurally required when (and only when) the caller selects that grouping. When `grouping == .scheduledStatus`, the list reads from `transactionStore.scheduledOverdueTransactions` / `.scheduledUpcomingTransactions` (already on `TransactionStore`), wraps them in `Section("Overdue") / Section("Upcoming")`, adds a "Pay Scheduled Transaction…" context-menu item + leading swipe action that write the row id into the binding, renders a `ProgressView` at the row's trailing edge while `pendingPayId.wrappedValue == row.id`, dynamically labels the Add toolbar button "Add Scheduled Transaction" / `calendar.badge.plus` and creates a recurring placeholder, and shows a scheduled-specific empty state. `TransactionRowView` gains `isOverdue / isDueToday / onPay` optional parameters; `UpcomingView` shrinks to ~50 lines (down from ~280).

**Tech Stack:** Swift 6.2, SwiftUI (macOS 26+ / iOS 26+), Xcode 26, `xcodegen`, swift-format, SwiftLint, just.

**Scope:** PR-4 of 5. PR-1 / PR-2 / PR-3 are queued. This branch stacks on PR-3's head.

**Spec:** `plans/2026-05-09-detail-view-structural-fix-design.md` §5.1 (`Grouping` enum), §5.4 (data flow — Pay action, in-progress visual), §7 PR-4.

**Worktree:** `/Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-pr4/` on branch `worktree-detail-view-structural-fix-pr4`. Branched off `origin/worktree-detail-view-structural-fix-pr3` with `--no-track`.

**Acknowledged scope expansion:** The design didn't fully spell out `UpcomingTransactionRow`'s removal. The custom row's UX (overdue red + warning icon, due-today orange + bold, recurrence in meta, inline Pay button) is folded into `TransactionRowView` so the canonical row can render it. `UpcomingTransactionRow.swift` is deleted.

---

## Task 1: Extend `TransactionRowView` with overdue / due-today / recurrence / Pay-button parameters

**Files:**
- Modify: `Features/Transactions/Views/TransactionRowView.swift`

The goal is feature parity with `UpcomingTransactionRow`, all gated on optional parameters that default to the row's current behaviour.

- [ ] **Step 1: Read both row implementations**

```
Read /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-pr4/Features/Transactions/Views/TransactionRowView.swift
Read /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-pr4/Features/Transactions/Views/UpcomingTransactionRow.swift
```

`UpcomingTransactionRow.swift` is the source of the special UX (lines 34-46 payeeHeader red treatment, lines 48-75 metaRow with recurrence + categories + earmarks, lines 89-99 inline Pay button, lines 101-125 augmented accessibility description). Replicate behaviorally.

- [ ] **Step 2: Add new optional parameters to `TransactionRowView`**

Add to `TransactionRowView`'s declared properties:

```swift
/// When true, the payee header shows a red `exclamationmark.triangle.fill`
/// leading icon and the payee text renders in red. Used by the
/// `.scheduledStatus` grouping for overdue rows.
var isOverdue: Bool = false

/// When true, the date in the meta row renders in orange and bold,
/// indicating the scheduled transaction is due today. Used by the
/// `.scheduledStatus` grouping.
var isDueToday: Bool = false

/// Optional inline Pay button. When non-nil, the row renders a trailing
/// "Pay" button that invokes the closure. When nil (the default), no
/// button is rendered. Used by the `.scheduledStatus` grouping.
var onPay: (() -> Void)?

/// When non-nil and equal to this row's transaction id, the inline Pay
/// area is replaced by a small `ProgressView` with a payee-parameterised
/// `.accessibilityLabel`, and the row is `.disabled(true)`. Used by the
/// `.scheduledStatus` grouping for the in-progress pay flow.
var pendingPayId: Transaction.ID?
```

- [ ] **Step 3: Update `body` and helpers to consume the new parameters**

Apply the visual changes:

- Payee header gains the leading `exclamationmark.triangle.fill` icon (red, `.imageScale(.small)`, `.accessibilityHidden(true)`) and red `.foregroundStyle` on the text when `isOverdue`.
- Meta row's date renders `.foregroundStyle(.orange)` + `.fontWeight(.semibold)` when `isDueToday`.
- Meta row gains a recurrence description (`transaction.recurPeriod` and `recurEvery` via `period.recurrenceDescription(every:)`) between the date and the categories — copy `UpcomingTransactionRow.recurrenceDescription`.
- The row's right side gains a per-state branch:
  - If `pendingPayId == transaction.id`: render `ProgressView().controlSize(.small)` with `.accessibilityLabel("Paying \(displayPayee), please wait")` and apply `.disabled(true)` to the entire row.
  - Else if `onPay != nil`: render an inline "Pay" button (use the same per-platform `.buttonStyle` switch as `UpcomingTransactionRow.payButton`).
  - Else: no extra trailing element.
- Update the `accessibilityDescription` to prefix "Overdue, " when `isOverdue` and to say "due today, <date>" when `isDueToday`. Append "repeats <recurrence>" when the row carries a recurrence. Match `UpcomingTransactionRow`'s description format.

Keep the existing `displayAmount`, `balance`, `scopeReferenceInstrument`, `hideEarmark`, `viewingAccountId` parameters and behaviour. The new parameters all default in a way that preserves the row's current rendering for every existing call site.

- [ ] **Step 4: Format + build**

```bash
mkdir -p /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-pr4/.agent-tmp

just --justfile /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-pr4/justfile \
     --working-directory /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-pr4 \
     format

just --justfile /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-pr4/justfile \
     --working-directory /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-pr4 \
     format-check 2>&1 | tail -5

just --justfile /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-pr4/justfile \
     --working-directory /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-pr4 \
     build-mac 2>&1 | tee /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-pr4/.agent-tmp/build-task1.txt | tail -10
```

Expected: clean build. Existing call sites are unchanged because the new parameters default.

- [ ] **Step 5: Run the test suite**

```bash
just --justfile /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-pr4/justfile \
     --working-directory /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-pr4 \
     test 2>&1 | tee /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-pr4/.agent-tmp/test-task1.txt | tail -10
```

Expected: all 2629 iOS + 2654 macOS tests still pass — the new parameters default to behaviour-preserving values.

- [ ] **Step 6: Commit**

```bash
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-pr4 \
    add Features/Transactions/Views/TransactionRowView.swift

git -C /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-pr4 \
    commit -m "$(cat <<'EOF'
feat(transactions): TransactionRowView gains overdue / due-today / Pay parameters

Adds four optional parameters to the canonical row so it can render the
special UX previously inlined in `UpcomingTransactionRow`:

- `isOverdue: Bool = false` — red `exclamationmark.triangle.fill` icon
  + red payee text.
- `isDueToday: Bool = false` — orange + bold date in the meta row.
- `onPay: (() -> Void)?` — inline trailing "Pay" button when non-nil.
- `pendingPayId: Transaction.ID?` — when equal to this row's id, the
  Pay button is replaced by a `ProgressView` with a payee-parameterised
  `.accessibilityLabel` and the row is `.disabled(true)`.

Recurrence description (`transaction.recurPeriod` + `recurEvery`) is
also added to the meta row when present.

All existing call sites unchanged — every new parameter defaults to a
behaviour-preserving value.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Add `Grouping` enum to `TransactionListView` (storage + plumbing)

**Files:**
- Modify: `Features/Transactions/Views/TransactionListView.swift`

This task adds the type + parameter only. Behavioural plumbing (sectioning, Pay menu, in-progress visual, scheduled Add label, empty state) is in Task 3.

- [ ] **Step 1: Add the `Grouping` enum and a stored property**

At the top of `TransactionListView` (after the `struct TransactionListView: View {` line and before the existing `let title:` declaration), add:

```swift
/// Grouping for the rendered list. Default `.flat` keeps existing
/// callers unchanged. `.scheduledStatus` bundles a `pendingPayId`
/// binding that the row's Pay action writes into; the binding is
/// structurally required when the caller selects that case (no
/// `Binding<>` defaults to silently-discarding `.constant(nil)`).
///
/// Grouping is @MainActor-only; do not add Sendable conformance —
/// `Binding<T>`'s closures are MainActor-isolated.
enum Grouping {
  case flat
  case byDate
  case scheduledStatus(today: Date, pendingPayId: Binding<Transaction.ID?>)
}

let grouping: Grouping
```

- [ ] **Step 2: Add `grouping: Grouping = .flat` to BOTH inits**

Default init (currently around line 86-114 of the de-genericized file):
- Add `grouping: Grouping = .flat` as the LAST parameter before `selectedTransaction` (which doesn't exist on this init) — i.e., add it as the last parameter.
- In the body, assign `self.grouping = grouping`.

Embedded init (currently around line 116-147):
- Add `grouping: Grouping = .flat` after `registrationsVersion: Int = 0` and before `selectedTransaction: Binding<Transaction?>`.
- In the body, assign `self.grouping = grouping`.

- [ ] **Step 3: Build (parameter is unused; build should be clean)**

```bash
just --justfile /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-pr4/justfile \
     --working-directory /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-pr4 \
     build-mac 2>&1 | tee /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-pr4/.agent-tmp/build-task2.txt | tail -10
```

Expected: clean build. Existing call sites pick up `.flat` via the default.

- [ ] **Step 4: Commit**

```bash
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-pr4 \
    add Features/Transactions/Views/TransactionListView.swift

git -C /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-pr4 \
    commit -m "$(cat <<'EOF'
feat(transactions): TransactionListView gains Grouping enum + parameter

Adds a non-optional `grouping: Grouping = .flat` parameter to both
inits. `Grouping` cases:

  - `.flat` — today's single ungrouped list (the default).
  - `.byDate` — grouped by transaction date.
  - `.scheduledStatus(today:, pendingPayId:)` — Overdue / Upcoming
    sections, with a `Binding<Transaction.ID?>` bundled into the case
    so the caller can't construct `.scheduledStatus` without supplying
    the binding (eliminates the `.constant(nil)` silent-discard
    footgun by construction).

Comment at the declaration site marks the enum as `@MainActor`-only —
do not add Sendable conformance, because `Binding<T>`'s closures are
MainActor-isolated.

Storage and parameter only — sectioning, Pay menu, in-progress visual,
and the scheduled-aware Add toolbar button land in the next commit.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Wire `Grouping.scheduledStatus` behaviour into `TransactionListView+List`

**Files:**
- Modify: `Features/Transactions/Views/TransactionListView+List.swift`

This is the substantive behavioural change. All conditional on `grouping`.

- [ ] **Step 1: Read the current file**

The existing `+List` extension contains `listView`, `transactionsList` (the `List(selection:) { ForEach { transactionRow } loadMoreFooter }`), `transactionRow(for:)`, `rowContextMenu(for:)`, `loadMoreFooter`, `emptyStateOverlay`, plus the `TransactionListCSVImportAddons` view modifier and the `PositionsTaskKey` struct.

Read it before editing — the file is ~299 lines.

- [ ] **Step 2: Add a helper that returns the rows for the active grouping**

```swift
/// Returns the rows the list should render under the current grouping.
/// `.flat` and `.byDate` both fall back to the existing flat path
/// (`filteredTransactions`); `.scheduledStatus` reads the store's
/// pre-computed `scheduledOverdueTransactions` /
/// `scheduledUpcomingTransactions` paths.
private struct GroupedRows {
  let overdue: [TransactionWithBalance]
  let upcoming: [TransactionWithBalance]
  let flat: [TransactionWithBalance]
}

private var groupedRows: GroupedRows {
  switch grouping {
  case .flat, .byDate:
    return GroupedRows(overdue: [], upcoming: [], flat: filteredTransactions)
  case .scheduledStatus:
    return GroupedRows(
      overdue: transactionStore.scheduledOverdueTransactions,
      upcoming: transactionStore.scheduledUpcomingTransactions,
      flat: [])
  }
}
```

(Note: `.byDate` is included in the type but not yet rendered specially. PR-4's scope is the `.scheduledStatus` case; `.byDate` falls back to flat for now and gets full sectioning in a future PR. The case exists in the type because it's a planned future expansion explicitly named in the design spec.)

- [ ] **Step 3: Branch `transactionsList` on grouping**

Replace the existing `private var transactionsList: some View { List(selection:) { ForEach { ... } loadMoreFooter } ... }` with a branched version:

```swift
@ViewBuilder private var transactionsList: some View {
  switch grouping {
  case .flat, .byDate:
    flatList
  case .scheduledStatus(let today, _):
    scheduledList(today: today)
  }
}

private var flatList: some View {
  List(selection: selectedTransactionBinding) {
    ForEach(filteredTransactions) { entry in
      transactionRow(for: entry)
    }
    loadMoreFooter
  }
  // … existing modifiers from the current `transactionsList` body
  // (listStyle / accessibilityIdentifier / profileNavigationTitle /
  // toolbar / sheet / onChange / .task / .refreshable / .searchable /
  // overlay) all stay attached here, IDENTICAL to the current code.
}

private func scheduledList(today: Date) -> some View {
  let rows = groupedRows
  return List(selection: selectedTransactionBinding) {
    if !rows.overdue.isEmpty {
      Section("Overdue") {
        ForEach(rows.overdue) { entry in
          transactionRow(for: entry)
        }
      }
    }
    if !rows.upcoming.isEmpty {
      Section("Upcoming") {
        ForEach(rows.upcoming) { entry in
          transactionRow(for: entry)
        }
      }
    }
  }
  // Apply the same modifier set as `flatList` above (listStyle, identifier,
  // profileNavigationTitle, toolbar, etc.) — copy them.
  // The toolbar's Add button uses `createNewScheduledTransaction()` instead
  // of `createNewTransaction()` (see Step 5).
  // The `.searchable` modifier still applies — search across overdue and
  // upcoming together is fine.
}
```

The two functions duplicate the modifier chain. To avoid drift, factor the modifier chain into a shared `ViewModifier` (e.g., `TransactionsListModifiers`) that both `flatList` and `scheduledList` apply. The implementer can choose the right factoring — the goal is one definition of "the standard transactions-list modifier set" so future modifier additions don't have to be made in two places.

- [ ] **Step 4: Update `transactionRow(for:)` to thread the new flags**

```swift
@ViewBuilder
private func transactionRow(for entry: TransactionWithBalance) -> some View {
  let isScheduled: Bool
  let isOverdueRow: Bool
  let isDueTodayRow: Bool
  let onPayClosure: (() -> Void)?
  let pendingPayIdValue: Transaction.ID?

  switch grouping {
  case .flat, .byDate:
    isScheduled = false
    isOverdueRow = false
    isDueTodayRow = false
    onPayClosure = nil
    pendingPayIdValue = nil
  case .scheduledStatus(let today, let pendingPayId):
    isScheduled = true
    isOverdueRow = transactionStore.scheduledOverdueTransactions.contains {
      $0.transaction.id == entry.transaction.id
    }
    isDueTodayRow = !isOverdueRow && Calendar.current.isDate(entry.transaction.date, inSameDayAs: today)
    pendingPayIdValue = pendingPayId.wrappedValue
    onPayClosure = {
      pendingPayId.wrappedValue = entry.transaction.id
    }
  }

  TransactionRowView(
    transaction: entry.transaction, accounts: accounts,
    categories: categories, earmarks: earmarks, displayAmounts: entry.displayAmounts,
    balance: entry.balance, scopeReferenceInstrument: scopeReferenceInstrument,
    hideEarmark: filter.earmarkId != nil, viewingAccountId: filter.accountId,
    isOverdue: isOverdueRow,
    isDueToday: isDueTodayRow,
    onPay: onPayClosure,
    pendingPayId: pendingPayIdValue
  )
  .tag(entry.transaction)
  .accessibilityIdentifier(
    UITestIdentifiers.TransactionList.transaction(entry.transaction.id)
  )
  .contentShape(Rectangle())
  .contextMenu { rowContextMenu(for: entry.transaction, isScheduled: isScheduled) }
  .swipeActions(edge: .trailing) {
    Button(role: .destructive) {
      transactionPendingDelete = entry.transaction.id
    } label: {
      Label("Delete Transaction", systemImage: "trash")
    }
  }
  .swipeActions(edge: .leading) {
    if isScheduled, case .scheduledStatus(_, let pendingPayId) = grouping {
      Button {
        pendingPayId.wrappedValue = entry.transaction.id
      } label: {
        Label("Pay Scheduled Transaction", systemImage: "checkmark.circle")
      }
      .tint(.green)
    }
  }
  .task {
    if entry.id == transactionStore.transactions.last?.id {
      await transactionStore.loadMore()
    }
  }
}
```

The `.task { loadMore }` modifier may not be needed for scheduled rows (the scheduled paths are computed properties, not paginated), but leaving it on every row is harmless — `transactionStore.transactions.last?.id` won't match a scheduled-only row's id during scheduled mode.

Update `rowContextMenu(for:)` to take `isScheduled: Bool`:

```swift
@ViewBuilder
private func rowContextMenu(for transaction: Transaction, isScheduled: Bool) -> some View {
  if isScheduled, case .scheduledStatus(_, let pendingPayId) = grouping {
    Button("Pay Scheduled Transaction\u{2026}", systemImage: "checkmark.circle") {
      pendingPayId.wrappedValue = transaction.id
    }
  }
  Button("Edit Transaction\u{2026}", systemImage: "pencil") {
    selectedTransaction = transaction
  }
  if transaction.importOrigin != nil {
    Button("Create rule from this\u{2026}", systemImage: "plus.rectangle.on.folder") {
      createRuleFromTransaction = transaction
    }
  }
  Divider()
  Button("Delete Transaction\u{2026}", systemImage: "trash", role: .destructive) {
    transactionPendingDelete = transaction.id
  }
}
```

- [ ] **Step 5: Make the Add toolbar button scheduled-aware**

In the existing toolbar declaration (currently a `ToolbarItem(placement: .primaryAction)` with a Button labelled "Add Transaction" / `plus`), branch on grouping:

```swift
ToolbarItem(placement: .primaryAction) {
  Button {
    if case .scheduledStatus = grouping {
      createNewScheduledTransaction()
    } else {
      createNewTransaction()
    }
  } label: {
    if case .scheduledStatus = grouping {
      Label("Add Scheduled Transaction", systemImage: "calendar.badge.plus")
    } else {
      Label("Add Transaction", systemImage: "plus")
    }
  }
}
```

Add `createNewScheduledTransaction()` to `TransactionListView` (in the main `.swift` file). Implementation matches `UpcomingView.createNewScheduledTransaction()` lines 170-192 of the pre-PR file: build a placeholder with `recurPeriod: .month, recurEvery: 1`, set `selectedTransaction` to it, persist via `transactionStore.create(_:)`. Use the same fallback-account logic as `createNewTransaction()`.

- [ ] **Step 6: Make the empty state scheduled-aware**

Update `emptyStateOverlay`'s "no transactions loaded at all, no filter, no search" arm — when `grouping` is `.scheduledStatus`, render:

```swift
ContentUnavailableView(
  "No Scheduled Transactions",
  systemImage: "calendar",
  description: Text(
    PlatformActionVerb.emptyStatePrompt(
      buttonLabel: "+",
      suffix: "to add a recurring transaction.")))
```

- [ ] **Step 7: Format + build + test**

```bash
just --justfile /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-pr4/justfile \
     --working-directory /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-pr4 \
     format

just --justfile /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-pr4/justfile \
     --working-directory /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-pr4 \
     format-check 2>&1 | tail -5

just --justfile /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-pr4/justfile \
     --working-directory /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-pr4 \
     build-mac 2>&1 | tee /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-pr4/.agent-tmp/build-task3.txt | tail -10

just --justfile /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-pr4/justfile \
     --working-directory /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-pr4 \
     test 2>&1 | tee /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-pr4/.agent-tmp/test-task3.txt | tail -10
```

Expected: clean build, format-check green, full test suite passes (no caller is using `.scheduledStatus` yet — `UpcomingView` migrates in Task 4 — so the new code path is dead but type-checked).

- [ ] **Step 8: Commit**

```bash
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-pr4 \
    add Features/Transactions/Views/TransactionListView+List.swift Features/Transactions/Views/TransactionListView.swift

git -C /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-pr4 \
    commit -m "$(cat <<'EOF'
feat(transactions): TransactionListView wires .scheduledStatus grouping behaviour

Implements the .scheduledStatus path inside the existing
TransactionListView pipeline:

  - sections rows into Overdue / Upcoming via the store's
    `scheduledOverdueTransactions` / `scheduledUpcomingTransactions`
    paths, with the same modifier set as the flat list (factored to
    avoid drift),
  - threads `isOverdue` / `isDueToday` flags + `onPay` closure +
    `pendingPayId` value into TransactionRowView so the row renders
    the scheduled-specific UX (red overdue, orange due-today, inline
    Pay button or in-progress ProgressView),
  - adds a "Pay Scheduled Transaction…" context-menu item and a
    leading-swipe Pay action that write the row id into the case's
    `pendingPayId: Binding<Transaction.ID?>`,
  - dynamically labels the Add toolbar button "Add Scheduled
    Transaction" / `calendar.badge.plus` and creates a recurring
    placeholder via `createNewScheduledTransaction()` when grouping is
    `.scheduledStatus`,
  - swaps the empty-state copy to "No Scheduled Transactions" when
    appropriate.

The .flat / .byDate cases continue to use the existing flat path; no
behaviour change for current callers. UpcomingView migration is the
next commit.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Migrate `UpcomingView` and delete `UpcomingTransactionRow`

**Files:**
- Modify: `Features/Transactions/Views/UpcomingView.swift`
- Delete: `Features/Transactions/Views/UpcomingTransactionRow.swift`

- [ ] **Step 1: Replace `UpcomingView`'s body**

Drop the hand-rolled `listView`, `overdueSection`, `upcomingSection`, `row(for:isOverdue:)`, `rowContextMenu(for:)`, and `overdueTransactions` / `upcomingTransactions` / `isDueToday(_:)` helpers. Keep `payTransaction(_:)`, `createNewScheduledTransaction()` (move to TransactionListView in Task 3 — actually the design has it now in TransactionListView; UpcomingView no longer needs its own since TransactionListView's Add button handles it via grouping).

Actually — check Task 3 Step 5: `createNewScheduledTransaction()` was added to `TransactionListView`. So `UpcomingView`'s copy can be deleted.

The `.focusedSceneValue(\.newTransactionAction, createNewScheduledTransaction)` exposure: `TransactionListView` already publishes `\.newTransactionAction` via its own `createNewTransaction()` / `createNewScheduledTransaction()` switch (line 176 of TransactionListView.swift today). So UpcomingView no longer needs to publish it.

New `UpcomingView`:

```swift
import SwiftUI

struct UpcomingView: View {
  let accounts: Accounts
  let categories: Categories
  let earmarks: Earmarks
  let transactionStore: TransactionStore

  @State private var selectedTransaction: Transaction?
  @State private var pendingPayId: Transaction.ID?
  @State private var transactionPendingDelete: Transaction.ID?

  var body: some View {
    TransactionListView(
      title: "Upcoming",
      filter: TransactionFilter(scheduled: .scheduledOnly),
      accounts: accounts,
      categories: categories,
      earmarks: earmarks,
      transactionStore: transactionStore,
      grouping: .scheduledStatus(today: Date(), pendingPayId: $pendingPayId),
      selectedTransaction: $selectedTransaction
    )
    .transactionInspector(
      selectedTransaction: $selectedTransaction,
      accounts: accounts,
      categories: categories,
      earmarks: earmarks,
      transactionStore: transactionStore,
      showRecurrence: true
    )
    .focusedSceneValue(\.selectedTransaction, $selectedTransaction)
    .onChange(of: pendingPayId) { _, newId in
      guard let id = newId,
        let match = transactionStore.transactions.first(where: { $0.transaction.id == id })
      else { return }
      Task {
        await payTransaction(match.transaction)
        await MainActor.run { pendingPayId = nil }
      }
    }
    .confirmationDialog(
      "Delete this transaction?",
      isPresented: Binding(
        get: { transactionPendingDelete != nil },
        set: { if !$0 { transactionPendingDelete = nil } }
      ),
      titleVisibility: .visible
    ) {
      Button("Delete Transaction", role: .destructive) {
        if let id = transactionPendingDelete {
          Task { await transactionStore.delete(id: id) }
        }
        transactionPendingDelete = nil
      }
      Button("Cancel", role: .cancel) { transactionPendingDelete = nil }
    } message: {
      Text("This action cannot be undone.")
    }
    .onReceive(NotificationCenter.default.publisher(for: .requestTransactionEdit)) { note in
      guard let id = note.object as? Transaction.ID,
        let match = transactionStore.transactions.first(where: { $0.transaction.id == id })
      else { return }
      selectedTransaction = match.transaction
    }
    .onReceive(NotificationCenter.default.publisher(for: .requestTransactionDelete)) { note in
      guard let id = note.object as? Transaction.ID,
        transactionStore.transactions.contains(where: { $0.transaction.id == id })
      else { return }
      transactionPendingDelete = id
    }
    // Per design §10, .requestTransactionPay handler also stays —
    // window-menu commands need a path to trigger Pay on the visible
    // leaf. Routes through the same pendingPayId binding so the
    // in-progress visual fires.
    .onReceive(NotificationCenter.default.publisher(for: .requestTransactionPay)) { note in
      guard let id = note.object as? Transaction.ID,
        transactionStore.transactions.contains(where: { $0.transaction.id == id })
      else { return }
      pendingPayId = id
    }
  }

  private func payTransaction(_ scheduledTransaction: Transaction) async {
    let result = await transactionStore.payScheduledTransaction(scheduledTransaction)
    switch result {
    case .paid(let updated):
      selectedTransaction = updated
    case .deleted:
      selectedTransaction = nil
    case .failed:
      break
    }
  }
}
```

The `#Preview` at the bottom of the file stays — it now exercises the migrated path.

- [ ] **Step 2: Delete `UpcomingTransactionRow.swift`**

```bash
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-pr4 \
    rm Features/Transactions/Views/UpcomingTransactionRow.swift
```

- [ ] **Step 3: Regenerate (drops the deleted file from the Xcode project)**

```bash
just --justfile /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-pr4/justfile \
     --working-directory /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-pr4 \
     generate 2>&1 | tail -5
```

- [ ] **Step 4: Format + build + test**

```bash
just --justfile /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-pr4/justfile \
     --working-directory /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-pr4 \
     format

just --justfile /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-pr4/justfile \
     --working-directory /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-pr4 \
     format-check 2>&1 | tail -5

just --justfile /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-pr4/justfile \
     --working-directory /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-pr4 \
     build-mac 2>&1 | tee /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-pr4/.agent-tmp/build-task4.txt | tail -10

just --justfile /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-pr4/justfile \
     --working-directory /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-pr4 \
     test 2>&1 | tee /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-pr4/.agent-tmp/test-task4.txt | tail -10
```

Expected: clean build, format-check green, full test suite passes. Any UpcomingView-specific tests should adapt automatically because the public API (the `UpcomingView` struct's parameters) is unchanged; only the internals migrated.

- [ ] **Step 5: Commit**

```bash
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-pr4 \
    add Features/Transactions/Views/UpcomingView.swift

git -C /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-pr4 \
    commit -m "$(cat <<'EOF'
refactor(transactions): UpcomingView migrates to TransactionListView

UpcomingView shrinks from a hand-rolled `List(selection:)` with
overdue/upcoming sections and a custom `UpcomingTransactionRow` to a
thin wrapper around `TransactionListView` with
`grouping: .scheduledStatus(today: Date(), pendingPayId: $pendingPayId)`.

UpcomingTransactionRow.swift is deleted — its overdue / due-today /
recurrence / inline-Pay UX folded into TransactionRowView in commit 1
of this PR via optional parameters that default to behaviour-
preserving values.

Pay flow: the leaf observes `pendingPayId` via `.onChange(of:)` and
runs the existing `payTransaction(_:)` flow, then resets the binding
to nil. Same-view dispatch via a typed `Binding<>` rather than
`NotificationCenter` keeps the path on @MainActor and Sendable-clean.

The pre-existing `.requestTransactionEdit` / `.requestTransactionDelete`
/ `.requestTransactionPay` notification handlers stay (cross-view
dispatch from window menus — out of scope, tracked as #826). The Pay
notification now routes through the pendingPayId binding so the
in-progress visual fires regardless of trigger source.

Behaviour-preserving for users — full test suite green.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Pre-PR review pass

- [ ] **Step 1: Run `code-review` agent**

Dispatch with prompt covering: Grouping enum (Sendable-correctness, naming), TransactionRowView's new parameters (defaults preserve existing behaviour), TransactionListView+List's grouping branches (no drift between `flatList` and `scheduledList` modifier sets), UpcomingView's migration (notification handlers preserved, pendingPayId routing).

Fix every Critical and Important finding before pushing.

- [ ] **Step 2: Run `ui-review` agent**

Dispatch with prompt covering: visual equivalence of overdue / due-today / recurrence rendering vs the deleted UpcomingTransactionRow; in-progress ProgressView placement and accessibility label; toolbar Add button label and icon switch under .scheduledStatus; empty-state copy; sectioning behaviour.

Fix every Critical and Important finding before pushing.

---

## Task 6: Push and open PR

- [ ] **Step 1: Push with explicit src:dst**

```bash
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-pr4 \
    push origin worktree-detail-view-structural-fix-pr4:worktree-detail-view-structural-fix-pr4 2>&1 | tail -5
```

- [ ] **Step 2: Open the PR**

Base `main`. Body explains the Grouping enum addition, the UpcomingView migration, the UpcomingTransactionRow deletion, and the stacking on PR-3.

- [ ] **Step 3: Add to merge queue**

```bash
PR_NUMBER=$(gh -R ajsutton/moolah-native pr list --head worktree-detail-view-structural-fix-pr4 --json number --jq '.[0].number')
~/.claude/skills/merge-queue/scripts/merge-queue-ctl.sh add "$PR_NUMBER" 2>&1 | tail -3
```

---

## Plan complete

PR-4 in flight. PR-5 (multi-instrument positions split move out of `TransactionListView` into `StandardAccountView`) gets its own plan once PR-4 is open.
