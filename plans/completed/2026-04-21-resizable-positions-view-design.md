# Resizable Positions View — Design

## Problem

`PositionsView` is rendered above the transactions list in two call sites:

- **Account detail** (`App/ContentView.swift` → `TransactionListView` with non-empty `positions:`) — header + responsive table.
- **Investment account detail** (`Features/Investments/Views/InvestmentAccountView.swift`) — header + chart + table, with `TransactionListView` (no positions) below.

Currently both sites use a `VStack(spacing: 0)` that lets the positions panel and the transactions list negotiate vertical space freely. For accounts with many positions, the panel crowds out transactions; for accounts with a few positions, the panel wastes space. On iOS the stacked layout is particularly cramped.

## Goals

- Default to showing ~5 instrument rows so the positions panel has a predictable initial height.
- Allow the user to adjust the split.
- Preserve the chart's natural height in the investment view (only the instruments table flexes).
- Use platform-native patterns: a real split pane on macOS; a segmented control on iOS where stacking doesn't scale.

## Design

### macOS — native `NSSplitView` via `NSViewRepresentable`

The positions panel and transactions list become the two panes of a vertical split. We wrap `NSSplitView` rather than SwiftUI's `VSplitView` because SwiftUI doesn't expose a way to persist the divider position across view rebuilds or app relaunches.

**New component: `ResizableVSplit<Top, Bottom>` (`Shared/Views/ResizableVSplit.swift`)**

- `NSViewRepresentable` wrapping `NSSplitView` with `isVertical = false` and `dividerStyle = .thin`.
- `autosaveName` parameter — `NSSplitView` automatically persists the divider position in `UserDefaults` under this name. Pass a single shared name (`"positions-transactions-split"`) so a resize in one account carries to all.
- `initialTopHeight` parameter — applied via `setPosition(_:ofDividerAt:)` only when no autosaved frame exists. Default 180pt ≈ 5 rows + column header + padding.
- `minTopHeight` (default 80pt) and `minBottomHeight` (default 200pt) enforced via an `NSSplitViewDelegate` (`splitView(_:constrainMinCoordinate:)` and `constrainMaxCoordinate`).
- Each child hosted in an `NSHostingView<Child>`; `updateNSView` swaps `rootView` so SwiftUI state changes propagate.
- Coordinator retains references to both hosting views and acts as the split delegate.

### iOS — segmented picker

Stacking positions and transactions on iPhone screens doesn't give either enough room, and a custom drag splitter duplicates a well-understood iOS idiom. A segmented `Picker` at the top lets the user swap between "Positions" and "Transactions". The active view fills the available space.

**iOS layout inside `PositionsTransactionsSplit`:**

- `Picker` styled `.segmented` with two cases.
- Selection is `@State` — per-view lifetime, not persisted. (Matches the existing `EarmarkDetailView` pattern.)
- Default tab is chosen by the caller:
  - Account detail → `.transactions` (the common case is adding/reviewing activity).
  - Investment account detail → `.positions` (positions are the primary information).

### Shared container

**New component: `PositionsTransactionsSplit<Positions: View, Transactions: View>` (`Shared/Views/Positions/PositionsTransactionsSplit.swift`)**

Encapsulates the platform choice so call sites don't repeat `#if os(macOS)`:

```swift
struct PositionsTransactionsSplit<Positions: View, Transactions: View>: View {
  enum DefaultTab { case positions, transactions }

  let defaultTab: DefaultTab
  @ViewBuilder let positions: () -> Positions
  @ViewBuilder let transactions: () -> Transactions

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
      iOSPicker
    #endif
  }
}
```

### Call-site changes

**`Features/Transactions/Views/TransactionListView.swift`**

Extract the existing `List(selection:…) { … }` block (including its `isLoading` footer) into a private `transactionsList` computed property, then replace the `VStack` in `listView`:

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

The existing `Divider()` between `PositionsView` and the list is removed — the split itself is the boundary.

**`Features/Investments/Views/InvestmentAccountView.swift`**

Wrap the non-legacy branch in the split. The legacy valuations branch (separate layout with side-by-side chart + valuations list) is unaffected. The embedded `TransactionListView` stays as-is (it already has no positions panel, since `positions:` is not passed).

```swift
if investmentStore.hasLegacyValuations {
  // unchanged
} else {
  PositionsTransactionsSplit(defaultTab: .positions) {
    if isLoadingPositions && positionsInput.positions.isEmpty {
      ProgressView().frame(maxWidth: .infinity).padding()
    } else {
      PositionsView(input: positionsInput, range: $positionsRange)
    }
  } transactions: {
    TransactionListView(/* existing args */)
  }
}
```

The `Divider()` between positions and transactions is removed.

### What doesn't change

- `PositionsView`, `PositionsHeader`, `PositionsChart`, `PositionsTable` — unchanged. The table already scrolls internally when its container is bounded.
- `PositionsViewInput` — unchanged.
- Earmark detail, reports drill-down, all-transactions — unchanged (no positions panel today).
- All existing tests — unchanged.

## Persistence behaviour

- **macOS:** `NSSplitView.autosaveName` stores divider geometry in `UserDefaults` (`NSSplitView Subview Frames <name>`). One shared name across both call sites so the user adjusts once.
- **iOS:** selected tab is not persisted — resets to the caller's default when the detail view reopens. This matches existing iOS detail-view behaviour (e.g., `EarmarkDetailView`).

## Testing

- Previews for `ResizableVSplit` and `PositionsTransactionsSplit` covering both the populated and empty states.
- Existing `PositionsView` previews and tests stay valid.
- Manual verification (the relevant checks here are UI-level and not well-covered by XCUITest per project guidance):
  - macOS: open an account with >5 positions, confirm ~5-row default, drag divider, close and reopen app → divider position restored. Open a different account → same divider position applies.
  - macOS: investment account shows chart + ~5 rows of positions by default; resize affects the whole positions panel including chart (chart grows/shrinks with the pane as native `NSSplitView` behaves).
  - iOS: account detail opens on "Transactions"; toggle to "Positions", instruments visible; reopen detail view → back on default tab.
  - iOS: investment account opens on "Positions"; chart and table share full screen; toggle shows transactions.

## Trade-offs considered

- **SwiftUI `VSplitView` vs. wrapped `NSSplitView`.** `VSplitView` is ~zero code but doesn't expose the divider position; user resizes don't persist across rebuilds, let alone launches. Wrapping `NSSplitView` adds ~80 LOC but gives free `autosaveName` persistence.
- **One global `autosaveName` vs. per-context.** Per-context (e.g., per account id) would balloon `UserDefaults` keys and surprise users with inconsistent panel sizes. Global matches the Finder-sidebar convention.
- **iOS tabs vs. collapsible header vs. drill-down.** Tabs won because each pane gets full vertical space and the chart benefits most from that. Drill-down is viable but adds a navigation step to a frequent action.
- **Resize target: whole panel vs. just the table.** Whole panel — matches how `NSSplitView` inherently works, and on macOS the chart benefits from extra vertical room when the user drags down. "5 lines of instruments by default" is expressed through the initial-height constant calibrated for header + 5 rows, not through per-subview clipping.

## Files touched

New:
- `Shared/Views/ResizableVSplit.swift`
- `Shared/Views/Positions/PositionsTransactionsSplit.swift`

Modified:
- `Features/Transactions/Views/TransactionListView.swift`
- `Features/Investments/Views/InvestmentAccountView.swift`
