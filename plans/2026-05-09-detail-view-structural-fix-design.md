# Detail-View Structural Fix — Design

**Date:** 2026-05-09
**Status:** Design (awaiting plan)
**Author:** Adrian Sutton (with Claude Opus 4.7)

---

## 1. Problem statement

Two recurring failure modes affect every leaf view that lives in `ContentView`'s `NavigationSplitView` detail column. Both have the same root cause — `.toolbar` and `.searchable` modifiers registered on leaf views that come and go as the sidebar selection changes — and the existing fixes have been mutually exclusive.

### 1.1 Failure mode A — AppKit toolbar bridge crash

```
NSInternalInconsistencyException: NSToolbar already contains an item
with the identifier com.apple.SwiftUI.search.
Duplicate items of this type are not allowed.
```

Fires whenever SwiftUI re-mounts a leaf view that owns both `.searchable` and `.toolbar` while the previous registration is still live. The bridge tracks toolbar items by view identity and silently re-installs them when an ancestor re-mounts the host. If the search-bearing view ends up at a different structural index between two renders, the bridge attempts to insert `com.apple.SwiftUI.search` while the previous registration is still live and AppKit traps.

Reproducible on the live `main` branch by sweeping rapidly across investment / crypto / bank accounts (`Shares` → `Trust Shares` → `Trust Ethereum` → `CommBank` → `SelfWealth` → …).

Two prior incidents in the repo:
- `InvestmentAccountView` flipping between `legacyValuationsLayout` and `positionTrackedLayout` after `.task` resolved (commit `010fb55b`).
- `accountDetail` wrapping the wallet header + `TransactionListView` in a `VStack` whose first child appeared/disappeared based on `account.type == .crypto` (PR #821, commit `08a99a2d`).

### 1.2 Failure mode B — `safeAreaInset` + `EmptyView` + `NSHostingView` collapse

When `TransactionListView` is hosted inside an `NSHostingView` (the `ResizableVSplit` used by `InvestmentAccountView.positionTrackedLayout`), applying `.safeAreaInset(edge: .top, spacing: 0) { EmptyView() }` collapses the modified view to zero size. Symptom: the transactions list disappears entirely under the positions split for `.calculatedFromTrades` accounts with multi-instrument positions.

### 1.3 History — why this is a structural problem

The two failure modes have been alternating in production:

| Commit / PR | Effect |
|---|---|
| `08a99a2d` "fix(crypto): pass wallet header via TransactionListView topAccessory slot" | Fixed (A) by hoisting the optional wallet header into a `topAccessory` `safeAreaInset` so the outer `VStack` wrap-or-not branching went away. Stable structural shape regardless of accessory. |
| PR #822 "fix(transactions): skip safeAreaInset when topAccessory is EmptyView" | Fixed (B) but reintroduced (A): the body's structural shape now differs between `TransactionListView<EmptyView>` and `TransactionListView<other>`, so navigation across leaves re-introduced the duplicate-search-item assertion. |
| PR #823 "revert: PR #822" (currently in merge queue) | Restores the no-crash invariant. Once merged, `main` has (A) fixed and (B) re-broken. |

Each point fix flipped the same coin to the other side. A structural change is required to eliminate both at once.

## 2. Goals

1. **Eliminate failure mode (A) for the entire detail-column family**, not just the path that currently reproduces.
2. **Eliminate failure mode (B)** as a side effect, by removing the dependency on `safeAreaInset` for accessory composition.
3. **Make it structurally hard to regress.** A single grep-able invariant, codified in `UI_GUIDE.md` and enforced by review agents.
4. **Preserve "one canonical transaction list."** No re-implementations of `List(selection:)` over `Transaction` outside `TransactionListView`.
5. **Keep per-leaf composition free.** Headers, splits, tab pickers — the leaf decides how it composes around `TransactionListView`.

## 3. Non-goals

- Migrating `RecentlyAddedView` (issue [#824](https://github.com/ajsutton/moolah-native/issues/824) — same anti-pattern but different data shape; deferred).
- Migrating `CategoriesView`, `AnalysisView`, `ReportsView`. Different shape (not "list of transactions + accessory"); they are not the source of the recurring bugs.
- Touching `EarmarksView`. Already removed in PR #825 (it was orphaned — the sidebar navigates directly to `EarmarkDetailView` via `.earmark(id)`).
- iPhone-specific re-design. iPhone exhibits neither failure mode in production today (iOS uses `UISearchController`, more forgiving than `NSToolbar`). The design wraps each leaf in `NavigationStack` unconditionally; iPhone behaviour is to be reviewed manually after PR-1 lands. The known iOS HIG concern is that `NavigationSplitView` collapses to a single-column stack on compact-width devices and an embedded `NavigationStack` inside the detail column then produces a double navigation bar with two back buttons — iOS HIG advises against nesting navigation stacks in single-column layouts. **If PR-1's manual iPhone review finds this unacceptable, the concrete fallback is to wrap the `NavigationStack` in `#if os(macOS)` (and apply the `.id(selection)` to the bare switch on iOS).** macOS-only wrapping still solves the production crash because (A) is a macOS-only failure (`NSToolbar`), and iOS continues with its existing single-stack navigation.

## 4. Architecture

### 4.1 The load-bearing change

Every detail-column leaf is wrapped in its own `NavigationStack`, hard-keyed on the sidebar selection:

```swift
@ViewBuilder private var detail: some View {
  NavigationStack {
    switch selection {
    case .account(let id):       accountDetail(id: id)
    case .earmark(let id):       earmarkDetail(id: id)
    case .recentlyAdded:         RecentlyAddedView(backend: session.backend)
    case .allTransactions:       AllTransactionsView(...)
    case .upcomingTransactions:  UpcomingView(...)
    case .categories:            CategoriesView(...)
    case .reports:               ReportsView(...)
    case .analysis:              AnalysisView(store: analysisStore)
    case nil:                    ContentUnavailableView(...)
    }
  }
  .id(selection)   // hard tear-down between leaves
}
```

The `.id(selection)` modifier is load-bearing: it forces SwiftUI to fully tear down the previous leaf's `NavigationStack` (and its `NSToolbar` host) before mounting the new one. Two `NSToolbar`s never coexist, so the bridge cannot double-register `com.apple.SwiftUI.search`.

### 4.2 Direct consequences

**Consequence 1 — `TransactionListView` reverts to a plain non-generic view.** `topAccessory`, the `safeAreaInset(edge:.top)` modifier, the `where TopAccessory == EmptyView` extension, and the `_ConditionalContent` skip all disappear. The `safeAreaInset+EmptyView+NSHostingView` collapse bug disappears with them — there is no `safeAreaInset` modifier anywhere in the file.

**Consequence 2 — leaves compose freely.** A crypto wallet is `VStack { WalletHeader; TransactionListView }` inside its leaf's `NavigationStack`. An investment account is `PositionsTransactionsSplit { positions } transactions: { TransactionListView }`. Each leaf's structural shape is now scoped to that leaf only — variance can no longer race against another leaf's toolbar registration because the toolbar is destroyed between leaves.

**Consequence 3 — one invariant left to enforce.** "There is exactly one `.searchable` per detail leaf, and it lives inside `TransactionListView`." Codified in `UI_GUIDE.md` §3 and checked by `code-review` / `ui-review` agents as Critical-tier.

The current `UI_GUIDE.md` §3 rules ("never wrap a `.searchable`-bearing view in a structurally-flipping parent", "defer layout decisions until data is stable") become *unnecessary* — they were workarounds for the toolbar bridge being shared across leaves. Once the bridge is per-leaf, structural flips inside a leaf are harmless. They are replaced with the simpler invariant.

## 5. Components & data flow

### 5.1 Modified types

**`TransactionListView`** — non-generic, no `topAccessory`, no `safeAreaInset`. ONE additive parameter:

- `grouping: Grouping = .flat` — non-optional, defaulted. Cases:
  - `.flat` — today's single ungrouped list (the default; existing call sites omit the parameter and pick this up).
  - `.byDate` — grouped by transaction date.
  - `.scheduledStatus(today: Date, pendingPayId: Binding<Transaction.ID?>)` — Overdue / Upcoming sections; the binding is the leaf-owned target for the Pay-Transaction action.

The `.scheduledStatus` case bundles `pendingPayId` into the case's associated values rather than exposing a separate top-level parameter on `TransactionListView`. This makes the binding **structurally required** when (and only when) the caller selects `.scheduledStatus`: there is no way to construct that case without supplying it, and no other case takes one. Eliminates the "Binding default of `.constant(nil)` silently discards writes" footgun by construction (compare `CODE_GUIDE.md` §8 "No silent `try?`" — same family of silent-discard concern).

When `grouping == .scheduledStatus`, `TransactionListView`'s row context-menu includes a "Pay Transaction…" item that writes the row's transaction id into the case's `pendingPayId` binding. The leaf observes via `.onChange(of: pendingPayId.wrappedValue)` and runs its existing `payTransaction` flow, then resets the binding to `nil`. **No NotificationCenter for the Pay action** — same-view dispatch is wired with a typed binding, which keeps the path on `@MainActor` and `Sendable`-clean per `CONCURRENCY_GUIDE.md` §8.

`Binding<T>` as an enum-case associated value is unusual but valid — `Binding` is a value-type wrapper around getter/setter closures, both `@MainActor`-isolated. The enum cannot synthesize `Equatable` because `Binding` is not `Equatable`; this is fine for `TransactionListView`'s usage because `Grouping` is read by the view body, not compared for diffing. **`Grouping` is intentionally non-`Sendable` and `@MainActor`-only** — its `Binding<T>` payload's getter/setter are `@MainActor`-isolated, and the enum is constructed in one `@MainActor` view body and consumed in another. The implementer of PR-4 must add a single-line declaration-site comment (`// Grouping is @MainActor-only; do not add Sendable conformance — Binding<T> closures are MainActor-isolated.`) so future contributors don't try to make it `Sendable` and hit a confusing diagnostic. PR-4 description should also reference §5.1's structural-required-binding rationale so `@code-review` doesn't re-question the unusual enum-case shape.

Note on cross-view dispatch (`.requestTransactionEdit`, `.requestTransactionDelete`): the existing notification-based wiring is **out of scope for this design**. Those notifications carry commands from window-level menus (Edit > Edit Transaction, etc.) to whichever transaction-list leaf is currently visible. The receiver isn't known to the menu sender; replacing them requires routing through `focusedSceneValue` and is a separate refactor (logged as follow-up — see §10).

The `today: Date` associated value is set by the leaf at view-construction time (`grouping: .scheduledStatus(today: Date(), pendingPayId: $pendingPayId)`). This is an explicit clock-boundary call inside the leaf view body — acceptable per `CODE_GUIDE.md` §17 ("`Date()` only at boundaries"), since the view layer is the boundary. Implementers must not extract this into a deeper utility without injecting it.

**No `extraToolbar:` or `extraRowActions:` parameters.** Both would force `TransactionListView` to be generic again (because `ToolbarContent` and `View` are PATs), which directly contradicts §4.2 Consequence 1. Instead, leaves that need additional toolbar items add them via a sibling `.toolbar { … }` modifier in the leaf's body — SwiftUI accumulates toolbar items across the view tree into the leaf's single `NavigationStack` toolbar host. Today the only leaf that adds a toolbar item is `EarmarkDetailView` (Edit, line 65); `InvestmentAccountView`'s Add Value lives inside `valuationsHeader`, not the toolbar, and `CryptoWalletAccountView`'s Sync now lives inside `WalletAccountHeaderView`'s body.

Owns: search text state, `.searchable`, the standard toolbar items, optionally the inspector wiring (`OptionalTransactionInspector`), the filter sheet. **Both existing inits stay** (default + embedded-with-binding). The embedded form is required by `InvestmentAccountView`: that leaf has an inner `.id(ValuationMode)` boundary that tears down `TransactionListView` on every layout flip; if `TransactionListView` owned the selection, the inspector would close every time the user switched between recorded-value and trades modes. Leaf-owned selection survives the inner tear-down. `StandardAccountView`, `CryptoWalletAccountView`, `AllTransactionsView`, and `UpcomingView` (post-PR-4) use the default init; `InvestmentAccountView` and `EarmarkDetailView` continue to use the embedded form.

**`ContentView.detail`** — wraps the switch in `NavigationStack { … }.id(selection)`. The 100-line `accountDetail(id:)` extension shrinks to a 3-arm switch on `account.type` that dispatches to named per-leaf views.

### 5.2 New per-leaf views

Each is content-only — toolbar items merge via the leaf's `NavigationStack`:

| Leaf view | Replaces | Body shape |
|---|---|---|
| `StandardAccountView` | inline `else` arm of `accountDetail` | `TransactionListView(filter: .accountId(id))` (post-PR-5: wrapped in `PositionsTransactionsSplit` for multi-instrument accounts) |
| `CryptoWalletAccountView` | inline crypto arm + `topAccessory` plumbing | `VStack { WalletAccountHeaderView; TransactionListView }` |
| `AllTransactionsView` | inline `.allTransactions` case | `TransactionListView(filter: TransactionFilter())` — extracted purely for switch-arm symmetry (every detail case dispatches to a named view), not for behaviour. Lives in the same file as `StandardAccountView` (`Features/Accounts/Views/StandardAccountView.swift`) rather than its own file. **Explicit exception to the one-primary-type-per-file convention** — both types are one-line wrappers around `TransactionListView` and pairing them makes the "one canonical transaction list, dispatched per leaf" pattern easier to read. The PR-1 description must call this exception out so `@code-review` does not flag it. |
| `EarmarkDetailView` (refactored, PR-2) | current `EarmarkDetailView` | `EarmarkOverviewWithTabs { TransactionListView } budget: { EarmarkBudgetSectionView }` |
| `InvestmentAccountView` (refactored, PR-3) | current `InvestmentAccountView` | branches on `valuationMode`; uses composition shells |
| `UpcomingView` (refactored, PR-4) | current hand-rolled List | `TransactionListView(filter: .scheduledOnly, grouping: .scheduledStatus(today: Date(), pendingPayId: $pendingPayId))`; the leaf observes `pendingPayId` via `.onChange` to drive the Pay flow |

### 5.3 Removed

- `TransactionListView`'s `TopAccessory` generic parameter.
- Both `where TopAccessory == EmptyView` convenience extensions (lines 321-373 of current `TransactionListView.swift`).
- The `safeAreaInset(edge: .top, spacing: 0) { topAccessory }` modifier on the body.
- The `listWithOptionalTopAccessory` conditional view (already reverted in PR #823).

### 5.4 Data flow

- **Toolbar items.** `TransactionListView` always supplies the standard set (filter, refresh, add). Leaves that need additional items add them via a sibling `.toolbar { … }` modifier on the leaf's body (e.g., `EarmarkDetailView`'s Edit button). SwiftUI accumulates toolbar items across the view tree into the leaf's single `NSToolbar`, because there is exactly one `NavigationStack` per leaf. No race.
  - **Ordering.** SwiftUI's accumulation order across sibling `.toolbar` modifiers is not contractually documented and can shift between OS versions. Each leaf that adds toolbar items is responsible for ordering verification at PR review time — `@ui-review` reviews the macOS-rendered toolbar against UI_GUIDE.md §6.4 placement conventions. If the visual ordering needs to be deterministic, prefer placing all of a leaf's items into a single `.toolbar { … }` block (rather than splitting between `TransactionListView` and the leaf) by using explicit `placement:` slots that don't collide. Today the only leaf adding items is `EarmarkDetailView` (Edit at `.primaryAction`); `TransactionListView`'s Add Transaction is also at `.primaryAction`. PR-2 verification includes confirming the on-screen order is acceptable; if not, move Edit to `.secondaryAction` or another non-colliding slot.
- **Search text.** `TransactionListView` owns `@State searchText` privately. The `.searchable` modifier is registered exactly once per leaf because no other code in the leaf is allowed to register one (invariant from §4.2).
- **Selection / inspector.** `TransactionListView` exposes two inits — the default form owns selection and inspector; the embedded form takes a `Binding<Transaction?>` and lets the leaf own both. `InvestmentAccountView` and `EarmarkDetailView` use the embedded form so selection survives inner-leaf tear-downs (see §5.1). All other leaves use the default form.
- **Per-leaf state** (e.g., `showingAddValue`, `selectedTab`, `positionsRange`) stays in the leaf — local UI state, not shared with `TransactionListView`.
- **Pay action** (scheduled-transaction-only). When `grouping == .scheduledStatus`, `TransactionListView` adds a "Pay Transaction…" context-menu item that writes the transaction id into the binding bundled inside the case (`grouping.scheduledStatus(today:, pendingPayId:)`). The leaf (today: `UpcomingView`) observes via `.onChange(of: pendingPayId.wrappedValue)` and runs its existing `payTransaction` flow, then resets the binding to `nil`. Same-view dispatch via a typed `Binding<>` rather than `NotificationCenter` keeps the path on `@MainActor` and `Sendable`-clean. The binding is structurally required by the `.scheduledStatus` case — there is no API path that supplies the case without supplying the binding.
  - **In-progress visual state.** While `pendingPayId.wrappedValue == transaction.id`, `TransactionListView` renders a small `ProgressView().controlSize(.small)` at the row's **trailing edge** (the leading icon stays in place — Finder's copy-progress row and Mail's send-in-progress row are the macOS-conventional precedent for this; replacing the leading icon would obscure row identity). The row also gets `.disabled(true)` to suppress further interaction, and the `ProgressView` carries a payee-parameterised accessibility label — `.accessibilityLabel("Paying \(transaction.payee ?? "transaction"), please wait")` — so VoiceOver users navigating multiple overdue rows can distinguish which row is in flight (mirrors Mail's "Sending message …" pattern, not the bare "Sending" alone). The leaf's `.onChange` handler resets `pendingPayId` to `nil` once the `payTransaction` async flow returns (success OR failure — both reset). On success the row disappears from the list naturally because the underlying transaction's scheduled state has changed; on failure the row reappears in its normal state and the leaf surfaces any error via the existing `.alert` chain (`payTransaction` already publishes errors through `transactionStore.error`). This closes a pre-existing UX gap in `UpcomingView` where the row gave no immediate feedback during the async pay flow.
- **Drag-and-drop CSV import.** `TransactionListView`'s existing `TransactionListCSVImportAddons` modifier (lines 236-245 / 271-290 of current source) handles `.dropDestination(for: URL.self)` and the create-rule sheet. After PR-1 the modifier still lives at the bottom of `TransactionListView.body`, scoped to the leaf's `NavigationStack` coordinate space. On macOS `.dropDestination` accepts drops over the view's frame, which is the full detail column — functionally unchanged from today.

## 6. Composition shells

Multi-pane layouts that recur across leaves get named composition shells. Each shell pins `TransactionListView` to a fixed structural slot.

### 6.1 `PositionsTransactionsSplit` — exists, unchanged

Vertical split (`ResizableVSplit` on macOS, plain `VStack` on iOS) with a positions panel on top and transactions on the bottom, draggable divider, autosaved divider position. Used today by `InvestmentAccountView.positionTrackedLayout` and by `TransactionListView`'s own multi-instrument-account split. The latter is removed from `TransactionListView` in PR-5 and moved into `StandardAccountView`.

### 6.2 `RecordedValueInvestmentLayout` — new (PR-3)

Extracted from `InvestmentAccountView.legacyValuationsLayout`. Named after the structural role (used for `valuationMode == .recordedValue`) rather than the temporal label "legacy"; the source body is named `legacyValuationsLayout` for historical reasons but the shell takes the structural name. Three slots:

- `summary: () -> some View` — performance tiles (today: `AccountPerformanceTiles`)
- `chartAndValuations: () -> some View` — the side-by-side macOS / stacked iOS chart + valuations layout (today: `legacyChartAndValuations`)
- `transactions: () -> some View` — `TransactionListView`

Renders `VStack { summary; chartAndValuations; Divider; transactions }`. Used by `InvestmentAccountView.legacyValuationsLayout` only.

### 6.3 `EarmarkOverviewWithTabs` — new (PR-2)

Extracted from `EarmarkDetailView`. Three slots:

- `overview: () -> some View` — the summary + savings-progress panel
- `transactions: () -> some View` — `TransactionListView`
- `budget: () -> some View` — `EarmarkBudgetSectionView`

Renders `VStack { overview; Divider; segmented Picker; switch tab { transactions | budget } }`. Owns `@State selectedTab`. Used by `EarmarkDetailView` only.

### 6.4 Why extract these as shells

For one-off shapes I would argue against extracting. These two exist because each represents a *recurring conceptual layout* that is non-trivial to get right (the split needs `ResizableVSplit` on macOS only; the tab picker needs the right autosave + `.id()` pinning so the tab flip doesn't mid-render swap which view holds focus). Extracting them keeps the leaf's body short and gives the composition a name in the codebase — easier to reuse if a third pattern emerges.

These shells are *content-only*. They do not register `.toolbar` or `.searchable`. Those still come from `TransactionListView` (and the leaf's own toolbar-item siblings). The shells just arrange views.

**Spacing convention (applies to both new shells):** outer `VStack(spacing: 0)`. Internal padding is the responsibility of each slot's content (the `summary` panel pads itself, the `overview` panel pads itself, etc.). This matches the spacing the corresponding inline bodies use today (`InvestmentAccountView.legacyValuationsLayout` line 120, `EarmarkDetailView` line 25). Per-platform inline padding values from `UI_GUIDE.md` §3.2 apply at the slot-content level, not the shell level. This convention is documented at the shell's source so PR-2 and PR-3 do not diverge on spacing.

## 7. Migration plan

Five PRs. PR-1 is load-bearing — alone it makes both reported bugs go away. PR-2…5 are quality follow-ups, each independently shippable against the new pattern.

### PR-1 — Foundation (fixes both production bugs)

- `ContentView.detail` wraps the switch in `NavigationStack { … }.id(selection)`.
- `TransactionListView` de-genericized: drop `TopAccessory`, the `topAccessory` parameter, the `safeAreaInset(edge:.top){…}` modifier, the `where TopAccessory == EmptyView` convenience extensions. Both inits stay (default + embedded-with-binding); `extraToolbar:` and `extraRowActions:` are NOT added (would force generics).
- Extract `StandardAccountView`, `CryptoWalletAccountView`, `AllTransactionsView`. `ContentView.accountDetail(id:)` becomes a 3-arm switch on `account.type` that dispatches to these.
- `UI_GUIDE.md` §3 rewrite: replace "never wrap a `.searchable`-bearing view in a structurally-flipping parent" with the simpler "exactly one `.searchable` per detail leaf, and it lives inside `TransactionListView`."
- `code-review` and `ui-review` agent rules updated to match.
- New UI test for the 5×8 navigation-sweep regression.
- Evaluate whether `TransactionListView+List.swift` can merge back into `TransactionListView.swift` post-genericization removal. The companion file exists today purely to keep the main file under the 400-line `file_length` warning; once the generic parameter, both convenience extensions, and the `safeAreaInset`+`listWithOptionalTopAccessory` machinery are gone, the line count should drop enough that one file suffices. Merge if so; keep separated if `file_length` is still pressured.
- **Cancellation-discipline verification.** The `.id(selection)` outer tear-down causes SwiftUI to cancel any in-flight `.task(id:)` blocks inside the previous leaf. Confirm during PR-1 manual verification that the tear-down path is exercised cleanly: (a) `TransactionStore.observe(filter:)` exits its `for await` loop on cancellation without logging a "Task was cancelled" error; (b) `PositionsValuator.valuate(...)` checks `Task.isCancelled` after each `await` suspension and returns early on cancellation; (c) `InvestmentStore.loadAndBuildPositionsInput(...)` honours cancellation. None of these paths should require code changes — the discipline is already in place — but rapid sidebar navigation should not produce console errors.

**Outcome at end of PR-1:** the toolbar duplicate-search-item crash is gone (per-leaf `NSToolbar` isolation), the trades-mode blank-list bug is gone (`safeAreaInset` deleted). `EarmarkDetailView`, `InvestmentAccountView`, and `UpcomingView` still have their existing bodies — but each now lives inside its own `NavigationStack`, so they are crash-safe even though they have not yet been migrated to the new shells.

### PR-2 — `EarmarkDetailView`

- Extract `EarmarkOverviewWithTabs` shell.
- `EarmarkDetailView` body shrinks to `overview` + shell.
- The "Edit" toolbar item moves alongside (sibling `.toolbar` in the leaf — merges into the leaf's `NavigationStack`).

### PR-3 — `InvestmentAccountView`

- Extract `RecordedValueInvestmentLayout` shell.
- Both layouts (`legacyValuationsLayout` / `positionTrackedLayout`) compose existing shells + plain `TransactionListView`.
- The current `makeAccountTransactionList()` helper drops because its embedded-init form is gone.
- Keep the inner `.id(ValuationMode)` for the layout-flip case (still useful within a single leaf).
- "Add Value" toolbar item moves alongside.

### PR-4 — `UpcomingView`

- Add `grouping: Grouping = .flat` parameter to `TransactionListView` (non-optional, defaulted; cases `.flat` / `.byDate` / `.scheduledStatus(today: Date, pendingPayId: Binding<Transaction.ID?>)` per §5.1). When `grouping == .scheduledStatus`, the list groups rows into Overdue / Upcoming sections and includes a "Pay Transaction…" context-menu item that writes the row's transaction id into the case's `pendingPayId` binding.
- Migrate `UpcomingView` to a thin wrapper around `TransactionListView(filter: .scheduledOnly, grouping: .scheduledStatus(today: Date(), pendingPayId: $pendingPayId))`. The leaf owns `@State private var pendingPayId: Transaction.ID?` and observes it via `.onChange(of: pendingPayId)` to run the existing `payTransaction` flow, then resets it to `nil`.
- Delete the hand-rolled `List` in `UpcomingView`.

No `NotificationCenter` for the new Pay wiring — same-view dispatch via the typed binding satisfies `CONCURRENCY_GUIDE.md` §8. The pre-existing `.requestTransactionEdit` / `.requestTransactionDelete` notification handlers in `UpcomingView` (lines 46-57) stay as-is — they are cross-view dispatch from window menus, out of scope for this PR (see §10 follow-up).

This is the largest single piece because `TransactionListView` gains a sectioning capability — but the capability is purely additive (one new enum, one new code path inside the existing `List`/`ForEach`) and used by exactly one new caller. No new generic parameters.

### PR-5 — Cleanup

- Move the multi-instrument positions split (`shouldShowPositionsSplit` / `PositionsTransactionsSplit`) out of `TransactionListView+List.swift` and into `StandardAccountView`.
- Removes the last `if`-branch from `TransactionListView`'s body — body shape becomes provably uniform by inspection.
- Pure refactor; no behaviour change.

### Per-PR workflow (applies to every PR)

1. Implement the change.
2. `just format` then `just format-check` clean.
3. `just test` (or at minimum `just build-mac`) green.
4. **Run the relevant review agents and fix every finding before pushing.** Repeat until each agent reports no issues:
   - **PR-1**: `@code-review`, `@ui-review`. Critical because PR-1 touches the structural pattern itself.
   - **PR-2 / PR-3 / PR-4**: `@code-review`, `@ui-review`. Each leaf migration touches view code and must comply with both the code guide and the new UI invariant.
   - **PR-5**: `@code-review`. Pure refactor.
5. Manual verification (see §9 verification matrix).
6. Push, open PR, add to merge queue. Reviewer findings reported by CI on the open PR are addressed in follow-up commits to the same branch *before* the queue picks it up — once queued, the PR is frozen per project convention.

## 8. Enforcement

### 8.1 Codified invariants (live in `UI_GUIDE.md` §3, post-PR-1)

- The detail column wraps every leaf in `NavigationStack { … }.id(selection)`. The `.id` is load-bearing (forces tear-down between leaves).
- **Searchable invariant (two-part rule, exhaustive):**
  - (a) Any leaf that contains a `TransactionListView` (e.g., `StandardAccountView`, `CryptoWalletAccountView`, `AllTransactionsView`, `EarmarkDetailView`, `InvestmentAccountView`, `UpcomingView`) registers exactly one `.searchable(text:)`, and it lives inside `TransactionListView`. No other code in such a leaf may register `.searchable`.
  - (b) Any leaf that does NOT contain a `TransactionListView` (e.g., `CategoriesView`) may register at most one `.searchable(text:)` directly on its own root view. Two `.searchable` modifiers in the same leaf are forbidden regardless of leaf type.
- `TransactionListView` is non-generic. It owns the standard transaction-list toolbar items (filter / refresh / add). Leaves contribute additional items via a sibling `.toolbar { … }` modifier on the leaf's body — these merge into the leaf's `NSToolbar` because there is exactly one `NavigationStack` per leaf. There is no `extraToolbar:` parameter on `TransactionListView` — it would force generics, contradicting the non-generic invariant.
- **Inspector placement:** the `.transactionInspector(...)` modifier (the per-leaf instance of `OptionalTransactionInspector`) attaches at the leaf's body level — i.e., inside the per-leaf `NavigationStack`, on the outermost view of the leaf's content. SwiftUI hoists the inspector to the window level for rendering, so the placement does not affect layout, but keeping the modifier at the leaf level scopes the inspector's binding to the leaf's `@State selectedTransaction` (which is required for `InvestmentAccountView` and `EarmarkDetailView` whose selection survives inner-leaf tear-downs). Do not move it up to the `ContentView.detail` level.
- **VoiceOver focus:** `.id(selection)` between leaves causes a full view-tree tear-down, after which SwiftUI defaults VoiceOver focus to the first focusable element (typically a toolbar button). Leaves that need focus to land on content (today: `InvestmentAccountView` via `@AccessibilityFocusState`) preserve their existing focus-anchoring code as-is. The per-leaf wrap does not require new focus-anchoring at the `ContentView.detail` level — the existing pattern is sufficient. PR-1 verification includes a manual VoiceOver pass to confirm focus lands sensibly after each sidebar selection change; if it does not, the remedy is to add `@AccessibilityFocusState`-driven anchoring to the affected leaf, not to the wrap.
- Composition shells (`PositionsTransactionsSplit`, `RecordedValueInvestmentLayout`, `EarmarkOverviewWithTabs`) are content-only — they never register `.toolbar` or `.searchable`.

### 8.2 Agent rules (Critical-tier, added to `code-review` and `ui-review` agents)

- *Detail leaf without `NavigationStack` wrap.* Any new sidebar-selection `case` in `ContentView.detail` that is not enclosed by the `NavigationStack { … }.id(selection)` outer is a Critical finding.
- *Second searchable in a detail leaf.* Any `.searchable(` call inside a file under `Features/` that is not on a `TransactionListView` instantiation, when that file is reachable from a detail-column leaf, is a Critical finding.
- *Re-implemented transaction list.* Any `List(selection:)` in a detail-column file that iterates over `Transaction`s without going through `TransactionListView` is a Critical finding (legacy: `UpcomingView` until PR-4 lands).
- *`TransactionListView` regaining a generic parameter or `topAccessory`-shaped slot.* Critical finding on any diff to `TransactionListView.swift` that re-introduces those.

## 9. Verification

### 9.1 Manual verification matrix

| Verification | PR-1 | PR-2 | PR-3 | PR-4 | PR-5 |
|---|:-:|:-:|:-:|:-:|:-:|
| 5×8 navigation sweep across investment / crypto / bank accounts (no toolbar crash) | ✓ | ✓ | ✓ | ✓ | ✓ |
| Trades-mode investment account shows transactions list (Trust Shares, IOZ/VGS) | ✓ | | ✓ | | ✓ |
| Wallet-header path renders on crypto accounts (Trust Ethereum) | ✓ | | | | |
| Earmark Transactions / Budget tab flips work; Edit toolbar item present | | ✓ | | | |
| Investment Add Value sheet opens; both layouts switch cleanly | | | ✓ | | |
| Upcoming overdue / upcoming sections render; Pay action works; per-row context menu intact | | | | ✓ | |
| Multi-instrument bank / asset accounts still show positions split | | | | | ✓ |
| **iPhone manual review** of nested `NavigationStack` at end of PR-1 (revisit if it looks bad) | ✓ | | | | |
| Existing UI tests (`just test-mac`) pass | ✓ | ✓ | ✓ | ✓ | ✓ |

### 9.2 Automated regression test (PR-1)

A new UI test in `MoolahUITests_macOS/` performs the 5×8 navigation-sweep that originally reproduced the toolbar-bridge crash:

- Seeds a profile with at least one investment account, one crypto account, and several bank accounts.
- Iterates the sidebar selection across them in a deterministic order, 40 selections total (5 cycles × 8 accounts).
- Asserts: app remains responsive (XCTest implicit — no crash); the transactions list is non-empty for each account that should have transactions.

This catches regression of failure mode (A) at CI time.

## 10. Open questions / follow-ups

- **iPhone nested-stack review** is the only known unknown. The user has explicitly accepted the risk and committed to manual review at the end of PR-1. If the inner `NavigationStack` produces undesirable iPhone chrome (double nav bars, awkward back-button titles), the wrap becomes `#if os(macOS)`-only. iPhone has not exhibited either failure mode in production, so falling back to the unconditional macOS-only wrap is safe.
- **`RecentlyAddedView`** — same anti-pattern, deferred to issue [#824](https://github.com/ajsutton/moolah-native/issues/824). When picked up, applies the same pattern (its own `NavigationStack` is provided by the outer wrap; the existing `.searchable` inside the conditional `mainContent` becomes a Critical agent finding once the rule is in place — that issue is the path to fixing it).
- **`EarmarksView`** — orphan, deleted in PR #825 (no longer in the navigation graph).
- **Detail leaves outside the transaction-list family** (`CategoriesView`, `AnalysisView`, `ReportsView`) get the `NavigationStack` wrap for free as part of PR-1's `ContentView.detail` change, but their internal structure is unchanged. They each register `.toolbar` (none register `.searchable` outside `CategoriesView`); the new invariant (§8.1, two-part rule) permits a leaf without a `TransactionListView` to register at most one `.searchable` directly — `CategoriesView` qualifies. The agent rule (§8.2) implements both parts.
- **Pre-existing notification-based cross-view dispatch** (`.requestTransactionEdit`, `.requestTransactionDelete`) — `CONCURRENCY_GUIDE.md` §8 lists callbacks/completion handlers as anti-patterns; `NotificationCenter` is in spirit the same shape. Today `TransactionListView` and `UpcomingView` both `.onReceive` these notifications because they're posted from window-level menu Commands and the sender does not know which list view is currently visible. Replacing them requires routing through `focusedSceneValue`-style focused-action bindings — a separate, larger refactor that would touch the menu Commands code, the `FocusedValues` extensions, and every transaction-list leaf. **Out of scope for this design**; tracked as issue [#826](https://github.com/ajsutton/moolah-native/issues/826) (filed 2026-05-09). The new Pay action does NOT use this pattern (it uses a typed `Binding<Transaction.ID?>` per §5.4).
