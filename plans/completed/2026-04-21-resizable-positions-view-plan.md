# Resizable Positions View Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the positions panel shown above transactions a user-adjustable vertical split on macOS (with persisted divider position) and a segmented tab swap on iOS, defaulting to ~5 instrument rows.

**Architecture:** A new `ResizableVSplit` view wraps `NSSplitView` (macOS only) to give a native resizable divider with autosaved position. A shared `PositionsTransactionsSplit` container picks between `ResizableVSplit` on macOS and a segmented `Picker` on iOS, so the two call sites (`TransactionListView` when positions are present, and `InvestmentAccountView`) don't need platform conditionals of their own.

**Tech Stack:** SwiftUI, AppKit (`NSSplitView`, `NSHostingView`), xcodegen.

---

## File Structure

Two new files and two modified:

- **Create** `Shared/Views/ResizableVSplit.swift` — macOS-only `NSViewRepresentable` wrapping `NSSplitView`. Autosaved divider position via `autosaveName`. Enforces min top/bottom pane sizes via an `NSSplitViewDelegate`. Hosts two generic SwiftUI child views through `NSHostingView`.
- **Create** `Shared/Views/Positions/PositionsTransactionsSplit.swift` — shared container that switches between `ResizableVSplit` (macOS) and a segmented `Picker` (iOS). Takes a default-tab parameter so the caller controls initial iOS selection.
- **Modify** `Features/Transactions/Views/TransactionListView.swift` — extract existing `List(selection:) { … }` block into a private `transactionsList` computed property, then rewrite `listView` to wrap with `PositionsTransactionsSplit` when `positionsInput` has positions.
- **Modify** `Features/Investments/Views/InvestmentAccountView.swift` — wrap the non-legacy branch (`PositionsView` + embedded `TransactionListView`) in `PositionsTransactionsSplit(defaultTab: .positions)`. Drop the inline `Divider()` between panes.

`project.yml` globs `Shared/**` and `Features/**` (confirmed via existing structure), so the new files are picked up automatically by xcodegen; no project.yml edit is required unless the build log disagrees.

---

## Task 1: Create `ResizableVSplit` (macOS)

**Files:**
- Create: `Shared/Views/ResizableVSplit.swift`

- [ ] **Step 1: Create the file with the full implementation**

```swift
import SwiftUI

#if os(macOS)
  import AppKit

  /// A vertical split (panes stacked, divider horizontal) backed by
  /// `NSSplitView` so the divider position can be autosaved in
  /// `UserDefaults`. SwiftUI's `VSplitView` has no binding for the
  /// divider position and doesn't persist it — hence the AppKit wrap.
  ///
  /// - Parameters:
  ///   - autosaveName: Key under which `NSSplitView` persists the
  ///     divider position. One shared name across all call sites means
  ///     the user's preferred size applies everywhere.
  ///   - initialTopHeight: Height used for the top pane on the very
  ///     first display, before any autosaved frame exists.
  ///   - minTopHeight: Minimum height of the top pane when dragging.
  ///   - minBottomHeight: Minimum height of the bottom pane.
  ///   - top: The top pane content.
  ///   - bottom: The bottom pane content.
  struct ResizableVSplit<Top: View, Bottom: View>: NSViewRepresentable {
    let autosaveName: String
    let initialTopHeight: CGFloat
    let minTopHeight: CGFloat
    let minBottomHeight: CGFloat
    let top: () -> Top
    let bottom: () -> Bottom

    init(
      autosaveName: String,
      initialTopHeight: CGFloat,
      minTopHeight: CGFloat = 80,
      minBottomHeight: CGFloat = 200,
      @ViewBuilder top: @escaping () -> Top,
      @ViewBuilder bottom: @escaping () -> Bottom
    ) {
      self.autosaveName = autosaveName
      self.initialTopHeight = initialTopHeight
      self.minTopHeight = minTopHeight
      self.minBottomHeight = minBottomHeight
      self.top = top
      self.bottom = bottom
    }

    func makeCoordinator() -> Coordinator {
      Coordinator(
        minTopHeight: minTopHeight,
        minBottomHeight: minBottomHeight
      )
    }

    func makeNSView(context: Context) -> NSSplitView {
      let split = NSSplitView()
      split.isVertical = false
      split.dividerStyle = .thin
      split.delegate = context.coordinator

      let topHost = NSHostingView(rootView: top())
      let bottomHost = NSHostingView(rootView: bottom())
      topHost.translatesAutoresizingMaskIntoConstraints = false
      bottomHost.translatesAutoresizingMaskIntoConstraints = false

      split.addArrangedSubview(topHost)
      split.addArrangedSubview(bottomHost)

      context.coordinator.topHost = topHost
      context.coordinator.bottomHost = bottomHost

      // Order matters: autosaveName triggers a restore attempt, so we
      // only apply the initial height when no saved frame exists yet.
      let hasSavedFrames =
        UserDefaults.standard.object(
          forKey: "NSSplitView Subview Frames \(autosaveName)") != nil
      split.autosaveName = autosaveName

      if !hasSavedFrames {
        let height = initialTopHeight
        DispatchQueue.main.async { [weak split] in
          split?.setPosition(height, ofDividerAt: 0)
        }
      }

      return split
    }

    func updateNSView(_ nsView: NSSplitView, context: Context) {
      context.coordinator.topHost?.rootView = top()
      context.coordinator.bottomHost?.rootView = bottom()
    }

    @MainActor
    final class Coordinator: NSObject, NSSplitViewDelegate {
      var topHost: NSHostingView<Top>?
      var bottomHost: NSHostingView<Bottom>?
      let minTopHeight: CGFloat
      let minBottomHeight: CGFloat

      init(minTopHeight: CGFloat, minBottomHeight: CGFloat) {
        self.minTopHeight = minTopHeight
        self.minBottomHeight = minBottomHeight
      }

      func splitView(
        _ splitView: NSSplitView,
        constrainMinCoordinate proposedMinimumPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
      ) -> CGFloat {
        max(proposedMinimumPosition, minTopHeight)
      }

      func splitView(
        _ splitView: NSSplitView,
        constrainMaxCoordinate proposedMaximumPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
      ) -> CGFloat {
        min(proposedMaximumPosition, splitView.bounds.height - minBottomHeight)
      }
    }
  }

  #Preview("Split") {
    ResizableVSplit(
      autosaveName: "preview-resizable-vsplit",
      initialTopHeight: 180
    ) {
      Color.blue.opacity(0.2).overlay(Text("Top"))
    } bottom: {
      Color.green.opacity(0.2).overlay(Text("Bottom"))
    }
    .frame(width: 480, height: 480)
  }
#endif
```

- [ ] **Step 2: Build macOS**

Run: `just build-mac 2>&1 | tee .agent-tmp/build-mac.txt`
Expected: Build succeeds with no warnings. If it fails, read the output and fix before proceeding.

- [ ] **Step 3: Verify no warnings**

Run: `grep -iE 'warning:|error:' .agent-tmp/build-mac.txt`
Expected: No output other than Xcode noise (e.g., SDK deprecation notices about symbols Moolah doesn't touch). Any warning in Moolah code must be fixed — the project has `SWIFT_TREAT_WARNINGS_AS_ERRORS: YES`.

- [ ] **Step 4: Commit**

```bash
git -C .worktrees/resizable-positions-view add Shared/Views/ResizableVSplit.swift
git -C .worktrees/resizable-positions-view commit -m "feat(shared): add ResizableVSplit NSSplitView wrapper"
```

---

## Task 2: Create `PositionsTransactionsSplit`

**Files:**
- Create: `Shared/Views/Positions/PositionsTransactionsSplit.swift`

- [ ] **Step 1: Create the file with the full implementation**

```swift
import SwiftUI

/// Container that presents a positions panel together with a transactions
/// list. On macOS, uses a native `NSSplitView` with an autosaved divider
/// position so the user can resize and the size sticks. On iOS, stacking
/// the two panes leaves neither with enough room, so a segmented picker
/// swaps between them.
struct PositionsTransactionsSplit<Positions: View, Transactions: View>: View {
  enum DefaultTab { case positions, transactions }

  let defaultTab: DefaultTab
  @ViewBuilder let positions: () -> Positions
  @ViewBuilder let transactions: () -> Transactions

  #if !os(macOS)
    @State private var selectedTab: DefaultTab
  #endif

  init(
    defaultTab: DefaultTab,
    @ViewBuilder positions: @escaping () -> Positions,
    @ViewBuilder transactions: @escaping () -> Transactions
  ) {
    self.defaultTab = defaultTab
    self.positions = positions
    self.transactions = transactions
    #if !os(macOS)
      _selectedTab = State(initialValue: defaultTab)
    #endif
  }

  var body: some View {
    #if os(macOS)
      ResizableVSplit(
        autosaveName: "positions-transactions-split",
        initialTopHeight: 180
      ) {
        positions()
      } bottom: {
        transactions()
      }
    #else
      VStack(spacing: 0) {
        Picker("View", selection: $selectedTab) {
          Text("Positions").tag(DefaultTab.positions)
          Text("Transactions").tag(DefaultTab.transactions)
        }
        .pickerStyle(.segmented)
        .padding(.horizontal)
        .padding(.vertical, 8)

        Divider()

        switch selectedTab {
        case .positions: positions()
        case .transactions: transactions()
        }
      }
    #endif
  }
}

#Preview("Default: transactions") {
  PositionsTransactionsSplit(defaultTab: .transactions) {
    Color.blue.opacity(0.2).overlay(Text("Positions pane"))
  } transactions: {
    Color.green.opacity(0.2).overlay(Text("Transactions pane"))
  }
  .frame(width: 480, height: 480)
}

#Preview("Default: positions") {
  PositionsTransactionsSplit(defaultTab: .positions) {
    Color.blue.opacity(0.2).overlay(Text("Positions pane"))
  } transactions: {
    Color.green.opacity(0.2).overlay(Text("Transactions pane"))
  }
  .frame(width: 480, height: 480)
}
```

- [ ] **Step 2: Build macOS and iOS**

```bash
just build-mac 2>&1 | tee .agent-tmp/build-mac.txt
just build-ios 2>&1 | tee .agent-tmp/build-ios.txt
```

Expected: Both builds succeed with no warnings in Moolah code.

- [ ] **Step 3: Verify no warnings**

```bash
grep -iE 'warning:|error:' .agent-tmp/build-mac.txt
grep -iE 'warning:|error:' .agent-tmp/build-ios.txt
```

Fix any warning in Moolah code before proceeding.

- [ ] **Step 4: Commit**

```bash
git -C .worktrees/resizable-positions-view add Shared/Views/Positions/PositionsTransactionsSplit.swift
git -C .worktrees/resizable-positions-view commit -m "feat(positions): add PositionsTransactionsSplit container"
```

---

## Task 3: Extract `transactionsList` in `TransactionListView`

A pure refactor to prepare Task 4. The behaviour must not change: the transactions `List` including its loading footer and all modifiers moves verbatim into a computed property.

**Files:**
- Modify: `Features/Transactions/Views/TransactionListView.swift` (the `listView` property around line 258).

- [ ] **Step 1: Inspect the current `listView` to find its full extent**

Read the file starting at line 258 and determine where the VStack ends (look for the matching `}` at the outer list-view scope). The `listView` block is approximately lines 258 through ~370; confirm the exact range before editing.

- [ ] **Step 2: Rewrite `listView` and add a new `transactionsList` property**

Locate the existing `listView` computed property. It currently starts with:

```swift
private var listView: some View {
  VStack(spacing: 0) {
    if let positionsInput, !positionsInput.positions.isEmpty {
      PositionsView(input: positionsInput, range: $positionsRange)
      Divider()
    }
    List(selection: selectedTransactionBinding) {
      // … rows and loading footer …
    }
    // … any list modifiers trailing the List …
  }
}
```

Change it to:

```swift
private var listView: some View {
  VStack(spacing: 0) {
    if let positionsInput, !positionsInput.positions.isEmpty {
      PositionsView(input: positionsInput, range: $positionsRange)
      Divider()
    }
    transactionsList
  }
}

private var transactionsList: some View {
  List(selection: selectedTransactionBinding) {
    // … rows and loading footer — unchanged from what was inside the VStack …
  }
  // … any list modifiers trailing the List — unchanged …
}
```

The inner `List(selection:) { … }` and every modifier that was chained onto it must move intact into `transactionsList`. Do not change any behaviour, accessibility identifiers, or modifiers. The only diff is indentation plus the new property boundary.

- [ ] **Step 3: Build macOS and iOS**

```bash
just build-mac 2>&1 | tee .agent-tmp/build-mac.txt
just build-ios 2>&1 | tee .agent-tmp/build-ios.txt
```

Expected: Both builds succeed with no warnings.

- [ ] **Step 4: Run test suite**

```bash
just test 2>&1 | tee .agent-tmp/test.txt
grep -iE 'failed|error:' .agent-tmp/test.txt
```

Expected: All tests pass. This refactor is behaviour-preserving; any failure means the extraction was not verbatim.

- [ ] **Step 5: Commit**

```bash
git -C .worktrees/resizable-positions-view add Features/Transactions/Views/TransactionListView.swift
git -C .worktrees/resizable-positions-view commit -m "refactor(transactions): extract transactionsList from listView"
```

---

## Task 4: Integrate split into `TransactionListView`

**Files:**
- Modify: `Features/Transactions/Views/TransactionListView.swift` — the `listView` property.

- [ ] **Step 1: Replace `listView` with the split-aware version**

Change `listView` to:

```swift
private var listView: some View {
  if let positionsInput, !positionsInput.positions.isEmpty {
    PositionsTransactionsSplit(defaultTab: .transactions) {
      PositionsView(input: positionsInput, range: $positionsRange)
    } transactions: {
      transactionsList
    }
  } else {
    transactionsList
  }
}
```

Remove the outer `VStack(spacing: 0)` and the inline `Divider()` that previously separated the positions panel from the list — both jobs are now done by `PositionsTransactionsSplit`.

If the compiler complains about `some View` due to the if/else returning different underlying types, wrap with `@ViewBuilder`:

```swift
@ViewBuilder
private var listView: some View {
  …
}
```

- [ ] **Step 2: Build macOS and iOS**

```bash
just build-mac 2>&1 | tee .agent-tmp/build-mac.txt
just build-ios 2>&1 | tee .agent-tmp/build-ios.txt
```

Expected: Both builds succeed with no warnings.

- [ ] **Step 3: Run test suite**

```bash
just test 2>&1 | tee .agent-tmp/test.txt
grep -iE 'failed|error:' .agent-tmp/test.txt
```

Expected: All tests pass.

- [ ] **Step 4: Commit**

```bash
git -C .worktrees/resizable-positions-view add Features/Transactions/Views/TransactionListView.swift
git -C .worktrees/resizable-positions-view commit -m "feat(transactions): wrap positions + list in PositionsTransactionsSplit"
```

---

## Task 5: Integrate split into `InvestmentAccountView`

**Files:**
- Modify: `Features/Investments/Views/InvestmentAccountView.swift` — the non-legacy branch of `body` (the `else` covering `if investmentStore.hasLegacyValuations`).

- [ ] **Step 1: Rewrite the non-legacy branch**

The current structure is:

```swift
var body: some View {
  VStack(spacing: 0) {
    if investmentStore.hasLegacyValuations {
      // legacy UI — keep untouched
    } else {
      if isLoadingPositions && positionsInput.positions.isEmpty {
        ProgressView().frame(maxWidth: .infinity).padding()
      } else {
        PositionsView(input: positionsInput, range: $positionsRange)
      }
    }

    Divider()

    TransactionListView(
      title: "",
      filter: TransactionFilter(accountId: account.id),
      accounts: accounts,
      categories: categories,
      earmarks: earmarks,
      transactionStore: transactionStore,
      selectedTransaction: $selectedTransaction
    )
  }
  // … modifiers …
}
```

Change it to:

```swift
var body: some View {
  Group {
    if investmentStore.hasLegacyValuations {
      VStack(spacing: 0) {
        // legacy UI — unchanged
        // (keep the existing legacy block contents here)
        Divider()
        TransactionListView(
          title: "",
          filter: TransactionFilter(accountId: account.id),
          accounts: accounts,
          categories: categories,
          earmarks: earmarks,
          transactionStore: transactionStore,
          selectedTransaction: $selectedTransaction
        )
      }
    } else {
      PositionsTransactionsSplit(defaultTab: .positions) {
        if isLoadingPositions && positionsInput.positions.isEmpty {
          ProgressView().frame(maxWidth: .infinity).padding()
        } else {
          PositionsView(input: positionsInput, range: $positionsRange)
        }
      } transactions: {
        TransactionListView(
          title: "",
          filter: TransactionFilter(accountId: account.id),
          accounts: accounts,
          categories: categories,
          earmarks: earmarks,
          transactionStore: transactionStore,
          selectedTransaction: $selectedTransaction
        )
      }
    }
  }
  // … existing trailing modifiers (transactionInspector, profileNavigationTitle,
  //     sheet, task, refreshable) stay as-is …
}
```

Key changes:

1. The outer `VStack(spacing: 0)` is replaced by `Group { … }` so each branch can pick its own layout — the legacy branch keeps the `VStack` + `Divider` + `TransactionListView`, the new branch uses `PositionsTransactionsSplit`.
2. In the new branch, the external `Divider()` and the external `TransactionListView` move *inside* `PositionsTransactionsSplit`'s `transactions:` closure; the split owns the boundary.
3. All trailing modifiers (`transactionInspector`, `profileNavigationTitle`, `sheet`, `task(id:)`, `refreshable`) stay attached to the outer view — unchanged.

- [ ] **Step 2: Build macOS and iOS**

```bash
just build-mac 2>&1 | tee .agent-tmp/build-mac.txt
just build-ios 2>&1 | tee .agent-tmp/build-ios.txt
```

Expected: Both builds succeed with no warnings.

- [ ] **Step 3: Run test suite**

```bash
just test 2>&1 | tee .agent-tmp/test.txt
grep -iE 'failed|error:' .agent-tmp/test.txt
```

Expected: All tests pass.

- [ ] **Step 4: Commit**

```bash
git -C .worktrees/resizable-positions-view add Features/Investments/Views/InvestmentAccountView.swift
git -C .worktrees/resizable-positions-view commit -m "feat(investments): wrap positions + transactions in PositionsTransactionsSplit"
```

---

## Task 6: Format, full build, full test

- [ ] **Step 1: Format**

```bash
just format
```

- [ ] **Step 2: Verify formatting clean (CI parity)**

```bash
just format-check
```

Expected: exits 0 (no diff). If not, `just format` left changes — stage and amend? No: commit a new formatting commit.

- [ ] **Step 3: Commit any formatting changes (only if step 2 reported diffs)**

```bash
git -C .worktrees/resizable-positions-view add -A
git -C .worktrees/resizable-positions-view commit -m "style: apply swift-format"
```

- [ ] **Step 4: Final full test run**

```bash
just test 2>&1 | tee .agent-tmp/test.txt
grep -iE 'failed|error:' .agent-tmp/test.txt
```

Expected: All tests pass on both targets.

- [ ] **Step 5: Clean temp files**

```bash
rm -f .agent-tmp/build-mac.txt .agent-tmp/build-ios.txt .agent-tmp/test.txt
```

---

## Task 7: Move design + plan to `plans/completed/`

- [ ] **Step 1: Move docs**

```bash
git -C .worktrees/resizable-positions-view mv plans/2026-04-21-resizable-positions-view-design.md plans/completed/
git -C .worktrees/resizable-positions-view mv plans/2026-04-21-resizable-positions-view-plan.md plans/completed/
```

- [ ] **Step 2: Commit**

```bash
git -C .worktrees/resizable-positions-view commit -m "docs(positions): move resizable-positions-view design + plan to completed"
```

---

## Self-review notes (author)

**Spec coverage:**
- macOS `NSSplitView` with autosave → Task 1.
- iOS segmented picker → Task 2 (embedded in `PositionsTransactionsSplit`).
- Default tab differs per caller → Task 2 API + Tasks 4, 5.
- `TransactionListView` wiring with refactored `transactionsList` → Tasks 3, 4.
- `InvestmentAccountView` wiring, legacy branch untouched → Task 5.
- Divider removal at both call sites → Tasks 4, 5.
- No changes to `PositionsView`, `PositionsTable`, earmarks, reports, all-transactions → verified by absence in file list.

**Type consistency:** `DefaultTab.positions` / `.transactions` used identically in Tasks 2, 4, and 5. `ResizableVSplit` init signature matches the call in `PositionsTransactionsSplit`.

**Placeholders:** None. Every step has concrete code or commands.
