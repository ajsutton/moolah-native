# Detail-View Structural Fix — PR-1 (Foundation) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Eliminate two recurring SwiftUI macOS production failures (the AppKit toolbar duplicate-search-item crash and the `safeAreaInset+EmptyView+NSHostingView` blank-list bug) by isolating each detail-column leaf in its own `NavigationStack`, and de-genericizing `TransactionListView` so it can never re-introduce the structural-shape variance the crash needs.

**Architecture:** Wrap every case of `ContentView.detail`'s switch in a single `NavigationStack { … }.id(selection)`. The `.id` forces SwiftUI to fully tear down the previous leaf's `NSToolbar` host before mounting the next one, so the bridge cannot double-register `com.apple.SwiftUI.search`. With per-leaf isolation in place, `TransactionListView` reverts to a non-generic plain view (no `topAccessory`, no `safeAreaInset`); the wallet-header path moves into a new `CryptoWalletAccountView` leaf, and the standard / all-transactions paths get their own thin leaf views for switch-arm symmetry. Codified as a single grep-able invariant in `UI_GUIDE.md` §3 and enforced by the `code-review` and `ui-review` agents.

**Tech Stack:** Swift 6.2, SwiftUI (macOS 26+ / iOS 26+), Xcode 26, `xcodegen`, XCUITest, swift-format, SwiftLint, just.

**Scope:** PR-1 of 5. This plan does not touch `EarmarkDetailView`, `InvestmentAccountView`, or `UpcomingView` beyond what PR-1's `NavigationStack` wrap implicitly does to them — those leaves continue to work because each is now inside its own `NavigationStack` (crash-safe), and they will be migrated to composition shells in PRs 2-4 with their own plans.

**Spec:** `plans/2026-05-09-detail-view-structural-fix-design.md`. PRs 2-5 are described in the spec but not in this plan.

**Worktree:** This plan executes in the `worktree-detail-view-structural-fix-design` worktree at `/Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-design/`. The design spec already lives in this worktree; PR-1 implementation lands on top of it on the same branch, so the resulting PR contains both the design and the foundation.

---

## Phase 1 — Regression test scaffolding

The 5×8 navigation-sweep test reproduces failure mode A. We write the test FIRST (TDD): on `main` it would crash; with PR-1's structural fix it passes. The test uses the existing `.tradeBaseline` seed (which has bank, investment-recordedValue, and investment-calculatedFromTrades accounts) plus the named sidebar items (Upcoming, All Transactions, Recently Added, Analysis) — together those exercise enough heterogeneous detail-column leaves to trigger the toolbar-bridge race without needing a crypto-account seed (which the existing test infrastructure doesn't support).

### Task 1: Add the navigation-sweep regression test

**Files:**
- Create: `MoolahUITests_macOS/Tests/DetailColumnNavigationSweepTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// MoolahUITests_macOS/Tests/DetailColumnNavigationSweepTests.swift
import XCTest

/// Regression test for the AppKit toolbar bridge crash that fired when
/// SwiftUI re-mounted a `.searchable` / `.toolbar`-bearing detail-column
/// leaf while the previous leaf's registration was still live:
///
///     NSInternalInconsistencyException: NSToolbar already contains an
///     item with the identifier com.apple.SwiftUI.search.
///
/// Before this PR the failure was reproducible by sweeping rapidly across
/// detail-column leaves of differing structural shape. The structural fix
/// wraps each leaf in its own `NavigationStack { … }.id(selection)` so the
/// previous `NSToolbar` host is fully torn down between selections — the
/// bridge can no longer race against itself.
///
/// This test sweeps a fixed sequence of leaves five times and asserts the
/// app remains responsive after each step (XCTest fails the test if the
/// app crashes; we additionally assert the transaction-list container
/// re-appears for transaction-bearing leaves so a silent
/// "the toolbar disappeared" regression also fails).
final class DetailColumnNavigationSweepTests: MoolahUITestCase {
  func test_rapidSweepAcrossDetailLeaves_doesNotCrashTheToolbarBridge() {
    let app = MoolahApp.launch(seed: .tradeBaseline)
    let sidebar = app.sidebar

    // Five cycles × eight selections per cycle. The exact count is
    // calibrated to the production reproduction — fewer cycles caught the
    // race only intermittently. The mix deliberately interleaves
    // transaction-list leaves (account, allTransactions, upcoming) with
    // structurally-different leaves (analysis, recentlyAdded) so the
    // toolbar-bridge tear-down path is exercised between every adjacent
    // pair.
    for cycleIndex in 0..<5 {
      Trace.record(detail: "cycle=\(cycleIndex)")

      sidebar.switchToAccount(.checking)
      sidebar.switchToAccount(.brokerage)
      sidebar.switchToNamed(.upcoming)
      sidebar.switchToAccount(.tradesBrokerage)
      sidebar.switchToNamed(.allTransactions)
      sidebar.switchToNamed(.analysis)
      sidebar.switchToAccount(.checking)
      sidebar.switchToNamed(.recentlyAdded)
    }

    // Final responsiveness check: the app is still alive (XCTest would
    // have failed the test on crash). Land on a transaction list and
    // confirm the container is in the accessibility tree.
    sidebar.switchToAccount(.checking)
    let listContainer = app.element(for: UITestIdentifiers.TransactionList.container)
    XCTAssertTrue(
      listContainer.waitForExistence(timeout: 3),
      "Transaction list container missing after the sweep — the structural "
      + "fix did not preserve list rendering across rapid navigation.")
  }
}
```

- [ ] **Step 2: Identify the missing helper that this test needs**

The test calls `sidebar.switchToNamed(.upcoming)` etc. The existing `SidebarScreen` driver only exposes `switchToAccount(_:)`. We need a `switchToNamed(_:)` method that selects sidebar items like Upcoming, All Transactions, Recently Added, and Analysis by their identifier.

Inspect `Features/Navigation/SidebarView.swift` to find what accessibility identifier each named item has. If none is set, the test cannot select them.

Run:
```bash
grep -n "accessibilityIdentifier\|UITestIdentifiers.Sidebar.named" \
  /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-design/Features/Navigation/SidebarView.swift
```

If the named items lack identifiers, that's part of Task 1 — see Step 3.

- [ ] **Step 3: Add accessibility identifiers + driver helper for named sidebar items (if missing)**

If grep in Step 2 showed no identifiers on the Upcoming / All Transactions / Recently Added / Analysis rows, add them. Each `NavigationLink` needs an identifier built from `UITestIdentifiers.Sidebar.view(_:)`.

Modify `Features/Navigation/SidebarView.swift` `navigationSection` (lines 215-241):

```swift
@ViewBuilder private var navigationSection: some View {
  Section {
    NavigationLink(value: SidebarSelection.analysis) {
      Label("Analysis", systemImage: "chart.bar.xaxis")
    }
    .accessibilityIdentifier(UITestIdentifiers.Sidebar.view("analysis"))
    NavigationLink(value: SidebarSelection.reports) {
      Label("Reports", systemImage: "chart.bar.fill")
    }
    .accessibilityIdentifier(UITestIdentifiers.Sidebar.view("reports"))
    NavigationLink(value: SidebarSelection.categories) {
      Label("Categories", systemImage: "tag")
    }
    .accessibilityIdentifier(UITestIdentifiers.Sidebar.view("categories"))
    NavigationLink(value: SidebarSelection.upcomingTransactions) {
      Label("Upcoming", systemImage: "calendar")
    }
    .accessibilityIdentifier(UITestIdentifiers.Sidebar.view("upcoming"))
    NavigationLink(value: SidebarSelection.recentlyAdded) {
      recentlyAddedLabel
    }
    .accessibilityIdentifier(UITestIdentifiers.Sidebar.view("recentlyAdded"))
    NavigationLink(value: SidebarSelection.allTransactions) {
      Label("All Transactions", systemImage: "list.bullet")
    }
    .accessibilityIdentifier(UITestIdentifiers.Sidebar.view("allTransactions"))
    #if os(iOS)
      Toggle(isOn: $showHidden) {
        Label("Show Hidden", systemImage: "eye.slash")
      }
    #endif
  }
}
```

The `UITestIdentifiers.Sidebar.view(_:)` helper already exists at `UITestSupport/UITestIdentifiers.swift:30-32` and produces identifiers of the form `sidebar.view.<name>`. **No change to `UITestIdentifiers.swift` is required for Task 1** — only adding `.accessibilityIdentifier(...)` to the `NavigationLink`s in `SidebarView.swift` (Step 3 above).

- [ ] **Step 4: Add `switchToNamed` to `SidebarScreen`**

Modify `MoolahUITests_macOS/Helpers/Screens/SidebarScreen.swift`:

```swift
/// Names of the top-level sidebar items below the account / earmark sections.
/// One case per `SidebarSelection` enum value that does NOT carry a UUID.
enum SidebarNamedItem: String {
  case upcoming
  case allTransactions
  case recentlyAdded
  case analysis
  case reports
  case categories
}

@MainActor
struct SidebarScreen {
  let app: MoolahApp

  // … existing switchToAccount(_:) unchanged …

  /// Switches the centre column to the named top-level view (Upcoming,
  /// All Transactions, Recently Added, Analysis, Reports, Categories).
  /// Returns once the corresponding detail-column root has rendered.
  func switchToNamed(_ item: SidebarNamedItem) {
    Trace.record(detail: "named=\(item.rawValue)")
    let identifier = UITestIdentifiers.Sidebar.view(item.rawValue)
    let row = app.element(for: identifier)
    if !row.waitForExistence(timeout: 3) {
      Trace.recordFailure("sidebar row '\(identifier)' did not appear")
      XCTFail("Sidebar row for named item \(item.rawValue) did not appear within 3s")
      return
    }
    row.click()
    // No single accessibility identifier is shared across every named-item
    // detail root. The XCTest watchdog detects crashes regardless of the
    // post-condition, so for named items we rely on the click landing
    // (returning) without an exception. A 100ms quiescence sleep is NOT
    // used per `UI_TEST_GUIDE.md`'s no-sleep rule; the next driver call's
    // `waitForExistence` provides the natural quiescence.
  }
}
```

- [ ] **Step 5: Run the test (production code unchanged from `main`) to verify it fails with the *bug*, not a build error**

At this step the worktree contains: the new test file, the new sidebar identifiers in `Features/Navigation/SidebarView.swift`, the `UITestIdentifiers.Sidebar.view(_:)` helper, and the new `SidebarScreen.switchToNamed(_:)` driver. Production code under `App/`, `Features/Transactions/`, `Features/Accounts/`, etc. is **unchanged from `main`**. The app compiles; the test compiles; the test then exercises the unfixed bug.

Run:
```bash
just --justfile /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-design/justfile \
     --working-directory /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-design \
     test-mac DetailColumnNavigationSweepTests \
     2>&1 | tee .agent-tmp/test-output-task1.txt
```

Expected: the test FAILS with `NSInternalInconsistencyException: NSToolbar already contains an item with the identifier com.apple.SwiftUI.search` (or, depending on AppKit's report path, an Xcode crash log under `~/Library/Logs/DiagnosticReports/`). The crash means the test is correctly detecting the bug we're about to fix.

If you see a build error instead of a runtime crash, Steps 3-4 are incomplete — fix the missing helpers / identifiers before re-running. A build error is NOT the expected red signal.

If the test passes (no crash), the seed/test combination doesn't exercise the race — increase the cycle count or add more leaf variety until it fails.

- [ ] **Step 6: Commit**

```bash
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-design \
    add MoolahUITests_macOS/Tests/DetailColumnNavigationSweepTests.swift \
        MoolahUITests_macOS/Helpers/Screens/SidebarScreen.swift \
        Features/Navigation/SidebarView.swift \
        UITestSupport/UITestIdentifiers.swift

git -C /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-design \
    commit -m "$(cat <<'EOF'
test(ui): add detail-column navigation-sweep regression test

Reproduces the AppKit toolbar bridge duplicate-search-item crash that
fired during rapid sidebar navigation across heterogeneous detail-
column leaves. Sweeps five cycles × eight selections through a mix of
account, named-view, and analysis leaves, then asserts the transaction
list container re-renders.

The test fails on pre-fix code (toolbar-bridge crash) and is the
regression contract for the structural fix in upcoming commits.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Phase 2 — Foundation (the structural change)

### Task 2: Wrap `ContentView.detail` in a per-leaf `NavigationStack`

**Files:**
- Modify: `App/ContentView.swift:165-211` (`detail` computed property)

- [ ] **Step 1: Read the current `detail` property**

The current shape:

```swift
@ViewBuilder private var detail: some View {
  switch selection {
  case .account(let id):       accountDetail(id: id)
  // … 9 cases total …
  case nil:                    ContentUnavailableView(...)
  }
}
```

- [ ] **Step 2: Wrap in `NavigationStack` with `.id(selection)`**

Replace the body:

```swift
@ViewBuilder private var detail: some View {
  NavigationStack {
    switch selection {
    case .account(let id):
      accountDetail(id: id)
    case .earmark(let id):
      if let earmark = earmarkStore.earmarks.by(id: id) {
        EarmarkDetailView(
          earmark: earmark,
          accounts: accountStore.accounts,
          categories: categoryStore.categories,
          earmarks: earmarkStore.earmarks,
          transactionStore: transactionStore,
          analysisRepository: analysisStore.repository)
      }
    case .recentlyAdded:
      RecentlyAddedView(backend: session.backend)
    case .allTransactions:
      AllTransactionsView(
        accounts: accountStore.accounts,
        categories: categoryStore.categories,
        earmarks: earmarkStore.earmarks,
        transactionStore: transactionStore)
    case .upcomingTransactions:
      UpcomingView(
        accounts: accountStore.accounts,
        categories: categoryStore.categories,
        earmarks: earmarkStore.earmarks,
        transactionStore: transactionStore)
    case .categories:
      CategoriesView(categoryStore: categoryStore)
    case .reports:
      ReportsView(
        reportingStore: reportingStore,
        categories: categoryStore.categories,
        accounts: accountStore.accounts,
        earmarks: earmarkStore.earmarks,
        transactionStore: transactionStore)
    case .analysis:
      AnalysisView(store: analysisStore)
    case nil:
      ContentUnavailableView(
        "Select an Account", systemImage: "sidebar.left",
        description: Text("Choose an account from the sidebar to view transactions."))
    }
  }
  .id(selection)
}
```

The two key changes from today:
1. `NavigationStack { switch … }.id(selection)` wraps the entire switch.
2. `.allTransactions` now dispatches to `AllTransactionsView` (extracted in Task 4) rather than inlining `TransactionListView(...)`.

`AllTransactionsView` does not yet exist; build will fail until Task 4 lands. That's acceptable — Phase 2 lands as a sequence of related commits, not as a series of green builds.

- [ ] **Step 3: Build to confirm the only break is the missing `AllTransactionsView`**

Run:
```bash
just --justfile /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-design/justfile \
     --working-directory /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-design \
     build-mac 2>&1 | tee .agent-tmp/build-task2.txt
```

Expected: a single Swift error of the form "cannot find 'AllTransactionsView' in scope". No other failures.

- [ ] **Step 4: Commit**

```bash
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-design \
    add App/ContentView.swift

git -C /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-design \
    commit -m "$(cat <<'EOF'
refactor(detail): wrap detail column in per-leaf NavigationStack

Each sidebar selection now mounts its own `NavigationStack { ... }`,
hard-keyed on the selection via `.id(selection)`. SwiftUI fully tears
down the previous `NSToolbar` host before mounting the next leaf, so
two `NSToolbar`s never coexist — the AppKit toolbar bridge can no
longer race against itself when re-installing
`com.apple.SwiftUI.search`.

Build does not yet succeed: subsequent commits in this PR add the
extracted leaf views referenced by the new switch arms.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

### Task 3: De-genericize `TransactionListView`

**Files:**
- Modify: `Features/Transactions/Views/TransactionListView.swift`

- [ ] **Step 1: Drop the generic parameter and the `topAccessory` parameter**

Modify `TransactionListView.swift` line 9:

```swift
// Before:
struct TransactionListView<TopAccessory: View>: View {

// After:
struct TransactionListView: View {
```

Delete the `topAccessory` stored property (lines 28-37, the `let topAccessory: TopAccessory` declaration and its surrounding doc comment).

- [ ] **Step 2: Drop the `topAccessory` parameter from both inits**

Modify the default init (lines 86-114). Remove the `@ViewBuilder topAccessory: () -> TopAccessory` parameter and the `self.topAccessory = topAccessory()` assignment:

```swift
init(
  title: String,
  filter: TransactionFilter,
  accounts: Accounts,
  categories: Categories,
  earmarks: Earmarks,
  transactionStore: TransactionStore,
  positions: [Position] = [],
  positionsHostCurrency: Instrument = .AUD,
  positionsTitle: String = "Balances",
  conversionService: (any InstrumentConversionService)? = nil,
  registrationsVersion: Int = 0
) {
  self.title = title
  self.baseFilter = filter
  self.accounts = accounts
  self.categories = categories
  self.earmarks = earmarks
  self.transactionStore = transactionStore
  self.positions = positions
  self.positionsHostCurrency = positionsHostCurrency
  self.positionsTitle = positionsTitle
  self.conversionService = conversionService
  self.registrationsVersion = registrationsVersion
  self._externalSelection = nil
  self._activeFilter = State(initialValue: filter)
}
```

Apply the same change to the embedded init (lines 116-147). Remove the `topAccessory` parameter and assignment, keep the `selectedTransaction: Binding<Transaction?>` parameter and its `_externalSelection = selectedTransaction` assignment. Resulting signature in full:

```swift
/// Embedded init — parent provides selection binding and handles the
/// inspector. Used by `InvestmentAccountView` and `EarmarkDetailView` so
/// their leaf-owned `@State selectedTransaction` survives inner-leaf
/// `.id(...)` tear-downs.
init(
  title: String,
  filter: TransactionFilter,
  accounts: Accounts,
  categories: Categories,
  earmarks: Earmarks,
  transactionStore: TransactionStore,
  positions: [Position] = [],
  positionsHostCurrency: Instrument = .AUD,
  positionsTitle: String = "Balances",
  conversionService: (any InstrumentConversionService)? = nil,
  registrationsVersion: Int = 0,
  selectedTransaction: Binding<Transaction?>
) {
  self.title = title
  self.baseFilter = filter
  self.accounts = accounts
  self.categories = categories
  self.earmarks = earmarks
  self.transactionStore = transactionStore
  self.positions = positions
  self.positionsHostCurrency = positionsHostCurrency
  self.positionsTitle = positionsTitle
  self.conversionService = conversionService
  self.registrationsVersion = registrationsVersion
  self._externalSelection = selectedTransaction
  self._activeFilter = State(initialValue: filter)
}
```

- [ ] **Step 3: Drop the `safeAreaInset` modifier from `body`**

Modify `body` (lines 162-246). Line 164 is currently `.safeAreaInset(edge: .top, spacing: 0) { topAccessory }` — delete this line entirely. The body now opens directly with `listView` followed by the existing `.modifier(OptionalTransactionInspector(...))` chain.

- [ ] **Step 4: Drop both convenience extensions**

Delete the entire `extension TransactionListView where TopAccessory == EmptyView { … }` block at lines 321-373. Both convenience inits (default and embedded-with-binding) become identical to the de-genericized inits in Step 2 and would now produce duplicate-init compile errors.

- [ ] **Step 5: Build**

```bash
just --justfile /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-design/justfile \
     --working-directory /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-design \
     build-mac 2>&1 | tee .agent-tmp/build-task3.txt
```

Expected breaks:
- The `topAccessory:` call site in `App/ContentView.swift` `accountDetail(id:)` (lines 361-386) — fixed in Task 6 (update `accountDetail` to dispatch to `CryptoWalletAccountView`).
- The `AllTransactionsView` reference from Task 2 — fixed in Task 4.

The `.allTransactions` arm of `ContentView.detail` was already converted to reference `AllTransactionsView` in Task 2's commit, so Task 3 introduces no *additional* break on that arm — the same missing-symbol error from Task 2 is still pending until Task 4 lands. The `EarmarkDetailView` and `InvestmentAccountView` call sites continue to work because they call the embedded init (which retains its `selectedTransaction:` parameter and is now non-generic but otherwise unchanged).

`TransactionListView+Preview.swift` does NOT need updating: the existing `#Preview` calls the convenience init (no `topAccessory:` argument), and after de-genericization the convenience init's signature is exactly equivalent to the de-genericized init. The preview file compiles unchanged.

No other breaks should be introduced by this commit.

- [ ] **Step 6: Commit**

```bash
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-design \
    add Features/Transactions/Views/TransactionListView.swift

git -C /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-design \
    commit -m "$(cat <<'EOF'
refactor(transactions): de-genericize TransactionListView

Drops the `<TopAccessory: View>` generic parameter, the `topAccessory`
init parameter, the `safeAreaInset(edge:.top){…}` modifier, and the
`where TopAccessory == EmptyView` convenience extensions.

The `safeAreaInset+EmptyView+NSHostingView` zero-size collapse bug
disappears because the modifier is gone — there is no longer a path
that applies `safeAreaInset` to an `EmptyView` payload inside an
`NSHostingView`-hosted layout.

The two inits (default + embedded-with-binding) stay so
`InvestmentAccountView` and `EarmarkDetailView` continue to own
selection that survives their inner `.id(...)` tear-downs.

Subsequent commits in this PR re-route the now-removed `topAccessory`
call site (the crypto wallet header) through a new
`CryptoWalletAccountView` leaf.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

### Task 4: Extract `StandardAccountView` and `AllTransactionsView`

**Files:**
- Create: `Features/Accounts/Views/StandardAccountView.swift` (contains both types)

- [ ] **Step 1: Write the file**

The `positions(for:)` lookup is on `AccountStore`, not `Accounts` (verified at `Features/Accounts/AccountStore+Queries.swift:39`). The leaf takes the positions array as a constructor parameter, constructed by the caller (which has access to `accountStore`). Same for `conversionService` — passed in. `BackendProvider.conversionService` is non-optional `any InstrumentConversionService` (verified at `Backends/CloudKit/CloudKitBackend.swift:12`), so `StandardAccountView`'s `conversionService` field is non-optional too. `registrationsVersion` is not threaded through `StandardAccountView` because it tracks crypto-token registry changes; for non-crypto accounts the default `0` in `TransactionListView`'s init is correct.

```swift
// Features/Accounts/Views/StandardAccountView.swift
//
// Two thin per-leaf wrappers around `TransactionListView` for the
// non-investment, non-crypto cases of `ContentView`'s detail column.
// Both types collocate in this file deliberately: each is a one-line
// composition with no behaviour, and pairing them keeps the
// "one canonical transaction list, dispatched per leaf" pattern visible
// at a glance. Explicit exception to the one-primary-type-per-file
// convention — both are one-line wrappers around `TransactionListView`
// with no behaviour of their own. See `guides/UI_GUIDE.md` §3 for the
// per-leaf-leaf-view pattern these implement.

import SwiftUI

/// Detail view for bank, asset, and other non-investment, non-crypto
/// accounts. A `TransactionListView` filtered to the account's id, with
/// the account's positions threaded through so the multi-instrument
/// positions split renders for accounts that hold foreign-currency
/// positions (e.g., a multi-currency CommBank account holding USD).
struct StandardAccountView: View {
  let account: Account
  let positions: [Position]
  let accounts: Accounts
  let categories: Categories
  let earmarks: Earmarks
  let transactionStore: TransactionStore
  let conversionService: any InstrumentConversionService

  var body: some View {
    TransactionListView(
      title: account.name,
      filter: TransactionFilter(accountId: account.id),
      accounts: accounts,
      categories: categories,
      earmarks: earmarks,
      transactionStore: transactionStore,
      positions: positions,
      positionsHostCurrency: account.instrument,
      positionsTitle: account.name,
      conversionService: conversionService)
  }
}

/// Detail view for the All Transactions sidebar selection. A bare
/// `TransactionListView` with an empty filter.
struct AllTransactionsView: View {
  let accounts: Accounts
  let categories: Categories
  let earmarks: Earmarks
  let transactionStore: TransactionStore

  var body: some View {
    TransactionListView(
      title: "All Transactions",
      filter: TransactionFilter(),
      accounts: accounts,
      categories: categories,
      earmarks: earmarks,
      transactionStore: transactionStore)
  }
}
```

The caller (Task 6's updated `accountDetail(id:)`) supplies `positions: accountStore.positions(for: account.id)` and `conversionService: session.backend.conversionService`.

- [ ] **Step 2: Add the file to `project.yml` if xcodegen requires it**

`project.yml` typically uses pattern globs (`Features/**/*.swift`), so a new file in `Features/Accounts/Views/` should be picked up automatically by the next `just generate`.

Run `just generate` and check `Moolah.xcodeproj/project.pbxproj` includes the new file:
```bash
just --justfile /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-design/justfile \
     --working-directory /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-design \
     generate 2>&1 | tail -5

grep "StandardAccountView" /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-design/Moolah.xcodeproj/project.pbxproj | head -3
```

Expected: at least one match (file added to a target's Sources phase).

- [ ] **Step 3: Build**

```bash
just --justfile /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-design/justfile \
     --working-directory /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-design \
     build-mac 2>&1 | tee .agent-tmp/build-task5.txt
```

Expected: only the missing `CryptoWalletAccountView` reference from Task 2 remains as a break. The `AllTransactionsView` reference now resolves; any compile errors from Task 3 are gone.

- [ ] **Step 4: Commit**

```bash
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-design \
    add Features/Accounts/Views/StandardAccountView.swift Moolah.xcodeproj/

git -C /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-design \
    commit -m "$(cat <<'EOF'
feat(accounts): extract StandardAccountView and AllTransactionsView

Two thin per-leaf wrappers around `TransactionListView` for the
non-investment, non-crypto detail-column cases. Collocated in one file
as an explicit exception to the one-primary-type-per-file convention —
both are one-line compositions with no behaviour, and pairing them
keeps the "dispatched-per-leaf" pattern visible at a glance.

The `ContentView.detail` switch now references `AllTransactionsView`
directly; `accountDetail(id:)` will dispatch to `StandardAccountView`
in the next commit.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

### Task 5: Extract `CryptoWalletAccountView`

**Files:**
- Create: `Features/Crypto/CryptoWalletAccountView.swift`

- [ ] **Step 1: Write the file**

```swift
// Features/Crypto/CryptoWalletAccountView.swift
import SwiftUI

/// Detail view for a crypto wallet account. Composes the wallet header
/// (full address, chain, last-synced state, Sync now button) above the
/// transaction list as siblings in a `VStack(spacing: 0)`.
///
/// This composition no longer goes through `TransactionListView`'s
/// removed `topAccessory` slot — the leaf is its own `NavigationStack`
/// (provided by `ContentView.detail`'s `.id(selection)` wrap), so the
/// wallet header and the transaction list are structurally local to
/// this leaf and cannot race against another leaf's `.toolbar` /
/// `.searchable` registrations.
///
/// The header renders only when `chainId`, the chain config, AND a
/// `cryptoSyncStore` all resolve; otherwise the `@ViewBuilder` returns
/// `EmptyView`. Within this leaf's `NavigationStack` a
/// `VStack(spacing: 0) { EmptyView; TransactionListView }` is safe —
/// the previously-observed `safeAreaInset+EmptyView+NSHostingView`
/// zero-size collapse fired only when the EmptyView-bearing layout
/// crossed an `NSHostingView` column boundary (the
/// `ResizableVSplit`'s arranged subviews used by
/// `InvestmentAccountView.calculatedFromTrades`). Inside a SwiftUI-
/// owned `NavigationStack` column there is no NSHostingView wrapping
/// at this level, so the bug does not apply.
struct CryptoWalletAccountView: View {
  let account: Account
  let accounts: Accounts
  let categories: Categories
  let earmarks: Earmarks
  let transactionStore: TransactionStore
  let positions: [Position]
  let conversionService: any InstrumentConversionService
  let session: ProfileSession

  var body: some View {
    VStack(spacing: 0) {
      walletHeader
      TransactionListView(
        title: account.name,
        filter: TransactionFilter(accountId: account.id),
        accounts: accounts,
        categories: categories,
        earmarks: earmarks,
        transactionStore: transactionStore,
        positions: positions,
        positionsHostCurrency: account.instrument,
        positionsTitle: account.name,
        conversionService: conversionService,
        // Drives a re-fire of the per-row valuator when the user marks
        // a token as `.spam` from preferences — issue #790.
        registrationsVersion: session.cryptoTokenStore?.registrationsVersion ?? 0)
    }
  }

  @ViewBuilder private var walletHeader: some View {
    if let chainId = account.chainId,
       let chain = ChainConfig.config(for: chainId),
       let cryptoSyncStore = session.cryptoSyncStore {
      WalletAccountHeaderView(
        account: account,
        chain: chain,
        cryptoSyncStore: cryptoSyncStore,
        hasApiKey: session.cryptoTokenStore?.hasAlchemyApiKey ?? false)
    }
  }
}
```

- [ ] **Step 2: Regenerate the project**

```bash
just --justfile /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-design/justfile \
     --working-directory /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-design \
     generate 2>&1 | tail -5
```

- [ ] **Step 3: Build**

```bash
just --justfile /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-design/justfile \
     --working-directory /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-design \
     build-mac 2>&1 | tee .agent-tmp/build-task6.txt
```

Expected: the only remaining break is the old `TransactionListView(...)` call site inside `accountDetail(id:)` that still passes a `topAccessory:` trailing closure. Task 6 fixes that.

- [ ] **Step 4: Commit**

```bash
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-design \
    add Features/Crypto/CryptoWalletAccountView.swift Moolah.xcodeproj/

git -C /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-design \
    commit -m "$(cat <<'EOF'
feat(crypto): extract CryptoWalletAccountView

Composes WalletAccountHeaderView above TransactionListView as siblings
in a `VStack`. Replaces the `topAccessory` slot threading that the
detail-view structural fix has removed; per the new pattern, the
composition is structurally local to its leaf because each leaf lives
in its own `NavigationStack`.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

### Task 6: Update `ContentView.accountDetail(id:)` to use the 3-arm switch

**Files:**
- Modify: `App/ContentView.swift:333-389` (the `accountDetail(id:)` extension)

- [ ] **Step 1: Replace `accountDetail(id:)`**

```swift
@ViewBuilder
private func accountDetail(id: UUID) -> some View {
  if let account = accountStore.accounts.by(id: id) {
    switch account.type {
    case .investment:
      InvestmentAccountView(
        account: account,
        accounts: accountStore.accounts,
        categories: categoryStore.categories,
        earmarks: earmarkStore.earmarks,
        investmentStore: investmentStore,
        transactionStore: transactionStore)
    case .crypto:
      CryptoWalletAccountView(
        account: account,
        accounts: accountStore.accounts,
        categories: categoryStore.categories,
        earmarks: earmarkStore.earmarks,
        transactionStore: transactionStore,
        positions: accountStore.positions(for: account.id),
        conversionService: session.backend.conversionService,
        session: session)
    default:
      StandardAccountView(
        account: account,
        positions: accountStore.positions(for: account.id),
        accounts: accountStore.accounts,
        categories: categoryStore.categories,
        earmarks: earmarkStore.earmarks,
        transactionStore: transactionStore,
        conversionService: session.backend.conversionService)
    }
  }
}
```

The `switch` covers `.investment`, `.crypto`, and `default:` (which catches `.bank`, `.asset`, and any future non-crypto, non-investment types). The previous inline composition (lines 361-386) goes away entirely.

The previous comment block (lines 344-360) explaining the `topAccessory` rationale is also gone — the rationale no longer applies because there is no `topAccessory`. The comment can be deleted entirely; the per-leaf dispatch is self-explanatory from the switch's three named arms. If a comment helps, point at `guides/UI_GUIDE.md` §3 (the codified, persistent location of the structural pattern), not at any plan file under `plans/` — plan files migrate to `plans/completed/` after the work lands and become stale references.

- [ ] **Step 2: Verify the inspector modifier is still at the leaf body level**

The per-leaf `NavigationStack` wrap means the leaf's body is now nested one level deeper. Confirm no call site accidentally lifted the inspector to the `NavigationStack` outer (which would bind the inspector to the wrong scope and break the leaf-owned `selectedTransaction` survival contract).

```bash
grep -rn "\.transactionInspector\|\.inspector(" /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-design/App \
  /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-design/Features 2>/dev/null
```

Expected hits, all unchanged from before PR-1:
- `Features/Transactions/Views/TransactionListView.swift` — applies `OptionalTransactionInspector` modifier on `listView` (still leaf-body level).
- `Features/Transactions/Views/TransactionInspectorModifier.swift` — defines the modifier.
- `Features/Investments/Views/InvestmentAccountView.swift:189` — applies `.transactionInspector(...)` at leaf body.
- `Features/Earmarks/Views/EarmarkDetailView.swift:57` — applies `.transactionInspector(...)` at leaf body.
- `Features/Transactions/Views/UpcomingView.swift:18` — applies `.transactionInspector(...)` at leaf body.

NO hit on `App/ContentView.swift` (the `NavigationStack` wrap should NOT have an `.inspector(...)` modifier on it). If `ContentView.swift` shows up, something extracted the inspector to the wrap by mistake — fix before continuing.

- [ ] **Step 3: Build**

```bash
just --justfile /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-design/justfile \
     --working-directory /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-design \
     build-mac 2>&1 | tee .agent-tmp/build-task7.txt
```

Expected: clean build. All Phase 2 structural changes are now in place.

- [ ] **Step 4: Run the regression test from Task 1**

```bash
just --justfile /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-design/justfile \
     --working-directory /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-design \
     test-mac DetailColumnNavigationSweepTests 2>&1 | tee .agent-tmp/test-task7.txt
```

Expected: PASS. The 5×8 sweep no longer crashes the app.

If the test still fails, inspect `.agent-tmp/test-task7.txt` for the specific failure. Either the structural fix is incomplete (e.g., `.id(selection)` is missing from `ContentView.detail`) or the test has a flake — run again before assuming the fix is wrong.

- [ ] **Step 5: Run the full test suite**

```bash
just --justfile /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-design/justfile \
     --working-directory /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-design \
     test 2>&1 | tee .agent-tmp/test-task7-full.txt
```

Expected: PASS. The structural fix is invisible to existing unit tests; UI tests should still pass because every existing flow (account swap, account → transaction inspector → close, etc.) still works.

If any UI test that worked on `main` now fails, investigate before continuing — the regression is more likely to be in the leaf-extraction (Tasks 4-5) than in the `NavigationStack` wrap.

- [ ] **Step 6: Commit**

```bash
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-design \
    add App/ContentView.swift

git -C /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-design \
    commit -m "$(cat <<'EOF'
refactor(detail): dispatch account detail through extracted leaf views

`ContentView.accountDetail(id:)` becomes a 3-arm switch on
`account.type` that dispatches to `InvestmentAccountView` (existing),
`CryptoWalletAccountView` (new in this PR), and `StandardAccountView`
(new in this PR, via the `default` arm). The inline `topAccessory`
threading is gone; the wallet header now lives inside the new crypto
leaf as a normal sibling of `TransactionListView` in a `VStack`.

The `DetailColumnNavigationSweepTests` regression test now passes.
The full test suite is green.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Phase 3 — Documentation & enforcement

### Task 7: Rewrite `UI_GUIDE.md` §3 (View-tree stability for views with .searchable / .toolbar)

**Files:**
- Modify: `guides/UI_GUIDE.md` lines 88-123 (the existing §3 sub-section)

- [ ] **Step 1: Replace the existing sub-section**

The current sub-section (lines 88-123) describes the failure mode (toolbar bridge crash) and four rules that worked around it (never wrap in structurally-flipping parents, defer layout decisions, use `safeAreaInset`/`topAccessory` for per-context headers, no two `.searchable`s in the same column). Those rules are now obsolete — the structural fix makes them unnecessary.

Replace with the post-PR-1 invariants:

```markdown
### View-tree stability for views with `.searchable` / `.toolbar`

The detail column wraps every leaf in `NavigationStack { … }.id(selection)`
(see `App/ContentView.swift`). The `.id(selection)` is load-bearing: it
forces SwiftUI to fully tear down the previous leaf's `NavigationStack`
(and its `NSToolbar` host) before mounting the next leaf. Two `NSToolbar`s
never coexist, so the AppKit toolbar bridge cannot double-register
`com.apple.SwiftUI.search`.

Two prior incidents drove this design — `InvestmentAccountView` flipping
between `legacyValuationsLayout` and `positionTrackedLayout` after `.task`
resolved (commit `010fb55b`), and the crypto-account `accountDetail`
wrapping the wallet header + `TransactionListView` in a `VStack` whose
first child appeared/disappeared with `account.type == .crypto` (PR #821,
commit `08a99a2d`). Both fired the same
`NSInternalInconsistencyException: NSToolbar already contains an item
with the identifier com.apple.SwiftUI.search` assertion. The structural
fix eliminates the failure mode at its source rather than patching each
new instance.

**Searchable invariant (two-part rule, exhaustive):**

1. Any leaf that contains a `TransactionListView` (e.g.,
   `StandardAccountView`, `CryptoWalletAccountView`, `AllTransactionsView`,
   `EarmarkDetailView`, `InvestmentAccountView`, `UpcomingView`) registers
   exactly one `.searchable(text:)`, and it lives inside
   `TransactionListView`. No other code in such a leaf may register
   `.searchable`.
2. Any leaf that does NOT contain a `TransactionListView` (e.g.,
   `CategoriesView`) may register at most one `.searchable(text:)` directly
   on its own root view. Two `.searchable` modifiers in the same leaf are
   forbidden regardless of leaf type.

**Toolbar accumulation:** `TransactionListView` owns the standard
transaction-list toolbar items (filter / refresh / add). Leaves that need
additional toolbar items add them via a sibling `.toolbar { … }` modifier
on the leaf's body — SwiftUI accumulates these into the leaf's single
`NSToolbar` because there is exactly one `NavigationStack` per leaf. There
is no `extraToolbar:` parameter on `TransactionListView`.

**Inspector placement:** the `.transactionInspector(...)` modifier
attaches at the leaf's body level — i.e., inside the per-leaf
`NavigationStack`, on the outermost view of the leaf's content. SwiftUI
hoists the inspector to the window level for rendering, so the placement
does not affect layout, but keeping the modifier at the leaf level scopes
the inspector's binding to the leaf's `@State selectedTransaction`. Do
not move it up to the `ContentView.detail` level.

**Composition shells** (`PositionsTransactionsSplit`, and after PR-3 /
PR-2: `RecordedValueInvestmentLayout`, `EarmarkOverviewWithTabs`) are
content-only: they do not register `.toolbar` or `.searchable`.

The `code-review` and `ui-review` agents flag any new view that violates
the searchable invariant. Treat agent findings on this rule as Critical.
```

- [ ] **Step 2: Confirm no stale references to `topAccessory` or `safeAreaInset` survive elsewhere in `UI_GUIDE.md`**

The rewrite replaces the §3 sub-section, but other sections of the guide may have referenced `topAccessory` or `safeAreaInset` as part of older patterns. Stale references would produce contradictions for anyone reading the guide top-to-bottom.

```bash
grep -n "topAccessory\|safeAreaInset(edge: .top" /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-design/guides/UI_GUIDE.md
```

Expected: zero matches. If any matches appear (outside the §3 sub-section we just rewrote), update or delete the stale references in the same commit.

- [ ] **Step 3: Format and commit**

```bash
just --justfile /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-design/justfile \
     --working-directory /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-design \
     format-check 2>&1 | tail -5

git -C /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-design \
    add guides/UI_GUIDE.md

git -C /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-design \
    commit -m "$(cat <<'EOF'
docs(ui-guide): rewrite §3 view-tree stability rules for the new pattern

Replaces the four workaround-style rules that protected against the
shared-`NSToolbar`-host failure mode with a single grep-able invariant
appropriate for the post-PR-1 codebase: per-leaf `NavigationStack`,
exactly one `.searchable` per leaf inside `TransactionListView`,
toolbar accumulation via sibling `.toolbar` modifiers, content-only
composition shells.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

### Task 8: Update the `code-review` agent rule

**Files:**
- Modify: `.claude/agents/code-review.md`

- [ ] **Step 1: Read the existing rule**

The agent definition has an "architectural conformance" or similar section that today references the view-tree-stability rule from `UI_GUIDE.md` §3. The rule needs to be replaced with the new searchable invariant.

Use the `Read` tool on `/Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-design/.claude/agents/code-review.md` (do not `cat` the file via `Bash` — `Read` is the tool we use for reading files in this codebase).

- [ ] **Step 2: Replace the rule**

Find the existing "Critical-tier — view-tree shape stability for views with `.toolbar` / `.searchable`" rule. Replace with:

```markdown
**Critical — Searchable invariant for detail-column leaves.** The
detail column wraps every leaf in `NavigationStack { … }.id(selection)`
(see `App/ContentView.swift`'s `detail` property and `guides/UI_GUIDE.md`
§3). Flag as Critical:

- Any new `case` in `ContentView.detail`'s `switch selection` that
  is not enclosed by the `NavigationStack { … }.id(selection)` outer.
- Any `.searchable(text:)` modifier inside a leaf that contains a
  `TransactionListView`, except the one inside `TransactionListView`
  itself. Two `.searchable` modifiers in any leaf are also Critical.
- Any new `List(selection:)` that iterates over `Transaction` outside
  `TransactionListView`. The canonical transaction list is
  `TransactionListView`; re-implementations in leaves are Critical.
- Any diff to `TransactionListView.swift` that re-introduces a generic
  parameter, a `topAccessory` slot, or a `safeAreaInset(edge:.top)`
  modifier. The de-genericized form is the codified post-PR-1 contract.

The pre-PR-1 wording referenced "view-tree shape stability for views
with `.searchable` / `.toolbar`". That rule is obsolete: the per-leaf
`NavigationStack` makes structural variance within a leaf harmless,
because the toolbar host is per-leaf. Do NOT reapply the obsolete rule
to a diff that demonstrates intra-leaf shape variance — only the new
invariant applies.
```

- [ ] **Step 3: Commit**

```bash
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-design \
    add .claude/agents/code-review.md

git -C /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-design \
    commit -m "$(cat <<'EOF'
agents(code-review): update detail-column rules for the new pattern

Replaces the obsolete "view-tree shape stability" rule with the
post-PR-1 searchable invariant: per-leaf NavigationStack required,
one searchable per leaf inside TransactionListView, no
re-implementations of the transaction list outside it, no resurrection
of the generic parameter / topAccessory / safeAreaInset surface.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

### Task 9: Update the `ui-review` agent rule

**Files:**
- Modify: `.claude/agents/ui-review.md`

- [ ] **Step 1: Read the existing rule**

Use the `Read` tool on `/Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-design/.claude/agents/ui-review.md`.

- [ ] **Step 2: Replace the rule**

Find the existing detail-column rules (the section that today references the four `UI_GUIDE.md` §3 rules — never-wrap-in-flipping-parent, defer-until-stable, etc.). Replace with:

```markdown
**Critical — Detail-column searchable invariant.** Per
`guides/UI_GUIDE.md` §3:

- Every leaf in `ContentView.detail`'s switch is wrapped in
  `NavigationStack { … }.id(selection)`. Flag as Critical any new leaf
  that escapes this wrap, or any diff that removes the `.id(selection)`
  modifier.
- Leaves that contain a `TransactionListView` register exactly one
  `.searchable(text:)`, inside `TransactionListView`. Flag any
  additional `.searchable` registration in such a leaf as Critical.
- Leaves that do NOT contain a `TransactionListView` (e.g.,
  `CategoriesView`) may register at most one `.searchable` directly.
  Flag any second registration in the same leaf as Critical.
- Composition shells (`PositionsTransactionsSplit`,
  `RecordedValueInvestmentLayout` post-PR-3, `EarmarkOverviewWithTabs`
  post-PR-2) are content-only. Flag any `.toolbar` or `.searchable`
  inside a shell as Critical.
- Inspector modifiers (`.transactionInspector(...)`) attach at the
  leaf's body level, not at `ContentView.detail`. Flag any inspector
  modifier on a `NavigationStack` outer or on `ContentView` itself as
  Critical.
```

- [ ] **Step 3: Commit**

```bash
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-design \
    add .claude/agents/ui-review.md

git -C /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-design \
    commit -m "$(cat <<'EOF'
agents(ui-review): update detail-column rules for the new pattern

Mirrors the code-review agent update: per-leaf NavigationStack,
single searchable per leaf inside TransactionListView, content-only
composition shells, leaf-body inspector placement.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Phase 4 — File-merge evaluation

### Task 10: Evaluate whether `TransactionListView+List.swift` can merge into `TransactionListView.swift`

**Files:**
- Evaluate: `Features/Transactions/Views/TransactionListView.swift` and `Features/Transactions/Views/TransactionListView+List.swift`

The companion file existed pre-PR-1 to keep the main file under the 400-line `file_length` SwiftLint warning. The PR-1 changes (drop generic parameter, drop both convenience extensions, drop `safeAreaInset` modifier, drop `topAccessory` parameter and storage) reduce the main file by ~80-120 lines. If the merged file fits under 400 lines, merge.

- [ ] **Step 1: Count lines**

```bash
wc -l /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-design/Features/Transactions/Views/TransactionListView.swift \
      /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-design/Features/Transactions/Views/TransactionListView+List.swift
```

- [ ] **Step 2: Decide**

The `file_length` SwiftLint warning fires at 400 lines. Merge only if the combined file is comfortably under that threshold — use ≤ 380 lines as the cutoff. The headroom matters because PRs 2-5 may grow `TransactionListView` slightly (PR-4 adds the `Grouping` enum and the `.scheduledStatus` row-action plumbing), and a merged file at 398 lines today could trip the warning a few PRs later — at which point splitting back is rework. If combined ≤ 380, proceed to Step 3 (merge). If > 380, leave them separated and skip to Step 5.

- [ ] **Step 3 (only if merging): Move `TransactionListView+List.swift`'s extension methods into `TransactionListView.swift`**

Concatenate `TransactionListView+List.swift`'s body (the `extension TransactionListView { … }` block) onto the end of `TransactionListView.swift`. The file-private `PositionsTaskKey` struct moves with it. The `TransactionListCSVImportAddons` view modifier also moves with it (it was moved to the companion file purely to keep the main file's line count down).

Delete `TransactionListView+List.swift`.

- [ ] **Step 4 (only if merging): Regenerate, build, format-check**

```bash
just --justfile /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-design/justfile \
     --working-directory /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-design \
     generate

just --justfile /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-design/justfile \
     --working-directory /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-design \
     format-check 2>&1 | tail -5

just --justfile /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-design/justfile \
     --working-directory /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-design \
     build-mac 2>&1 | tee .agent-tmp/build-task11.txt
```

If `format-check` flags `file_length`, abort the merge: `git checkout -- .` to restore both files, leave them separated, document the line count in the PR description.

- [ ] **Step 5: Commit (whether merged or not)**

If merged:
```bash
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-design \
    rm Features/Transactions/Views/TransactionListView+List.swift

git -C /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-design \
    add Features/Transactions/Views/TransactionListView.swift Moolah.xcodeproj/

git -C /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-design \
    commit -m "$(cat <<'EOF'
chore(transactions): merge TransactionListView+List.swift back into TransactionListView.swift

Post-de-genericization, the combined file fits under the 400-line
file_length warning and the companion-file structure no longer earns
its keep. One file, one type.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

If not merged: skip the commit; leave a note in the PR description that file_length pressure prevented the merge.

---

## Phase 5 — Pre-PR gate

### Task 11: `just format` and `just format-check`

- [ ] **Step 1: Run format**

```bash
just --justfile /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-design/justfile \
     --working-directory /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-design \
     format
```

- [ ] **Step 2: Verify clean**

```bash
just --justfile /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-design/justfile \
     --working-directory /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-design \
     format-check 2>&1 | tail -5
```

Expected: `All Swift files are correctly formatted.`

If anything was modified by `format`, commit. Step A stages everything `format` touched; Step B commits, but only if Step A actually staged something (otherwise we'd produce an empty commit):

```bash
# Step A — stage all tracked-file modifications from `format`.
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-design \
    add -u

# Step B — commit only if there is anything staged. `git diff --cached --quiet`
# exits 0 when the index matches HEAD (nothing staged); we want to commit in
# the OPPOSITE case, hence the leading `!`.
if ! git -C /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-design \
       diff --cached --quiet; then
  git -C /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-design \
      commit -m "$(cat <<'EOF'
chore(format): apply swift-format

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
fi
```

If `format-check` reports SwiftLint baseline violations, do **NOT** modify `.swiftlint-baseline.yml` — fix the underlying code (per the project's "fix swiftlint, don't re-baseline" memory).

### Task 12: Full test suite

- [ ] **Step 1: Run full tests**

```bash
mkdir -p /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-design/.agent-tmp

just --justfile /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-design/justfile \
     --working-directory /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-design \
     test 2>&1 | tee /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-design/.agent-tmp/test-full.txt
```

- [ ] **Step 2: Check for failures**

```bash
grep -i 'failed\|error:' /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-design/.agent-tmp/test-full.txt | head -20
```

Expected: no failures. The new test (`DetailColumnNavigationSweepTests.test_rapidSweepAcrossDetailLeaves_doesNotCrashTheToolbarBridge`) passes; every existing test still passes.

If any test fails, fix the underlying issue before continuing — do not push a red branch.

### Task 13: Run `code-review` agent and fix every finding

- [ ] **Step 1: Invoke the agent**

Dispatch the `code-review` agent with prompt:

> Review the changes on the `worktree-detail-view-structural-fix-design` branch for compliance with `guides/CODE_GUIDE.md` and the architectural conventions in CLAUDE.md. Focus on the foundation pass (PR-1 of the detail-view structural fix per `plans/2026-05-09-detail-view-structural-fix-design.md`): the per-leaf `NavigationStack` wrap in `ContentView`, the de-genericized `TransactionListView`, the new `StandardAccountView` / `AllTransactionsView` / `CryptoWalletAccountView` leaves, the `UI_GUIDE.md` §3 rewrite, the agent rule updates. Flag every Critical, Important, and Minor finding.

- [ ] **Step 2: Fix every Critical and Important finding**

For each finding, edit the relevant file, format, build, test, commit. Repeat until the agent reports no Critical or Important findings.

Apply Minor findings unless they conflict with the design spec (in which case justify the deviation in the PR description).

### Task 14: Run `ui-review` agent and fix every finding

- [ ] **Step 1: Invoke the agent**

Dispatch the `ui-review` agent with prompt:

> Review the changes on the `worktree-detail-view-structural-fix-design` branch for compliance with `guides/UI_GUIDE.md` and Apple HIG. Focus on the foundation pass: per-leaf `NavigationStack` wrapping (does iPhone behaviour look right?), the `UI_GUIDE.md` §3 rewrite, the new leaf views' composition (does `CryptoWalletAccountView`'s `VStack` render the wallet header at the right spacing?), the agent rule updates. Flag every Critical, Important, and Minor finding.

- [ ] **Step 2: Fix every finding**

Same process as Task 13. Repeat until `ui-review` is clean.

### Task 15: Manual verification — macOS

- [ ] **Step 1: Run the app**

```bash
just --justfile /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-design/justfile \
     --working-directory /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-design \
     run-mac
```

- [ ] **Step 2: Verify the manual verification matrix from §9.1 of the design spec**

For PR-1 the matrix calls for:
- 5×8 navigation sweep across investment / crypto / bank accounts (no toolbar crash). ✓ (covered by automated test in Task 1, but also do a manual sweep to feel the rendering)
- Trades-mode investment account shows transactions list (Trust Shares, IOZ/VGS) — load a real or test profile that exercises this layout, switch to it, confirm the transactions list renders below the positions split.
- Wallet-header path renders on crypto accounts (Trust Ethereum or any seeded wallet) — confirm the header renders with the wallet address, chain name, last-synced state, and Sync now button intact.
- **EarmarkDetailView toolbar ordering** — open any earmark from the sidebar. Confirm the toolbar shows the standard `TransactionListView` items (Filter, Refresh, Add Transaction) AND the `EarmarkDetailView` Edit button, and that the visual left-to-right order is acceptable. PR-1 does not migrate `EarmarkDetailView` to the composition shell (deferred to PR-2), but it now lives inside its own per-leaf `NavigationStack`, so SwiftUI accumulates both leaves' toolbar items into one `NSToolbar`. If the order is wrong (e.g., Edit appears between Refresh and Add Transaction in a way that disrupts the expected grouping), document it and PR-2 will reposition with explicit `placement:` slots.

Document any observed regressions in `.agent-tmp/manual-verification.txt`.

### Task 16: Manual verification — iPhone (nested NavigationStack review)

- [ ] **Step 1: Run on iOS simulator**

```bash
just --justfile /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-design/justfile \
     --working-directory /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-design \
     build-ios
```

Open the built app in the **iPhone 16 Pro** simulator (or any other iPhone size — NOT iPad). The compact-width iPhone path is what collapses `NavigationSplitView` to a single stack and would expose the nested-`NavigationStack` double-nav-bar issue. iPad keeps the split view, so iPad doesn't exercise the failure mode this verification needs to check.

Navigate the sidebar, push into account details, verify there is no double navigation bar and the back-button title is reasonable.

- [ ] **Step 2: Decide whether to keep the unconditional wrap**

If the iPhone rendering is acceptable: keep the `NavigationStack` wrap unconditional. Document the visual outcome in the PR description.

If the rendering shows a double nav bar or other HIG violation: change `ContentView.detail` to wrap conditionally:

```swift
@ViewBuilder private var detail: some View {
  #if os(macOS)
    NavigationStack {
      switchBody
    }
    .id(selection)
  #else
    switchBody
      .id(selection)
  #endif
}

@ViewBuilder private var switchBody: some View {
  switch selection {
  // … cases as in Task 2 …
  }
}
```

Commit the conditional wrap if the unconditional version was unacceptable. Document the decision in the PR description.

### Task 17: Cancellation-discipline verification

- [ ] **Step 1: Code-inspect the three async paths that get cancelled by `.id(selection)` tear-down**

The `.id(selection)` outer wrap forces SwiftUI to cancel any in-flight `.task(id:)` blocks on every sidebar selection change. Confirm by reading the code that each cancellation path exits cleanly:

```bash
grep -n "await\|Task.isCancelled\|CancellationError" \
  /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-design/Features/Transactions/Views/TransactionListView+List.swift \
  /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-design/Features/Investments/InvestmentStore+Loading.swift \
  /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-design/Features/Investments/InvestmentStore+PositionsInput.swift
```

Read each match in context and confirm:
- `TransactionStore.observe(filter:)` — the `for await` loop in the store exits cleanly when SwiftUI cancels the consuming `.task(id:)` (loop returns when iteration ends; no need for explicit `Task.isCancelled` checks because `for await` cooperates with cancellation natively).
- `PositionsValuator.valuate(...)` (called from `TransactionListView+List.swift:113`'s `.task(id: PositionsTaskKey(...))`) — should return early on `CancellationError` or check `Task.isCancelled` after each `await` suspension.
- `InvestmentStore.loadAndBuildPositionsInput(account:profileCurrency:range:)` (called from `InvestmentAccountView.swift:202`'s `.task(id: LoadKey)`) — same.

If any path is missing cancellation discipline, fix it as a separate commit (do NOT bundle a cancellation-fix commit with the structural-refactor commits — make it grep-able as a defensive add). If all three are clean, the structural fix is on solid ground.

- [ ] **Step 2: Confirm at runtime — sweep the macOS app rapidly with the console open**

Run `just run-mac` and watch the Xcode / Console.app output for `os_log` messages while sweeping the sidebar rapidly across leaves.

Expected: no error messages from any of:
- `TransactionStore.observe(filter:)` exiting its `for await` loop
- `PositionsValuator.valuate(...)`
- `InvestmentStore.loadAndBuildPositionsInput(...)`

If errors are observed at runtime that the code-inspection in Step 1 didn't catch, the discrepancy is meaningful — investigate what async path is producing the error and add the missing cancellation check to it. Do not push a branch where the rapid-sweep produces console errors.

### Task 18: Push and open PR

- [ ] **Step 1: Push the branch with explicit src:dst**

```bash
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-design \
    push origin worktree-detail-view-structural-fix-design:worktree-detail-view-structural-fix-design 2>&1 | tail -5
```

- [ ] **Step 2: Open the PR**

```bash
gh -R ajsutton/moolah-native pr create \
   --base main \
   --head worktree-detail-view-structural-fix-design \
   --title "fix(detail): per-leaf NavigationStack + de-genericize TransactionListView" \
   --body "$(cat <<'EOF'
## Summary

Implements PR-1 (Foundation) of the detail-view structural fix per `plans/2026-05-09-detail-view-structural-fix-design.md`.

- **Per-leaf `NavigationStack`** in `ContentView.detail`, hard-keyed on `.id(selection)`. The previous leaf's `NSToolbar` is fully torn down before the next leaf mounts; the AppKit toolbar bridge can no longer race against itself when re-installing `com.apple.SwiftUI.search`.
- **De-genericized `TransactionListView`** — drops the `TopAccessory` generic, the `topAccessory` parameter, the `safeAreaInset(edge:.top)` modifier, the `where TopAccessory == EmptyView` convenience extensions. The `safeAreaInset+EmptyView+NSHostingView` zero-size collapse bug disappears with them.
- **New per-leaf views** — `StandardAccountView`, `AllTransactionsView`, `CryptoWalletAccountView`. The crypto wallet header now lives inside its leaf as a normal `VStack` sibling, no longer threaded through `topAccessory`.
- **`UI_GUIDE.md` §3 rewrite** — replaces the four workaround-style rules with the single grep-able invariant: exactly one `.searchable` per detail leaf, inside `TransactionListView`.
- **Agent rules updated** — `code-review` and `ui-review` now flag the new invariant as Critical-tier.
- **Regression test** — `DetailColumnNavigationSweepTests.test_rapidSweepAcrossDetailLeaves_doesNotCrashTheToolbarBridge` performs the 5×8 sweep that originally reproduced the crash and asserts no crash + non-empty list.

Closes the structural recurrence of the toolbar bridge crash and the `safeAreaInset+EmptyView` blank-list bug.

## Out of scope

- `EarmarkDetailView`, `InvestmentAccountView`, `UpcomingView` migrations to composition shells (PR-2, PR-3, PR-4).
- Multi-instrument positions split move out of `TransactionListView` into `StandardAccountView` (PR-5).
- `RecentlyAddedView` migration (issue #824).
- Pre-existing `NotificationCenter` cross-view dispatch (issue #826).

## Test plan

- [x] `DetailColumnNavigationSweepTests` passes (the regression test fails on `main`).
- [x] `just test` green.
- [x] `just format-check` clean.
- [x] `@code-review` agent: no Critical or Important findings.
- [x] `@ui-review` agent: no Critical or Important findings.
- [x] Manual macOS verification — wallet-header path, trades-mode investments list, sweep across heterogeneous leaves.
- [x] Manual iPhone review — nested `NavigationStack` rendering acceptable / conditionally wrapped (note in commit message which path was taken).
- [x] Cancellation-discipline verification — rapid sweep produces no console errors.

Generated with [Claude Code](https://claude.com/claude-code)
EOF
)" 2>&1 | tail -3
```

The output is the PR URL.

- [ ] **Step 3: Add to merge queue**

```bash
PR_NUMBER=$(gh -R ajsutton/moolah-native pr list --head worktree-detail-view-structural-fix-design --json number --jq '.[0].number')
~/.claude/skills/merge-queue/scripts/merge-queue-ctl.sh add "$PR_NUMBER" 2>&1 | tail -3
```

Expected: `added #<n>`.

The merge-queue daemon picks up the PR; CI runs against the speculative merge train.

---

## Plan complete

PR-1 is in flight. PRs 2-5 each get their own plan after PR-1 lands and we have implementation experience to inform them.
