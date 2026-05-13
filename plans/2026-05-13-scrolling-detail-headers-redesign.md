# Scrolling Detail-View Headers — Redesign

**Status:** Design, awaiting implementation plan
**Date:** 2026-05-13
**Supersedes:** `plans/2026-05-12-scrolling-detail-headers-design.md`
**Platforms affected:** macOS only — iOS layout is unchanged

## Why this redesign exists

The 2026-05-12 design and its implementation (branch `ui/scrolling-detail-headers`, 20 commits) shipped most of the structural change — `topAccessory` slot on `TransactionListView`, per-leaf wiring on all five macOS detail leaves, per-leaf `NavigationStack(.id(selection))` already merged separately — but the **positions table** stayed visibly broken inside the `topAccessory` row, and the supporting machinery accumulated workarounds (hardcoded heights, AnyView boxing, per-leaf conditional inits).

This redesign documents what the rendering empirically does, not what the previous spec hoped it would do, and revises the mechanism.

## Empirical findings (validated 2026-05-13 via `mcp__xcode__RenderPreview`)

A test preview placed `PositionsTable` inside a `List` row followed by 20 transaction-style rows — the actual production shape inside `TransactionListView.topAccessory`. Six variants were rendered:

| Variant | Result |
|---|---|
| **Current production** — `Table` + `.frame(height: 28 + 36*rows + 4)` | ❌ Column header row clipped. Only a stray sort chevron appears where the header titles should be. |
| `Table` + `.fixedSize(horizontal: false, vertical: true)` | ❌ Table collapses entirely. Invisible. |
| `Table` + `.scrollDisabled(true)` | ❌ Column-divider hairlines render at the top; **no rows visible**. |
| **Grid** (new) — `Grid { GridRow … }` | ✅ All rows render. Header row, body rows, alternating tinting. Sizes naturally to content. Transactions immediately follow with no gap. |
| `safeAreaInset(.top) + Table` (pinned, bounded `.frame(height: 220)`) | ✅ Full native chrome (sort indicators, alternating row tinting). But header is **pinned** — doesn't scroll off. |
| `safeAreaInset(.top) + Table + scroll-offset translation` | ❌ Translation works, but the `safeAreaInset` keeps reserving the header's original space. When fully translated off, there's a header-height empty gap above transactions. |
| **Always-emit `Section { EmptyView() }` with neutralised row modifiers** | ✅ Zero visible pixels. Transaction 0 starts at the top with no gap or separator. (Means the optional-row machinery in the slot is unnecessary — see Section 2 below.) |

**Conclusion:** SwiftUI `Table` on macOS has **no working intrinsic-content-size mode**. To use `Table`, an externally-supplied bounded height is mandatory. Inside an unbounded vertical container (a `List` row), `Table`'s rendering cannot be salvaged with `fixedSize`, `scrollDisabled`, or any other public SwiftUI modifier — the production "fix" of `.frame(height: …row math…)` does not produce a correct render today.

The 2026-05-12 design's preference for `Table`-with-computed-height was made without this validation. The implementation cycle then attempted to repair the rendering by adding successive workarounds (`minHeight: 530`, "flatten to VStack", "branch on resolvability", `macOSTableHeight(rowCount:)`) without addressing the root cause.

## Mechanism

### 1. Positions table on macOS is a `Grid`, not a `Table`

`PositionsTable.swift`'s `wideLayout` is replaced with a `Grid`-based layout. The `Table`-specific shape (`Table(rows, selection:, sortOrder:)`, `TableColumn`, `KeyPathComparator` directly bound to the Table) is removed on macOS.

```swift
@ViewBuilder private var wideLayout: some View {
  Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 0) {
    headerRow                                       // tappable sort buttons + active-sort chevron
    Divider().gridCellColumns(6)
    ForEach(Array(sortedRows.enumerated()), id: \.element.id) { item in
      // Closure parameter tuple destructuring (`{ idx, row in }`) was
      // removed in Swift 4 (SE-0110) — destructure inside the body.
      let (idx, row) = (item.offset, item.element)
      PositionsTableRow(
        row: row,
        isSelected: selection?.id == row.id,
        alternateBg: !idx.isMultiple(of: 2),
        toggleSelection: { … }
      )
    }
  }
  .padding(.horizontal, 12)
  .dynamicTypeSize(.medium ... .xLarge)             // see Risk #6
}
```

`PositionsTableRow` is a dedicated row subview that owns the per-row hover state (`@State var isHovered: Bool`) so SwiftUI's diffing isolates re-renders to a single row instead of re-evaluating the whole grid on hover. It also carries the row-level accessibility shape (Section 1.1).

The header row is `HStack`-laid-out per column inside its own `GridRow`. Each column header is a `.buttonStyle(.borderless)` button (not `.plain` — see FOCUS_GUIDE.md §1.1 "Focusable views" focusable-controls table, which lists `.bordered`/`.borderless` as Space-activatable when Full Keyboard Access is enabled and flags `.plain` as the long-standing Space-activation gap). The positions table's sort headers must be Space-activatable for Full Keyboard Access. The header builder shape per column:

```swift
GridRow {
  Button { toggleSort(.instrument) } label: {
    HStack(spacing: 4) {
      Text("Instrument")
      if sort.column == .instrument {
        Image(systemName: sort.direction == .ascending ? "chevron.up" : "chevron.down")
          .imageScale(.small)
      }
    }
    .font(.caption)
    .foregroundStyle(.secondary)
  }
  .buttonStyle(.borderless)
  .accessibilityAddTraits(.isHeader)
  .accessibilityLabel(headerLabel(for: .instrument))
  // …trailing-alignment for numeric columns via gridColumnAlignment(.trailing)…
}
```

Sort indicator uses `chevron.up` (ascending) / `chevron.down` (descending) at `.imageScale(.small)`, rendered to the **right** of the column title within the same `HStack` (matches Finder / Mail / Calendar convention on macOS). Inactive columns render no chevron — they receive a sort indicator only on activation.

#### 1.1 Accessibility shape

Native SwiftUI `Table` advertises a "Table" trait, marks column headers as headings, and lets VoiceOver navigate by column. A bare `Grid` does none of this. The replacement must restore the affordances:

- **Header cells.** Each header button uses `.accessibilityAddTraits(.isHeader)` plus `.accessibilityLabel(_:)` describing both the column and the current sort state: `"Instrument, sorted ascending"` when the column is active, `"Instrument, tap to sort"` otherwise. The chevron is decorative (`.accessibilityHidden(true)`).
- **Data rows.** Each `PositionsTableRow` wraps its `GridRow` in `.accessibilityElement(children: .combine)` and assigns an `.accessibilityLabel(_:)` that reads all six values plus the exchange (when present) as a natural sentence: `"BHP, ASX, Stock, 250 shares, $45.30 unit price, $10,125 cost, $11,325 value, gain of $1,200, up 11.9 percent."` The exchange field comes from `Instrument.exchange` and matches the existing `instrumentLabel(for:)` behaviour in `PositionsTable.swift` — instruments with shared tickers on different exchanges (BHP on ASX vs LSE) must remain distinguishable to VoiceOver. Per UI_GUIDE.md §9, this is the canonical grouped-data pattern.
- **Selection.** When selected, the row appends `.accessibilityAddTraits(.isSelected)`.
- **The grid container.** `Grid` itself takes `.accessibilityLabel("Positions, \(rowCount) instruments")` so the user knows the structural context when VoiceOver enters the panel.

The native "Table" trait is not reproducible from SwiftUI primitives (it's bridged from `NSTableView` internally). This is documented as a deferred affordance — see Risk #7 for the tracked-issue note.

#### 1.2 Selection / hover / alternating-row colours (semantic tokens)

Per UI_GUIDE.md §5, no hand-tuned `Color.opacity` values. All row-state backgrounds use AppKit semantic colour tokens (macOS only; `narrowLayout` on iOS is unchanged):

```swift
#if os(macOS)
private static func rowBackground(
  isSelected: Bool,
  isHovered: Bool,
  isFocused: Bool,
  alternateBg: Bool
) -> Color {
  if isSelected {
    return isFocused
      ? Color(nsColor: .selectedContentBackgroundColor)
      : Color(nsColor: .unemphasizedSelectedContentBackgroundColor)
  }
  if isHovered {
    return Color(nsColor: .controlAccentColor).opacity(0.10)  // accent-hue hover tint (system convention)
  }
  return Color(nsColor: NSColor.alternatingContentBackgroundColors[alternateBg ? 1 : 0])
}
#endif
```

Why these specific tokens:
- `selectedContentBackgroundColor` is the focused-table selection background. Honors the user's accent colour and Increase Contrast.
- `unemphasizedSelectedContentBackgroundColor` is the unfocused-table selection grey. Important — a `.accentColor.opacity(0.18)` approximation never desaturates when the window loses key state.
- `NSColor.alternatingContentBackgroundColors` is a two-element array of system-resolved row tints. The system automatically returns transparent / no-alternation when Increase Contrast is enabled — `Color.secondary.opacity(0.05)` would draw a flat grey in both cases, defeating the accessibility intent.
- The hover token is `controlAccentColor` at 10% opacity — this is the only place where a SwiftUI `.opacity()` is used, because AppKit does not expose a single "row hover" semantic colour; the alpha is the system's actual published convention (see Apple's `NSTableRowView` hover treatment).

**Window-key vs unemphasised selection.** Native `NSTableView` automatically swaps between `selectedContentBackgroundColor` (window is key) and `unemphasizedSelectedContentBackgroundColor` (window is main but not key, or background) — SwiftUI does not bridge this swap into `Color(nsColor:)`, so the `Color` value is static and we must drive the swap ourselves. The correct API is `@Environment(\.controlActiveState)` (available since the first SwiftUI release; no deployment-target gate at the project's macOS 26 minimum), values `.key` / `.active` / `.inactive`. `@FocusState` is **not** the right tool here — it tracks first-responder among views that opted-in via `.focused()` and has no "any descendant has focus" semantics. The Grid root reads `controlActiveState` and passes `isFocused: (controlActiveState == .key)` into `rowBackground(...)`.

#### 1.3 Sort cycle

`SortColumn` enum + `SortState { column: SortColumn, direction: SortDirection }` + a `toggleSort(_ column: SortColumn)` method. Cycle:

- Tap **inactive** column → activate it, direction = `.descending` (largest first — the existing production default with `\.valueQuantity, order: .reverse`).
- Tap **active** column → flip direction (`.descending` ↔ `.ascending`).
- Sort never resets to "no sort" — there is always an active sort column.

**Deliberate HIG deviation:** macOS convention (Finder/Mail) is ascending-on-first-activation. We use descending-on-first-activation for financial data because "largest first" is the more useful default for monetary columns. Justification stays in source comments so future contributors don't "correct" it.

The state machine is pure (no UI dependency) and lives on a dedicated value type — unit-testable without rendering.

#### 1.4 What we keep vs. what we lose vs. native `Table`

What we keep:
- Identical column set: Instrument, Qty, Unit Price, Cost, Value, Gain.
- `.monospacedDigit()` on all five numeric outputs: Qty, Unit Price, Cost, Value, the signed-currency portion of Gain, and the percent suffix of Gain.
- Per-row selection via tap-to-toggle (highlight via §1.2 tokens).
- Alternating row tinting via §1.2 tokens.
- Hover treatment via §1.2 hover token + `PositionsTableRow.@State isHovered`.
- Accessibility labels on the instrument and gain cells from the current `PositionsTable.swift` (unchanged).
- The Grid flattens all rows (`groups.flatMap(\.rows)`), identical to current `Table` behaviour; `showsGroupSubtotals` continues to have no effect in the wide layout (it drives the `narrowLayout` only).
- The `gain` colour `(.red / .green)` exception in UI_GUIDE.md §5 applies as today. The §5 "Selected-Row Contrast Override" pattern (`SidebarRowView.amountColorOverride`) is **not** imported here — the positions panel's selection background is the in-detail-column accent, not the focused-sidebar blue, so `.red` / `.green` read cleanly against it.

What we lose vs. native `Table`:
- Native column-resize affordance — no other table in this app exposes this; not a regression in user expectation.
- Native column-reorder by drag — not used today.
- Native column-header context menu (right-click) — not used today; can be re-introduced as `.contextMenu` on each header button if a future requirement appears.
- Native row keyboard cursor (Up/Down inside the table) — see Risk #7. The outer `List`'s arrow keys still handle transaction-row focus; positions-row keyboard navigation is deferred.
- Native VoiceOver "Table" trait — see Risk #7. Replacement: structural traits per §1.1 and a grouped row label.

iOS keeps `narrowLayout` (`PositionRow`-based) unchanged.

### 2. `TransactionListView` keeps the generic; the metatype check and per-leaf branching go away

`TransactionListView<TopAccessory: View>` stays as today — keeping the generic is free at runtime (no `AnyView` boxing) and is the standard SwiftUI shape for optional view slots. What changes is that the `Section` is **always emitted**, regardless of what `TopAccessory` resolves to:

```swift
// TransactionListView+List.swift
List(selection: selectedTransactionBinding) {
  Section {
    topAccessory
      .listRowInsets(EdgeInsets())
      .listRowSeparator(.hidden)
      .listRowBackground(Color.clear)
      .selectionDisabled()
      .accessibilityIdentifier(UITestIdentifiers.TransactionList.headerContainer)
  }
  listContent
}
```

Empirical validation confirms `Section { EmptyView() }` with these row modifiers contributes zero visible pixels (no gap, no hairline). This means:

- The `TopAccessory.self != EmptyView.self` metatype comparison can be deleted.
- Callers that previously had to choose between two inits ("with topAccessory" / "without") use **one** init with a default of `{ EmptyView() }`.
- Callers that previously had to branch conditionally based on whether their accessory had renderable content can use a single `@ViewBuilder` closure with an internal `if`/`else`. When the runtime branch returns `EmptyView`, the row is structurally present but contributes zero pixels.

What this removes:
- `TopAccessory.self != EmptyView.self` runtime metatype comparison in `TransactionListView+List.swift`.
- `StandardAccountView`'s two-arm `if let panel { … } else { … }` over the panel.
- `CryptoWalletAccountView.hasResolvableWalletHeader` precondition and the call-site fork.
- Per-leaf duplication of "with-topAccessory" / "without-topAccessory" init invocations.

What stays:
- The generic parameter `TopAccessory: View` with default `EmptyView` — unchanged from today.
- The `accessibilityIdentifier(UITestIdentifiers.TransactionList.headerContainer)` on the row. This now lights up on every detail leaf (even when the accessory is `EmptyView`), but it's still an accurate marker of where the header lives — UI tests can use it as a stable post-condition sentinel for the scroll surface itself, not for accessory presence.

Note: the per-leaf accessibility-identifier semantics shift slightly. Today the identifier resolves only when the accessory is non-empty; under this redesign it resolves on every detail leaf. The existing `ScrollingDetailHeaderTests.swift` asserts presence on the brokerage account, which still passes. If we want a stricter "the accessory is non-empty" assertion, add a child identifier inside the accessory builder; the existing test doesn't require this.

### 3. `MultiInstrumentPositionsTopAccessoryHost` simplifies

Today the host yields the panel via a closure typed `(AnyView?) -> Content`. With the always-emit `Section` and the always-`some-View` topAccessory, the host yields a typed panel directly; the leaf's `topAccessory` closure embeds it via switch:

```swift
struct MultiInstrumentPositionsTopAccessoryHost<Content: View>: View {
  let positions: [Position]
  let hostCurrency: Instrument
  // …
  // `content` (not `body` — `body` is the `View` protocol requirement,
  // can't double as a stored property). Matches the existing production
  // type's parameter name.
  @ViewBuilder let content: (PositionsPanel) -> Content

  enum PositionsPanel {
    case panel(PositionsViewInput, Binding<PositionsTimeRange>)
    case loading
    case absent
  }

  var body: some View { … resolves the .task(id:) and yields a PositionsPanel that is passed into `content` … }
}

// at the leaf call site:
TransactionListView(
  title: …,
  …,
  topAccessory: {
    switch panel {
    case .panel(let input, let range): PositionsView(input: input, range: range)
    case .loading: ProgressView().frame(maxWidth: .infinity).padding()
    case .absent: EmptyView()    // collapses to zero pixels in the Section
    }
  }
)
```

No `AnyView` anywhere. The panel enum's three cases are concrete view types, the `@ViewBuilder` closure builds a `_ConditionalContent`/`_ExhaustiveTrioContent` view that the generic `TopAccessory` infers as.

### 4. Per-leaf changes

The leaf bodies retain the same shape as the 2026-05-12 design (one `TransactionListView` per leaf with a `topAccessory:` builder), only the call sites simplify. iOS branches unchanged.

Concrete per-leaf simplifications:

- **`StandardAccountView`** — single `TransactionListView` call (drop the `if let panel { … } else { … }`).
- **`CryptoWalletAccountView`** — single `TransactionListView` call; the `topAccessory` builder is `VStack(spacing: 0) { walletHeader; positionsPanel.view }` where `walletHeader` returns `EmptyView` when the chain isn't resolvable.
- **`InvestmentAccountView.positionTrackedLayout`** — single `TransactionListView` call; the `topAccessory` builder yields `PositionsView` (which now hosts the Grid-based positions table).
- **`InvestmentAccountView.legacyValuationsLayout`** — single `TransactionListView` call; the `topAccessory` builder yields `VStack(spacing: 0) { legacySummary; legacyChartAndValuations; Divider() }`.
- **`EarmarkDetailView`** — body shape unchanged (segmented picker stays pinned above the body switch); the `topAccessory: { overviewPanel }` call no longer needs `selectedTransaction:` parameter wrangling around the generic.

## Alternatives considered

### `safeAreaInset(.top) + scroll-offset translation` (rejected with empirical evidence)

The 2026-05-12 spec rejected this without testing; we re-tested.

Empirical result: the `safeAreaInset` keeps reserving the header's natural space even after the inset's content is translated off-screen via `.offset(y:)`. When the header is fully translated (`scrollOffset == headerHeight`), there is a header-height blank gap at the top of the visible list area. Transactions don't fill it.

A possible variant — header in `.overlay(alignment: .top)` + an invisible `Color.clear` spacer first row in the `List`, both translated at the same rate — would work but is structurally equivalent to "the header is a heavy first row of the List" (the current `topAccessory` pattern). The complexity moves to the spacer/header height synchronization without reducing.

`safeAreaInset + Table` (pinned, no translation) does render correctly, but the header is permanently visible — that explicitly is not the goal.

### Keep `Table`, give it an externally-measured height (rejected)

Measuring the table's natural height via `GeometryReader` / `PreferenceKey` against a hidden non-Table rendering, then applying that height to the real `Table`, would in principle bypass the hardcoded constants. In practice the measurement still depends on row-height assumptions (Dynamic Type, instrument cell shape, group subtotals on iOS), and the measurement-feedback loop has historically introduced layout oscillation. `Grid` sidesteps the problem entirely.

### Replace `List` with `ScrollView { LazyVStack { … } }` (rejected)

Maximises layout freedom but loses every `List`-only behaviour the rest of `TransactionListView` relies on: keyboard multi-select, `swipeActions`, row separators, right-click context menu coupled to selection, `.searchable`, `.refreshable`, VoiceOver "List/Table" semantics. Each of those would need a hand-rolled reimplementation. Not justified when `Grid` solves the actual rendering bug.

## Risks

1. **Manual sort affordance regressions.** Tap-to-sort on a custom Grid header is a new code path; needs explicit unit tests for the cycle (see §1.3). Mitigation: a `SortColumn` enum + a `toggleSort(_:)` method makes the state machine grep-able and unit-testable without UI rendering.

2. **Manual selection / hover / alternating-row chrome must use AppKit semantic tokens — not opacity literals.** Native `Table`'s row chrome is system-resolved (honours accent colour, focused-vs-unfocused window state, Increase Contrast, and disables alternation when the user opts out). Section 1.2 prescribes the exact `NSColor` tokens (`selectedContentBackgroundColor`, `unemphasizedSelectedContentBackgroundColor`, `controlAccentColor.opacity(0.10)` for hover, `alternatingContentBackgroundColors`) so we get those behaviours back. A reviewer who sees `.accentColor.opacity(...)` in implementation should treat it as a regression.

3. **Chart inside the topAccessory.** `PositionsView` embeds `PositionsChart` which historically wants to fill available vertical space. Inside an unbounded vertical List row, the chart may collapse to its minimum intrinsic height. Mitigation: keep the existing `.padding(.vertical, 8)` on the chart and verify via preview that the chart renders at a reasonable height with the Grid-based table below it. If the chart collapses, add a `.frame(minHeight: 220)` on the chart specifically — a localized minimum on the chart sub-view, not on the whole `PositionsView`.

4. **Re-introduction of the spiral.** If the chart or another sub-view shows brittle behaviour during implementation, the temptation will be to add a `minHeight:` or a `.frame(height:)` magic number. Process mitigation: any new hardcoded layout constant must be justified in the commit message with a screenshot / preview comparing the without-magic-number rendering to the with-magic-number rendering.

5. **Empty `Section` accessibility-identifier semantics.** The `transactionlist.header` identifier now resolves on every detail leaf (since the Section is always emitted, even when the accessory is `EmptyView`). The existing UI test `ScrollingDetailHeaderTests` asserts presence on the brokerage account, which continues to pass — but future tests must not interpret identifier resolution as "the accessory has content." If a future test needs that semantics, the accessory body should add its own child identifier.

6. **Dynamic Type clipping above `.xLarge`.** Six columns at fixed inter-column spacing will overflow available width at macOS Accessibility text sizes. Mitigation: `.dynamicTypeSize(.medium ... .xLarge)` on the wide layout per §1; users with larger system text fall back to `narrowLayout` (`PositionRow`-based, single-column). Validated via preview at `.xLarge` boundary before merge.

7. **Deferred macOS keyboard / VoiceOver-table affordances.** Two affordances do not survive the Grid replacement out of the box:
   - Up/Down arrow row focus inside the positions panel.
   - The native "Table" VoiceOver trait announcement.
   
   The implementation plan will file a tracked GitHub issue and reference it via `TODO(#N):` per CLAUDE.md §Bug Tracking.
   
   **Selection drives a user-visible chart interaction, not just informational state.** `PositionsView.swift` passes the row selection to `PositionsChart` as `selectedInstrument:`; when an instrument is selected, the chart switches from the aggregate-portfolio curve to that instrument's individual series (per the chart's `// Selection: a single tap on a row filters the chart to that instrument` doc comment). With keyboard navigation inside the Grid deferred, **sighted keyboard users cannot filter the chart to a specific instrument from the keyboard** — only via pointer or VoiceOver actions. This is a real (not theoretical) accessibility regression versus native `Table`, which would provide keyboard row navigation for free.
   
   Deferral acceptance criteria: the tracked issue must be filed before this PR merges; the implementation plan must commit to closing it before any subsequent feature gates new behaviour on positions-row selection. If a follow-up requirement makes row selection load-bearing for a primary user flow (e.g., row-driven editing, multi-select aggregation), the unresolved deferral elevates to a blocker for that work.

## Testing

- **Preview parity:** the existing `PositionsTable` previews (`mixed wide`, `conversion failure`) and `PositionsView` previews (`Default`, `All fiat`, `Conversion failure`, `Empty`, `With chart`, `With performance tiles`) all continue to render. Visual acceptance: header titles fully visible, every position row renders, gain column shows the full signed-and-percent value without truncation, no internal scroll bar, table grows or shrinks with row count.
- **New unit tests** for the sort state machine (`SortState.toggleSort_inactiveColumn_activatesDescending`, `…activeColumn_flipsDirection`, `…activeColumn_neverReachesNoSort`) — pure value-type tests, no UI dependency.
- **Existing `ScrollingDetailHeaderTests.swift`** continues to assert that the `transactionlist.header` identifier resolves on the brokerage account — unchanged.
- **No new UI tests required.** The header's presence inside the scroll surface is already covered.
- **Manual smoke:** `just run-mac`; click each affected detail leaf; scroll; observe that the top region scrolls off and that the positions table fits exactly the number of rows with no internal scrolling and no clipped column headers. Specific checks before merge:
  - Tab into the positions panel: header sort buttons receive focus rings in Tab order; Space activates the sort toggle (regression check against FOCUS_GUIDE.md §1.1's focusable-controls table — confirms `.buttonStyle(.borderless)` chose correctly over `.plain`).
  - Defocus the window (Cmd-Tab away, then back): selected position row's background changes from accent-coloured (`selectedContentBackgroundColor`) to the unfocused grey (`unemphasizedSelectedContentBackgroundColor`), then back. This validates the `@Environment(\.controlActiveState)` wiring.
  - System Settings > Accessibility > Display > Increase Contrast on: alternating-row tinting disappears (expected behaviour from `NSColor.alternatingContentBackgroundColors`); selection remains visible.
  - System Settings > Accessibility > Display > Reduce Motion on: tapping a sort header reorders rows instantly with no row-position animation. Implementation gates any reorder animation on `@Environment(\.accessibilityReduceMotion)`.
  - VoiceOver on: navigating into the panel announces `"Positions, N instruments"`; each row reads as a single sentence including instrument name, **exchange (when present)**, kind, all five numeric columns, and gain wording (matching `instrumentLabel(for:)` + `gainAccessibilityLabel(...)` from current production); each header button announces its column name plus current sort state.
  - Dynamic Type slider at `.xLarge`: Grid still fits horizontally; above `.xLarge` (`.accessibility1`+) the layout falls back to `narrowLayout`.

## Workflow

- Work continues on `ui/scrolling-detail-headers` in the existing worktree.
- New commits stack on top of the current 20 (no rebase, no force-push).
- Implementation, tests, format, and a local diff land in the worktree.
- User reviews the diff before any push or PR. Merge queue runs only after explicit approval.

## What this redesign does NOT do

- Does not delete `PositionsTable`'s `narrowLayout`. iOS keeps it.
- Does not touch `PositionsTransactionsSplit`, `EarmarkOverviewWithTabs`, or `RecordedValueInvestmentLayout` (iOS-only composition shells).
- Does not touch the `NavigationStack(.id(selection))` wrap in `ContentView.detail` — that's the toolbar-bridge crash fix from the earlier `2026-05-09-detail-view-structural-fix-design.md` work and stays as-is.
- Does not change `safeAreaInset` usage anywhere else in the app (it remains valid for content that genuinely should be pinned).
