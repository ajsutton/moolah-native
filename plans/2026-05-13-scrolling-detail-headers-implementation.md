# Scrolling Detail-View Headers — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Spec:** `plans/2026-05-13-scrolling-detail-headers-redesign.md` (landing via PR #879). This plan executes that spec verbatim; spec sections (`§1.2`, `§4`, Risk #N) are quoted directly so a fresh implementer needs only the spec + this plan.

**Goal:** Replace the broken `Table`-in-`List`-row positions panel with a `Grid`-based layout that scrolls naturally as the leading row of the embedded `TransactionListView`, and wire all five macOS detail leaves (Standard, Crypto wallet, Investment position-tracked, Investment legacy, Earmark) through a single `topAccessory` slot.

**Architecture:**

1. `Shared/Views/Positions/PositionsTable.swift` gains a macOS-only `macOSGridLayout` rendering path that uses a `Grid` plus a sibling `PositionsTableRow` view driven by a pure `PositionsSortState` value type. The existing `wideLayout` (Table-based) is retained for iOS regular-width iPad — iPad isn't embedded in a List row, so the rendering bug doesn't apply and keeping Table preserves column-resize / reorder affordances. `narrowLayout` is untouched.
2. `TransactionListView` grows a `TopAccessory: View` generic with `@ViewBuilder` closure inits. `TransactionListView+List.swift` **always** emits a leading `Section { topAccessory.listRowInsets(EdgeInsets())… }` (no metatype guard — see spec §2).
3. A new `MultiInstrumentPositionsTopAccessoryHost<Content>` mirrors the existing `MultiInstrumentPositionsSplitModifier` valuation lifecycle but exposes the panel via a `PositionsPanel` enum so call sites switch on three concrete cases — no `AnyView` boxing.
4. Per-leaf wiring on `StandardAccountView`, `CryptoWalletAccountView`, `InvestmentAccountView` (both layouts), and `EarmarkDetailView` collapses to a **single** `TransactionListView` call per macOS branch with a `topAccessory:` builder; the old `if let panel { … } else { … }` forks and the `hasResolvableWalletHeader` precondition are deleted.
5. iOS branches stay on `PositionsTransactionsSplit` / `RecordedValueInvestmentLayout` / `EarmarkOverviewWithTabs` / `MultiInstrumentPositionsSplitModifier`. No iOS rendering changes.
6. **Risk #7 is implemented, not deferred:** Up/Down arrow keyboard row navigation via `@FocusState` + `.onKeyPress`, and the native VoiceOver "Table" trait via `.accessibilityRepresentation { Table(...) }` — Apple's official pattern for pairing a custom visual with a different accessibility tree. The spec's claim that the Table trait is "not reproducible from SwiftUI primitives" did not consider `accessibilityRepresentation`; the representation gives VoiceOver the canonical Table announcement (row/column navigation, sort indication) while the Grid carries the visual rendering.

**Tech Stack:** SwiftUI (Grid, GridRow, gridCellColumns, gridColumnAlignment), `@Environment(\.controlActiveState)`, `@Environment(\.dynamicTypeSize)`, AppKit `NSColor` semantic tokens (`selectedContentBackgroundColor`, `unemphasizedSelectedContentBackgroundColor`, `controlAccentColor`, `alternatingContentBackgroundColors`), Swift Testing framework (`import Testing`, `@Suite`, `@Test`, `#expect`), XCUITest (`import XCTest`).

---

## File Structure

### New files

| Path | Responsibility |
|---|---|
| `Shared/Views/Positions/PositionsSortState.swift` | Pure value type. `PositionsSortColumn`, `PositionsSortDirection`, `PositionsSortState` with `toggleSort(_:)` and `sorted(_ rows: [ValuedPosition]) -> [ValuedPosition]`. No SwiftUI dependency. |
| `Shared/Views/Positions/PositionsTableRow.swift` | Per-row Grid view. Owns `@State var isHovered`. Reads `@Environment(\.controlActiveState)`. Applies row background via static `rowBackground(isSelected:isHovered:isFocused:alternateBg:)` helper. Shows a focus-ring overlay when the panel's keyboard cursor is on this row. Accessibility content (per-cell text) lives on the visual Row; the panel-level `.accessibilityRepresentation { Table }` (added in Task 5) replaces this subtree with a native Table for VoiceOver. |
| `Features/Transactions/Views/MultiInstrumentPositionsTopAccessoryHost.swift` | Top-accessory host. Owns `.task(id:)` (mirrors `MultiInstrumentPositionsSplitModifier`'s lifecycle). Yields a `PositionsPanel` enum (`.panel(input, range)` / `.loading` / `.absent`) to a `@ViewBuilder content: (PositionsPanel) -> Content`. |
| `Features/Investments/Views/InvestmentValuationsPanel.swift` | Extracted from `InvestmentAccountView` so the type stays under SwiftLint's `type_body_length` budget after we add the macOS legacy topAccessory branch. macOS body renders as a `VStack(Divider-separated rows)` so it nests cleanly inside the outer List row; iOS keeps `List`. |
| `MoolahTests/Shared/PositionsSortStateTests.swift` | Swift Testing suite for the sort state machine (inactive-column activation = descending, active-column flips direction, never reaches no-sort, sorted-order matches direction for every column). |
| `MoolahUITests_macOS/Tests/ScrollingDetailHeaderTests.swift` | XCUITest asserting `transactionlist.header` resolves on the brokerage account. |

### Modified files

| Path | Change |
|---|---|
| `Shared/Views/Positions/PositionsTable.swift` | Add macOS-only `macOSGridLayout` rendering path (Grid + `PositionsTableRow` + `PositionsSortState`). Apply `.accessibilityRepresentation { Table(sortedRows, selection:, sortOrder:) { TableColumn × 6 } }` to the Grid so VoiceOver gets the native Table trait + column-navigable announcement (spec Risk #7, implemented not deferred). Add `@FocusState isPanelFocused` + `@State focusedRowIndex` + `.onKeyPress(.upArrow / .downArrow / .space)` for keyboard row navigation. Falls back to `narrowLayout` on macOS when `dynamicTypeSize > .xLarge` (spec Risk #6). The existing `wideLayout` (Table) is retained for iOS regular width; `narrowLayout` is untouched. |
| `Features/Transactions/Views/TransactionListView.swift` | Add `TopAccessory: View` generic with `@ViewBuilder topAccessory:` closure init. Add convenience inits in `extension TransactionListView where TopAccessory == EmptyView` so existing call sites compile unchanged. |
| `Features/Transactions/Views/TransactionListView+List.swift` | Always-emit leading `Section { topAccessory.listRowInsets(EdgeInsets())… }` carrying `UITestIdentifiers.TransactionList.headerContainer`. No `TopAccessory.self != EmptyView.self` metatype check (spec §2). |
| `UITestSupport/UITestIdentifiers.swift` | Add `TransactionList.headerContainer = "transactionlist.header"`. |
| `MoolahUITests_macOS/Helpers/Screens/TransactionListScreen.swift` | Add `expectHeaderVisible()` and `expectContainerVisible()` methods. |
| `Features/Accounts/Views/StandardAccountView.swift` | macOS body uses `MultiInstrumentPositionsTopAccessoryHost { panel in TransactionListView(topAccessory: { … switch panel … }) }`. Single `TransactionListView` call. iOS branch unchanged. |
| `Features/Crypto/CryptoWalletAccountView.swift` | macOS body uses the host with a topAccessory builder yielding `VStack(spacing: 0) { walletHeader; <panel switch> }`. No `hasResolvableWalletHeader` precondition. iOS branch unchanged. |
| `Features/Investments/Views/InvestmentAccountView.swift` | Add `makeAccountTransactionList<TopAccessory>(topAccessory:)` overload. `positionTrackedLayout` macOS branch uses it yielding `PositionsView`. `legacyValuationsLayout` macOS branch uses it yielding `VStack(spacing: 0) { legacySummary; legacyChartAndValuations; Divider() }`. `valuationsList` and `valuationsHeader` / `valuationsBody` are extracted to `InvestmentValuationsPanel`. iOS branches unchanged. |
| `Features/Earmarks/Views/EarmarkDetailView.swift` | macOS body becomes `VStack(spacing: 0) { macOSTabPicker; macOSTabContent }` with a `private enum EarmarkTab` and `@State selectedTab`. `.transactions` case calls `TransactionListView(topAccessory: { overviewPanel })`; `.budget` wraps the panel + budget editor in a `ScrollView`. iOS branch unchanged. |

### Sequencing rationale

Tasks 1–4 deliver pure-value-type infrastructure (sort state + tests, focus-index clamp helper + tests) plus the `topAccessory` mechanism with no behaviour change to any leaf — the existing convenience inits pin `TopAccessory == EmptyView` so all current call sites compile. Task 5 adds the macOS-only `macOSGridLayout` to `PositionsTable` — Grid visual + `.accessibilityRepresentation { Table(...) }` for VoiceOver + `@FocusState`-driven Up/Down keyboard navigation. Tasks 6–9 wire the four macOS leaves through the host one at a time, each independently smoke-testable. Task 10 wires the Earmark leaf and ports the UI test. Task 11 runs format/test/review and queues the PR.

---

## Pre-Task: Workflow setup

Per CLAUDE.md and the user's standing instructions, every implementation task must happen in an isolated worktree off `origin/main`.

- [ ] **Step 0.1: Ensure spec PR is at least queued**

Run: `gh pr view 879 --json state,mergeStateStatus,statusCheckRollup --jq '{state, mergeStateStatus, ci: [.statusCheckRollup[] | {name, status, conclusion}]}'`

Expected: PR #879 is `OPEN` and queued in the merge queue (`mq status` shows it in slot 0). If it has merged by the time this task runs, that's also fine. Either way do **not** restart that work.

- [ ] **Step 0.2: Fetch origin and create a fresh worktree off `origin/main`**

`.worktrees/` is gitignored; never reuse `.worktrees/scrolling-detail-headers/` (that's the rejected branch).

```bash
REPO=/Users/aj/Documents/code/moolah-project/moolah-native
WT=$REPO/.worktrees/scrolling-headers-redesign

git -C "$REPO" fetch origin
git -C "$REPO" worktree add --no-track "$WT" -b ui/scrolling-detail-headers-redesign origin/main
```

`--no-track` is mandatory to prevent the new local branch silently tracking another remote branch (CLAUDE.md "Stacked-PR worktrees: don't accidentally push into the parent PR").

- [ ] **Step 0.3: Regenerate the worktree's `Moolah.xcodeproj`**

Run: `just -d "$WT" --justfile "$WT/justfile" generate`

Expected: `xcodegen` succeeds and prints `Created project at Moolah.xcodeproj`. Confirms the worktree has its own project file so `mcp__xcode__RenderPreview` will read from the worktree once Xcode opens it (CLAUDE.md "Xcode previews and the `mcp__xcode__RenderPreview` tool from a worktree").

- [ ] **Step 0.4: Baseline build to confirm a clean starting point**

Run: `just -d "$WT" --justfile "$WT/justfile" build-mac 2>&1 | tee "$WT/.agent-tmp/baseline-build.txt"`

Expected: build succeeds with no warnings (CLAUDE.md sets `SWIFT_TREAT_WARNINGS_AS_ERRORS: YES`). If it fails, stop and investigate — the worktree should be clean before any task runs.

---

## Task 1: `PositionsSortState` value type + unit tests

Pure value-type infrastructure for the Grid table's sort column / direction state machine (spec §1.3). Has no UI dependency — fully unit-testable with Swift Testing.

**Files:**
- Create: `Shared/Views/Positions/PositionsSortState.swift`
- Create: `MoolahTests/Shared/PositionsSortStateTests.swift`

- [ ] **Step 1.1: Write failing tests in `MoolahTests/Shared/PositionsSortStateTests.swift`**

Project convention is Swift Testing (`import Testing`, `@Suite`, `@Test`, `#expect`). Reference: `MoolahTests/Shared/AccountCashFlowsTests.swift` for the established shape.

```swift
import Foundation
import Testing

@testable import Moolah

@Suite("PositionsSortState")
struct PositionsSortStateTests {

  // MARK: - State machine (spec §1.3)

  @Test("Tapping an inactive column activates it in descending order")
  func inactiveColumnActivatesDescending() {
    var state = PositionsSortState(column: .value, direction: .descending)
    state.toggleSort(.instrument)
    #expect(state.column == .instrument)
    #expect(state.direction == .descending)
  }

  @Test("Tapping the active column flips the direction")
  func activeColumnFlipsDirection() {
    var state = PositionsSortState(column: .value, direction: .descending)
    state.toggleSort(.value)
    #expect(state.column == .value)
    #expect(state.direction == .ascending)
    state.toggleSort(.value)
    #expect(state.direction == .descending)
  }

  @Test("Sort never reaches a no-sort state — there is always an active column")
  func sortNeverResetsToNoSort() {
    var state = PositionsSortState(column: .value, direction: .descending)
    for _ in 0..<10 {
      state.toggleSort(.value)
      #expect(state.column == .value)
    }
  }

  // MARK: - Sorting (spec §1: same column set as production Table today)

  @Test("Sorting by value descending puts the largest value first")
  func sortByValueDescending() {
    let rows = Self.mixedRows()
    var state = PositionsSortState(column: .value, direction: .descending)
    let sorted = state.sorted(rows)
    #expect(sorted.map(\.instrument.id) == ["BHP.AX", "CBA.AX", "ETH-MAINNET", "AUD"])
    _ = state  // suppress unused-var
  }

  @Test("Sorting by instrument ascending orders by name lexicographically")
  func sortByInstrumentAscending() {
    let rows = Self.mixedRows()
    var state = PositionsSortState(column: .instrument, direction: .ascending)
    let sorted = state.sorted(rows)
    #expect(sorted.first?.instrument.name == "AUD")
    #expect(sorted.last?.instrument.name == "Ethereum")
    _ = state
  }

  @Test("Sorting by quantity descending orders by raw quantity")
  func sortByQuantityDescending() {
    let rows = Self.mixedRows()
    var state = PositionsSortState(column: .quantity, direction: .descending)
    let sorted = state.sorted(rows)
    #expect(sorted.first?.quantity == 2_480)  // AUD cash
  }

  @Test("Sorting by gain descending orders by signed gain (refunds preserve sign)")
  func sortByGainDescending() {
    let rows = Self.mixedRows()
    var state = PositionsSortState(column: .gain, direction: .descending)
    let sorted = state.sorted(rows)
    // BHP gain +1_200, CBA +600, ETH +2_300, AUD has no gain.
    // gainLoss-less rows sink to the end regardless of direction.
    let withGains = sorted.prefix(while: { $0.gainLoss != nil }).map(\.instrument.id)
    #expect(withGains == ["ETH-MAINNET", "BHP.AX", "CBA.AX"])
  }

  // MARK: - Fixtures

  /// Mixed-instrument fixture matching `PositionsTable.swift`'s
  /// `mixedPositionsInput()` preview so sort assertions reflect the
  /// production preview shape.
  private static func mixedRows() -> [ValuedPosition] {
    let aud = Instrument.AUD
    let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")
    let cba = Instrument.stock(ticker: "CBA.AX", exchange: "ASX", name: "CBA")
    let eth = Instrument.crypto(
      chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18)
    return [
      ValuedPosition(
        instrument: bhp, quantity: 250,
        unitPrice: InstrumentAmount(quantity: 45.30, instrument: aud),
        costBasis: InstrumentAmount(quantity: 10_125, instrument: aud),
        value: InstrumentAmount(quantity: 11_325, instrument: aud)),
      ValuedPosition(
        instrument: cba, quantity: 80,
        unitPrice: InstrumentAmount(quantity: 120, instrument: aud),
        costBasis: InstrumentAmount(quantity: 9_000, instrument: aud),
        value: InstrumentAmount(quantity: 9_600, instrument: aud)),
      ValuedPosition(
        instrument: eth, quantity: 2.45,
        unitPrice: InstrumentAmount(quantity: 4_000, instrument: aud),
        costBasis: InstrumentAmount(quantity: 7_500, instrument: aud),
        value: InstrumentAmount(quantity: 9_800, instrument: aud)),
      ValuedPosition(
        instrument: aud, quantity: 2_480,
        unitPrice: nil, costBasis: nil,
        value: InstrumentAmount(quantity: 2_480, instrument: aud)),
    ]
  }
}
```

- [ ] **Step 1.2: Add the new test file to `project.yml` and regenerate**

`MoolahTests/Shared/*` is matched by the existing test target glob in `project.yml`. Regenerate to pick the new file up.

Run: `just -d "$WT" --justfile "$WT/justfile" generate`

Expected: `xcodegen` succeeds and prints a unified diff for `Moolah.xcodeproj` mentioning `PositionsSortStateTests.swift`.

- [ ] **Step 1.3: Run the failing tests to confirm the failure mode**

Run: `mkdir -p "$WT/.agent-tmp" && just -d "$WT" --justfile "$WT/justfile" test-mac PositionsSortStateTests 2>&1 | tee "$WT/.agent-tmp/sort-state-fail.txt"`

Expected: build fails with diagnostics on every reference to `PositionsSortState`, `PositionsSortColumn`, `PositionsSortDirection` ("cannot find … in scope"). This is the TDD red — proceed to 1.4.

- [ ] **Step 1.4: Create `Shared/Views/Positions/PositionsSortState.swift`**

```swift
import Foundation

/// Sort columns surfaced by the macOS positions Grid (spec §1).
/// Matches the existing production `Table` column set so the wide
/// layout's sort semantics survive the Grid rewrite.
enum PositionsSortColumn: String, Hashable, CaseIterable {
  case instrument
  case quantity
  case unitPrice
  case costBasis
  case value
  case gain
}

enum PositionsSortDirection: Hashable {
  case ascending
  case descending
}

/// Pure value type carrying the active sort column + direction for the
/// positions Grid. Per spec §1.3: tapping an inactive column activates
/// it descending; tapping the active column flips direction; sort
/// never resets to "no sort." Lives outside any view so the cycle is
/// unit-testable without SwiftUI rendering.
struct PositionsSortState: Hashable {
  private(set) var column: PositionsSortColumn
  private(set) var direction: PositionsSortDirection

  init(column: PositionsSortColumn = .value, direction: PositionsSortDirection = .descending) {
    self.column = column
    self.direction = direction
  }

  /// Per spec §1.3:
  /// - Tap inactive column → activate it, `direction = .descending`
  ///   ("largest first" — the existing production default with
  ///   `\.valueQuantity, order: .reverse`).
  /// - Tap active column → flip direction.
  /// - Sort never resets to "no sort" — there is always an active column.
  ///
  /// Deliberate macOS HIG deviation: convention is ascending-on-first-
  /// activation (Finder/Mail). We use descending-on-first-activation
  /// because "largest first" is the more useful default for monetary
  /// columns. Do not "correct" this — see spec §1.3.
  mutating func toggleSort(_ tapped: PositionsSortColumn) {
    if tapped == column {
      direction = (direction == .ascending) ? .descending : .ascending
    } else {
      column = tapped
      direction = .descending
    }
  }

  /// Sort `rows` by the active column/direction. `nil` values for the
  /// chosen column sink to the end regardless of direction (per spec §1:
  /// "the gain column shows the full signed-and-percent value without
  /// truncation" — missing-gain rows are a UX edge, not a sort key).
  func sorted(_ rows: [ValuedPosition]) -> [ValuedPosition] {
    let ascending = direction == .ascending
    return rows.sorted { left, right in
      let leftKey = key(for: left)
      let rightKey = key(for: right)
      switch (leftKey, rightKey) {
      case (.some(let lhs), .some(let rhs)):
        return ascending ? lhs < rhs : lhs > rhs
      case (.some, .none):
        return true  // values before nils, regardless of direction
      case (.none, .some):
        return false
      case (.none, .none):
        // Tiebreak by instrument id so the relative order is stable
        // across re-renders. Same fallback applies whenever the chosen
        // column's values are equal.
        return left.instrument.id < right.instrument.id
      }
    }
  }

  private func key(for row: ValuedPosition) -> SortKey? {
    switch column {
    case .instrument:
      return .string(row.instrument.name)
    case .quantity:
      return .decimal(row.quantity)
    case .unitPrice:
      return row.unitPrice.map { .decimal($0.quantity) }
    case .costBasis:
      return row.costBasis.map { .decimal($0.quantity) }
    case .value:
      return row.value.map { .decimal($0.quantity) }
    case .gain:
      return row.gainLoss.map { .decimal($0.quantity) }
    }
  }

  /// Comparable wrapper so the keys for the six columns share one
  /// generic sort path. Decimal and String are both `Comparable`; the
  /// wrapper unifies them under one comparable type.
  private enum SortKey: Comparable {
    case decimal(Decimal)
    case string(String)

    static func < (lhs: SortKey, rhs: SortKey) -> Bool {
      switch (lhs, rhs) {
      case (.decimal(let lv), .decimal(let rv)):
        return lv < rv
      case (.string(let lv), .string(let rv)):
        return lv.localizedStandardCompare(rv) == .orderedAscending
      // Mixed cases are never produced by `key(for:)` for a given column.
      // Trapping makes the assumption explicit; the function is internal
      // so call sites are auditable.
      case (.decimal, .string), (.string, .decimal):
        preconditionFailure("PositionsSortState.SortKey: heterogeneous comparison")
      }
    }
  }
}
```

- [ ] **Step 1.5: Add the new source file to `project.yml`'s app glob (no edit needed if Shared/ glob covers it) and regenerate**

`Shared/Views/Positions/*.swift` is matched by the existing Moolah target glob. Regenerate to pick the new file up.

Run: `just -d "$WT" --justfile "$WT/justfile" generate`

Expected: `xcodegen` succeeds.

- [ ] **Step 1.6: Run the sort-state tests; expect green**

Run: `just -d "$WT" --justfile "$WT/justfile" test-mac PositionsSortStateTests 2>&1 | tee "$WT/.agent-tmp/sort-state-pass.txt"`

Expected: all tests in `PositionsSortStateTests` pass. If any fail, fix and re-run before proceeding.

- [ ] **Step 1.7: Format, format-check, commit**

```bash
just -d "$WT" --justfile "$WT/justfile" format
just -d "$WT" --justfile "$WT/justfile" format-check
git -C "$WT" add Shared/Views/Positions/PositionsSortState.swift \
  MoolahTests/Shared/PositionsSortStateTests.swift project.yml Moolah.xcodeproj/project.pbxproj 2>/dev/null || \
  git -C "$WT" add Shared/Views/Positions/PositionsSortState.swift \
    MoolahTests/Shared/PositionsSortStateTests.swift project.yml
git -C "$WT" commit -m "$(cat <<'EOF'
feat(positions): add PositionsSortState value type + sort-cycle tests

Pure value type carrying the macOS positions Grid's active sort column
and direction. Spec §1.3 cycle: inactive column → activate descending;
active column → flip direction; never reaches no-sort. Sorts by the six
production columns (instrument / quantity / unitPrice / costBasis /
value / gain), with `nil` keys sinking to the end and an instrument-id
tiebreak for stable ordering. No SwiftUI dependency — fully testable
under Swift Testing.

Refs plans/2026-05-13-scrolling-detail-headers-redesign.md §1.3.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

Expected: `just format-check` exits 0; `git commit` succeeds; `git -C "$WT" status` is clean.

---

## Task 2: `PositionsTableRow` per-row view

Per-row Grid view owning hover state, the §1.2 row-background helper, and a focus-ring overlay for keyboard navigation. Pulled out from `PositionsTable` so the diff stays focused and so a future change to row chrome doesn't have to touch the table.

**Files:**
- Create: `Shared/Views/Positions/PositionsTableRow.swift`

- [ ] **Step 2.1: Create `Shared/Views/Positions/PositionsTableRow.swift`**

Implements spec §1.2 (semantic-token row backgrounds). The window-key vs unemphasised distinction is driven by `@Environment(\.controlActiveState)` — spec §1.2 calls out that `@FocusState` is **not** the right tool for this and that `controlActiveState` is the public API.

The row carries **no** `.accessibilityElement(...)` / `.accessibilityLabel(...)` configuration. The parent `PositionsTable.macOSGridLayout` (Task 5) wraps the whole Grid in `.accessibilityRepresentation { Table(...) }`, which replaces the Grid's accessibility tree with a native `Table` view that has the proper VoiceOver "Table" trait. Any per-row accessibility config here would be overridden by the representation — so we omit it and let the Table representation own the accessibility shape.

The row does still expose a `let isFocused: Bool` parameter. When `true` the row draws a system focus-ring overlay, used by the parent's `@FocusState`-driven keyboard cursor (Task 5).

```swift
import SwiftUI

#if os(macOS)

  /// One Grid row inside `PositionsTable.macOSGridLayout`. Owns its
  /// own hover state so SwiftUI's diffing keeps hover-only re-renders
  /// scoped to a single row. Reads `@Environment(\.controlActiveState)`
  /// so the selection background swaps between
  /// `selectedContentBackgroundColor` and
  /// `unemphasizedSelectedContentBackgroundColor` when the window loses
  /// key state (spec §1.2 — native `NSTableView` swaps these automatically
  /// but SwiftUI's `Color(nsColor:)` is static, so the swap is driven
  /// here).
  ///
  /// Accessibility shape: this view carries **no** per-cell or per-row
  /// accessibility config — the parent's
  /// `.accessibilityRepresentation { Table(...) }` (Task 5) replaces
  /// the Grid's entire accessibility tree with a native `Table`, which
  /// advertises the "Table" trait, column headers, and row navigation
  /// to VoiceOver out of the box.
  struct PositionsTableRow: View {
    let row: ValuedPosition
    let isSelected: Bool
    let isFocused: Bool
    let alternateBg: Bool
    let toggleSelection: () -> Void

    @State private var isHovered = false
    @Environment(\.controlActiveState) private var controlActiveState

    var body: some View {
      GridRow(alignment: .firstTextBaseline) {
        instrumentCell
        Text(row.quantityFormatted)
          .monospacedDigit()
          .gridColumnAlignment(.trailing)
        amountCell(row.unitPrice)
          .gridColumnAlignment(.trailing)
        amountCell(row.costBasis)
          .gridColumnAlignment(.trailing)
        amountCell(row.value)
          .gridColumnAlignment(.trailing)
        gainCell
          .gridColumnAlignment(.trailing)
      }
      .padding(.vertical, 6)
      .padding(.horizontal, 8)
      .background(
        Self.rowBackground(
          isSelected: isSelected,
          isHovered: isHovered,
          isFocused: controlActiveState == .key,
          alternateBg: alternateBg))
      .overlay(focusRing)
      .contentShape(Rectangle())
      .onTapGesture { toggleSelection() }
      .onHover { isHovered = $0 }
    }

    /// Keyboard-focus ring drawn on top of the row when this row is the
    /// `focusedRowIndex` in the parent panel. Mirrors the macOS
    /// system focus appearance: 2pt accent-coloured rounded rect.
    /// Conditionally rendered so unfocused rows don't pay the modifier
    /// cost.
    @ViewBuilder private var focusRing: some View {
      if isFocused {
        RoundedRectangle(cornerRadius: 4)
          .stroke(Color.accentColor, lineWidth: 2)
          .accessibilityHidden(true)
      }
    }

    // MARK: - Cells

    @ViewBuilder private var instrumentCell: some View {
      HStack(spacing: 6) {
        KindBadge(kind: row.instrument.kind)
        VStack(alignment: .leading) {
          Text(row.instrument.name)
          if let exchange = row.instrument.exchange {
            Text(exchange).font(.caption).foregroundStyle(.secondary)
          }
        }
      }
    }

    @ViewBuilder private func amountCell(_ amount: InstrumentAmount?) -> some View {
      if let amount {
        Text(amount.formatted).monospacedDigit()
      } else {
        Text("—").foregroundStyle(.tertiary)
      }
    }

    @ViewBuilder private var gainCell: some View {
      if let gain = row.gainLoss {
        HStack(spacing: 4) {
          Text(gain.signedFormatted)
            .monospacedDigit()
            .foregroundStyle(Self.gainColor(gain))
          if let pct = row.gainLossPercent {
            Text(GainLossPercentDisplay.formatted(pct))
              .font(.caption)
              .monospacedDigit()
              .foregroundStyle(Self.gainColor(gain))
          }
        }
      } else {
        Text("—").foregroundStyle(.tertiary)
      }
    }

    // MARK: - Background (spec §1.2)

    /// Resolves the row background from AppKit semantic tokens —
    /// `selectedContentBackgroundColor` (key window), the
    /// `unemphasizedSelected…` variant (window not key),
    /// `controlAccentColor.opacity(0.10)` (hover —
    /// the one place opacity is permitted per spec §1.2 because AppKit
    /// has no single "row hover" semantic colour and 10% is the
    /// published `NSTableRowView` convention), and
    /// `alternatingContentBackgroundColors[0|1]` (zebra striping —
    /// system-resolved so Increase Contrast disables striping for free).
    static func rowBackground(
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
        return Color(nsColor: .controlAccentColor).opacity(0.10)
      }
      return Color(nsColor: NSColor.alternatingContentBackgroundColors[alternateBg ? 1 : 0])
    }

    private static func gainColor(_ gain: InstrumentAmount) -> Color {
      if gain.isNegative { return .red }
      if gain.isZero { return .primary }
      return .green
    }
  }

#endif
```

- [ ] **Step 2.2: Regenerate the project (Shared glob picks up the file)**

Run: `just -d "$WT" --justfile "$WT/justfile" generate`

Expected: `xcodegen` succeeds.

- [ ] **Step 2.3: Build the macOS target to confirm the row compiles in isolation**

Run: `just -d "$WT" --justfile "$WT/justfile" build-mac 2>&1 | tee "$WT/.agent-tmp/row-build.txt"`

Expected: build succeeds with no warnings. The row isn't referenced by `PositionsTable` yet (that's Task 5) but it must compile standalone. If `KindBadge`, `GainLossPercentDisplay`, `InstrumentAmount.signedFormatted`, etc. don't resolve, search for the actual symbol — these are the ones the production `PositionsTable.gainCell` already uses, so they exist in production today.

- [ ] **Step 2.4: Format, format-check, commit**

```bash
just -d "$WT" --justfile "$WT/justfile" format
just -d "$WT" --justfile "$WT/justfile" format-check
git -C "$WT" add Shared/Views/Positions/PositionsTableRow.swift project.yml
git -C "$WT" commit -m "$(cat <<'EOF'
feat(positions): add PositionsTableRow with semantic-token chrome

Per-row Grid view for the macOS positions Grid (spec §1.2). Owns
`@State isHovered` so SwiftUI diffing scopes hover re-renders to one
row at a time. Reads `@Environment(\.controlActiveState)` so the
selection background swaps between `selectedContentBackgroundColor`
and `unemphasizedSelectedContentBackgroundColor` when the window
loses key state (native `NSTableView` swaps these automatically but
SwiftUI's `Color(nsColor:)` is static).

Row background uses AppKit semantic tokens exclusively per spec §1.2:
- `selectedContentBackgroundColor` / `unemphasizedSelected…` for
  selection
- `controlAccentColor.opacity(0.10)` for hover (the one place a
  literal opacity is permitted — AppKit has no single hover token
  and 10% is the published `NSTableRowView` convention)
- `alternatingContentBackgroundColors[…]` for zebra striping
  (system-resolved so Increase Contrast disables striping for free)

The row also draws a system-style focus ring (accent-coloured 2pt
RoundedRectangle stroke) when its `isFocused` flag is true, used by
the parent panel's `@FocusState`-driven keyboard cursor (Task 5).

No per-row accessibility config — the parent's
`.accessibilityRepresentation { Table(...) }` (Task 5) replaces the
Grid's accessibility tree with a native `Table` view, giving
VoiceOver the canonical "Table" trait + column-navigable
announcement out of the box.

The view is gated `#if os(macOS)` so iOS keeps `PositionRow`.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

Expected: format check passes; commit succeeds.

---

## Task 3: `TopAccessory` slot on `TransactionListView`

Add the generic + `@ViewBuilder` closure init + convenience `EmptyView` inits so existing call sites compile unchanged. No leaf wiring yet — this task just adds the surface.

**Files:**
- Modify: `Features/Transactions/Views/TransactionListView.swift`
- Modify: `Features/Transactions/Views/TransactionListView+List.swift`
- Modify: `UITestSupport/UITestIdentifiers.swift`

- [ ] **Step 3.1: Add `TopAccessory: View` generic to `TransactionListView.swift`**

Replace the struct declaration `struct TransactionListView: View {` with `struct TransactionListView<TopAccessory: View>: View {`. Add a `let topAccessory: TopAccessory` stored property right after `@Environment(ImportStore.self) private var importStore`:

```swift
  /// Optional content rendered as the sole row of a leading `Section`
  /// of the embedded `List`. Defaults to `EmptyView` via the
  /// convenience inits below — the leading `Section` is emitted
  /// unconditionally and an `EmptyView` row contributes zero visible
  /// pixels (spec §2). When non-empty, the row carries
  /// `UITestIdentifiers.TransactionList.headerContainer` and is
  /// `.selectionDisabled()` so it stays out of the selection model
  /// and arrow-key navigation.
  let topAccessory: TopAccessory
```

Update **both** designated inits (the one with `_externalSelection = nil` and the one taking a `selectedTransaction: Binding<Transaction?>`) to accept and assign a `@ViewBuilder topAccessory: () -> TopAccessory` closure. Use the exact signature from the rejected branch's `TransactionListView.swift` lines 78–125:

```swift
  init(
    title: String,
    filter: TransactionFilter,
    accounts: Accounts,
    categories: Categories,
    earmarks: Earmarks,
    transactionStore: TransactionStore,
    grouping: Grouping = .flat,
    @ViewBuilder topAccessory: () -> TopAccessory
  ) {
    self.title = title
    self.baseFilter = filter
    self.accounts = accounts
    self.categories = categories
    self.earmarks = earmarks
    self.transactionStore = transactionStore
    self.grouping = grouping
    self._externalSelection = nil
    self._activeFilter = State(initialValue: filter)
    self.topAccessory = topAccessory()
  }

  init(
    title: String,
    filter: TransactionFilter,
    accounts: Accounts,
    categories: Categories,
    earmarks: Earmarks,
    transactionStore: TransactionStore,
    grouping: Grouping = .flat,
    selectedTransaction: Binding<Transaction?>,
    @ViewBuilder topAccessory: () -> TopAccessory
  ) {
    self.title = title
    self.baseFilter = filter
    self.accounts = accounts
    self.categories = categories
    self.earmarks = earmarks
    self.transactionStore = transactionStore
    self.grouping = grouping
    self._externalSelection = selectedTransaction
    self._activeFilter = State(initialValue: filter)
    self.topAccessory = topAccessory()
  }
```

At the bottom of `TransactionListView.swift` (after the `struct` closing brace, outside it), add the convenience inits in an extension constrained to `TopAccessory == EmptyView`:

```swift
// Convenience initialisers for the common case where no top accessory
// is provided. Swift 6 rejects the simpler form
// `@ViewBuilder topAccessory: () -> TopAccessory = { EmptyView() }`
// at the designated init declaration with:
//
//   error: cannot use default expression for inference of
//   '() -> TopAccessory' because it is inferrable from parameters
//   #6, #7; this will be an error in a future Swift language mode
//
// The diagnostic fires on the init declaration itself (not any call
// site), and the wording is documented Swift behaviour: a default
// expression cannot be the sole source of inference for a generic
// parameter when other parameters in the signature could in principle
// transitively constrain it. The convenience inits below pin
// `TopAccessory == EmptyView` so existing call sites that omit
// `topAccessory:` resolve to these overloads — same surface shape as
// the pre-generic API, no source changes needed.
extension TransactionListView where TopAccessory == EmptyView {
  init(
    title: String,
    filter: TransactionFilter,
    accounts: Accounts,
    categories: Categories,
    earmarks: Earmarks,
    transactionStore: TransactionStore,
    grouping: Grouping = .flat
  ) {
    self.init(
      title: title,
      filter: filter,
      accounts: accounts,
      categories: categories,
      earmarks: earmarks,
      transactionStore: transactionStore,
      grouping: grouping,
      topAccessory: { EmptyView() })
  }

  init(
    title: String,
    filter: TransactionFilter,
    accounts: Accounts,
    categories: Categories,
    earmarks: Earmarks,
    transactionStore: TransactionStore,
    grouping: Grouping = .flat,
    selectedTransaction: Binding<Transaction?>
  ) {
    self.init(
      title: title,
      filter: filter,
      accounts: accounts,
      categories: categories,
      earmarks: earmarks,
      transactionStore: transactionStore,
      grouping: grouping,
      selectedTransaction: selectedTransaction,
      topAccessory: { EmptyView() })
  }
}
```

- [ ] **Step 3.2: Add the headerContainer identifier in `UITestSupport/UITestIdentifiers.swift`**

Inside the `TransactionList` namespace (between `container` and `transaction(_:)`):

```swift
    /// Container of the scrolling header (top accessory) on detail-view
    /// transaction lists. The leading `Section { topAccessory … }` row
    /// in `TransactionListView+List.swift` carries this identifier
    /// unconditionally — even when the accessory is `EmptyView`, since
    /// the row contributes zero visible pixels but the identifier still
    /// resolves. UI tests should treat resolution as "the scroll
    /// surface is wired," NOT as "the accessory has content."
    public static let headerContainer = "transactionlist.header"
```

- [ ] **Step 3.3: Always-emit the leading Section in `TransactionListView+List.swift`**

Replace the `List(selection: selectedTransactionBinding) { listContent }` body of the `transactionsList` computed var with:

```swift
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

Critical: **no** `if TopAccessory.self != EmptyView.self { … }` gate. Per spec §2: always emit the Section; an `EmptyView` row with the four row modifiers above contributes zero visible pixels (validated empirically in the spec's findings table).

- [ ] **Step 3.4: Regenerate, build, verify warning-free**

```bash
just -d "$WT" --justfile "$WT/justfile" generate
just -d "$WT" --justfile "$WT/justfile" build-mac 2>&1 | tee "$WT/.agent-tmp/topaccessory-build.txt"
just -d "$WT" --justfile "$WT/justfile" build-ios 2>&1 | tee "$WT/.agent-tmp/topaccessory-build-ios.txt"
```

Expected: both builds succeed warning-free. All existing `TransactionListView(…)` call sites compile via the `where TopAccessory == EmptyView` convenience inits — no leaf source changes yet.

- [ ] **Step 3.5: Run the full unit test suite to confirm no regressions**

Run: `just -d "$WT" --justfile "$WT/justfile" test-mac 2>&1 | tee "$WT/.agent-tmp/topaccessory-test.txt" ; grep -i 'failed\|error:' "$WT/.agent-tmp/topaccessory-test.txt" || echo 'no failures'`

Expected: all macOS tests pass. iOS tests will run later via `just test` once the full surface stabilises.

- [ ] **Step 3.6: Format, format-check, commit**

```bash
just -d "$WT" --justfile "$WT/justfile" format
just -d "$WT" --justfile "$WT/justfile" format-check
git -C "$WT" add \
  Features/Transactions/Views/TransactionListView.swift \
  Features/Transactions/Views/TransactionListView+List.swift \
  UITestSupport/UITestIdentifiers.swift
git -C "$WT" commit -m "$(cat <<'EOF'
feat(transactions): add topAccessory slot to TransactionListView

`TransactionListView` becomes generic on a `TopAccessory: View` slot
with `@ViewBuilder topAccessory:` closure inits; convenience inits
pinned to `TopAccessory == EmptyView` keep every existing call site
compiling unchanged. The leading `Section { topAccessory … }` is
emitted unconditionally — `EmptyView` plus the four row modifiers
(`listRowInsets(EdgeInsets())`, `listRowSeparator(.hidden)`,
`listRowBackground(Color.clear)`, `selectionDisabled()`) contributes
zero visible pixels, per the spec's empirical validation. The row
carries `UITestIdentifiers.TransactionList.headerContainer` so UI
tests can wait on the scroll surface (not accessory presence).

Refs plans/2026-05-13-scrolling-detail-headers-redesign.md §2.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

Expected: format check passes; tests still pass; commit succeeds.

---

## Task 4: `MultiInstrumentPositionsTopAccessoryHost`

The macOS top-accessory host. Owns the same valuation `.task(id:)` as `MultiInstrumentPositionsSplitModifier` but yields a typed enum to its content closure so call sites switch concretely instead of branching on `AnyView?`.

**Files:**
- Create: `Features/Transactions/Views/MultiInstrumentPositionsTopAccessoryHost.swift`

- [ ] **Step 4.1: Create the host file**

```swift
import SwiftUI

/// macOS top-accessory host. Owns the same positions-valuator lifecycle
/// as `MultiInstrumentPositionsSplitModifier` (`@State positionsInput`,
/// `@State positionsRange`, `.task(id:)` keyed on positions + the
/// crypto-registry version), but yields a typed `PositionsPanel` enum
/// to its `content` builder so call sites switch on three concrete
/// cases (`.panel` / `.loading` / `.absent`) instead of branching on
/// `AnyView?`.
///
/// The visibility predicate is `MultiInstrumentPositionsSplitModifier.shouldShow(…)`
/// (shared with the iOS modifier) so host and modifier agree on when
/// to render a panel.
struct MultiInstrumentPositionsTopAccessoryHost<Content: View>: View {
  let positions: [Position]
  let hostCurrency: Instrument
  let title: String
  let conversionService: (any InstrumentConversionService)?
  let registrationsVersion: Int
  @ViewBuilder let content: (PositionsPanel) -> Content

  @State private var positionsInput: PositionsViewInput?
  @State private var positionsRange: PositionsTimeRange = .threeMonths

  /// What the host has resolved for the current positions + valuator
  /// state. Call sites switch on this so the topAccessory builder is
  /// type-driven, not `AnyView`-driven.
  enum PositionsPanel {
    /// The valuator has produced an input — render `PositionsView`.
    case panel(PositionsViewInput, Binding<PositionsTimeRange>)
    /// The valuator hasn't produced an input yet but should — render a
    /// `ProgressView`. Distinct from `.absent` so call sites can
    /// render a placeholder during the first valuation.
    case loading
    /// No panel is appropriate for this account (single-host-currency
    /// account; or post-valuation `shouldHide` is true). Call sites
    /// return `EmptyView` to collapse the slot.
    case absent
  }

  private var panel: PositionsPanel {
    let shouldShow = MultiInstrumentPositionsSplitModifier.shouldShow(
      rawPositions: positions,
      hostCurrency: hostCurrency,
      positionsInput: positionsInput)
    guard shouldShow else { return .absent }
    if let positionsInput {
      return .panel(positionsInput, $positionsRange)
    }
    return .loading
  }

  var body: some View {
    content(panel)
      .task(
        id: PositionsTopAccessoryTaskKey(
          positions: positions,
          registrationsVersion: registrationsVersion)
      ) {
        await valuatePositions()
      }
  }

  private func valuatePositions() async {
    guard let conversionService, !positions.isEmpty else {
      positionsInput = nil
      return
    }
    let valuator = PositionsValuator(conversionService: conversionService)
    let rows = await valuator.valuate(
      positions: positions,
      hostCurrency: hostCurrency,
      costBasis: [:],
      on: Date()
    )
    guard !Task.isCancelled else { return }
    positionsInput = PositionsViewInput(
      title: title,
      hostCurrency: hostCurrency,
      positions: rows,
      historicalValue: nil
    )
  }
}

/// Composite id for `MultiInstrumentPositionsTopAccessoryHost`'s
/// valuation `.task(id:)`. Re-fires when the positions list changes
/// OR when the crypto-registry version bumps (issue #790: a `.spam`
/// flip in preferences must re-run the per-row valuator). Distinct
/// type from `MultiInstrumentPositionsSplitModifier`'s key so the two
/// hosts' `.task(id:)` invalidations don't cross-fire when both are
/// instantiated under the same parent.
private struct PositionsTopAccessoryTaskKey: Hashable {
  let positions: [Position]
  let registrationsVersion: Int
}
```

- [ ] **Step 4.2: Build to confirm the host compiles**

Run: `just -d "$WT" --justfile "$WT/justfile" generate ; just -d "$WT" --justfile "$WT/justfile" build-mac 2>&1 | tee "$WT/.agent-tmp/host-build.txt"`

Expected: build succeeds warning-free. If `PositionsValuator`, `MultiInstrumentPositionsSplitModifier.shouldShow`, etc. don't resolve, search the codebase — they exist on main (we read them earlier).

- [ ] **Step 4.3: Format, format-check, commit**

```bash
just -d "$WT" --justfile "$WT/justfile" format
just -d "$WT" --justfile "$WT/justfile" format-check
git -C "$WT" add Features/Transactions/Views/MultiInstrumentPositionsTopAccessoryHost.swift project.yml
git -C "$WT" commit -m "$(cat <<'EOF'
feat(transactions): add MultiInstrumentPositionsTopAccessoryHost

macOS top-accessory host with the same valuation lifecycle as
`MultiInstrumentPositionsSplitModifier`. Yields a typed `PositionsPanel`
enum (`.panel(input, range)` / `.loading` / `.absent`) to its content
builder so per-leaf call sites switch concretely instead of branching
on `AnyView?`. Visibility predicate is shared with the iOS modifier
via `MultiInstrumentPositionsSplitModifier.shouldShow(…)`.

Refs plans/2026-05-13-scrolling-detail-headers-redesign.md §3.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

Expected: format check passes; commit succeeds.

---

## Task 5: macOS Grid layout for `PositionsTable`

The rejected-implementation rewrite point: macOS gets a new `macOSGridLayout` (Grid) and routes through it. iOS keeps the existing Table-based `wideLayout` (it isn't embedded in a List row). `narrowLayout` is untouched.

**Files:**
- Modify: `Shared/Views/Positions/PositionsTable.swift`

Spec §1 says the `Table` shape is "removed **on macOS**" — iOS regular width keeps its existing `Table`-based `wideLayout` (it's not embedded in a List row on iPad, so the rendering bug doesn't apply). The change is **additive on macOS**: a new `macOSGridLayout` runs instead of `wideLayout` on macOS, while the existing `wideLayout` (Table) is retained for iOS regular width.

- [ ] **Step 5.1: Add Grid-state and environment readers; branch the body**

At the top of `PositionsTable`, alongside the existing `@State private var sortOrder: [KeyPathComparator<ValuedPosition>] = …`:

```swift
  /// macOS-only Grid sort state (spec §1.3). Lives alongside `sortOrder`
  /// (the iOS Table's `KeyPathComparator` array) — the two states never
  /// both drive layout because the `#if os(macOS)` branch in `body`
  /// chooses one or the other.
  #if os(macOS)
    @State private var sort = PositionsSortState(column: .value, direction: .descending)
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// Tracks whether the macOS Grid panel currently owns keyboard
    /// focus. Driven by `.focusable()` + `.focused($isPanelFocused)`.
    /// On focus-gain we seed `focusedRowIndex` to 0; on focus-loss we
    /// clear it so the focus ring disappears when the user Tabs out.
    @FocusState private var isPanelFocused: Bool

    /// Which row inside the panel the keyboard cursor is on. `nil`
    /// means no row is focused (panel doesn't own focus yet, or the
    /// row list is empty). Driven by Up/Down arrow key presses.
    @State private var focusedRowIndex: Int? = nil
  #endif
```

Replace the `body` Group with the per-platform branch — macOS routes to the new Grid layout (with the Dynamic-Type fallback per spec Risk #6); iOS routes to the unchanged Table-based `wideLayout` for regular width:

```swift
  var body: some View {
    Group {
      #if os(macOS)
        if dynamicTypeSize > .xLarge {
          narrowLayout
        } else {
          macOSGridLayout
        }
      #else
        if sizeClass == .regular {
          wideLayout
        } else {
          narrowLayout
        }
      #endif
    }
  }
```

- [ ] **Step 5.2: Add `macOSGridLayout` and the Grid-specific helpers**

Add a new `// MARK: - macOS Grid (spec §1)` section ABOVE the existing `// MARK: - Wide` section. Everything inside is `#if os(macOS)` guarded so iOS builds don't see Grid-specific Mac-only types. `wideLayout`, `instrumentCell`, `amountCell`, `gainCell`, `gainAccessibilityLabel`, and `rowSelectionBinding` (the iOS Table path) stay untouched.

```swift
  // MARK: - macOS Grid (spec §1)

  #if os(macOS)
    @ViewBuilder private var macOSGridLayout: some View {
      let sortedRows = sort.sorted(groups.flatMap(\.rows))
      Grid(
        alignment: .leadingFirstTextBaseline,
        horizontalSpacing: 16,
        verticalSpacing: 0
      ) {
        headerRow
        Divider().gridCellColumns(6)
        ForEach(Array(sortedRows.enumerated()), id: \.element.id) { item in
          // Closure parameter tuple destructuring (`{ idx, row in }`)
          // was removed in Swift 4 (SE-0110); destructure inside the
          // body.
          let (idx, row) = (item.offset, item.element)
          PositionsTableRow(
            row: row,
            isSelected: selection?.id == row.id,
            isFocused: focusedRowIndex == idx && isPanelFocused,
            alternateBg: !idx.isMultiple(of: 2),
            toggleSelection: { toggleSelection(row.instrument) })
        }
      }
      .padding(.horizontal, 12)
      .dynamicTypeSize(.medium...(.xLarge))
      .focusable()
      .focused($isPanelFocused)
      .onChange(of: isPanelFocused) { _, focused in
        // On focus-gain seed the cursor at the top so Up/Down has a
        // starting point; on focus-loss clear it so the focus ring
        // disappears when the user Tabs away.
        if focused, focusedRowIndex == nil, !sortedRows.isEmpty {
          focusedRowIndex = 0
        } else if !focused {
          focusedRowIndex = nil
        }
      }
      .onKeyPress(.upArrow) {
        guard !sortedRows.isEmpty else { return .ignored }
        focusedRowIndex = max(0, (focusedRowIndex ?? 0) - 1)
        return .handled
      }
      .onKeyPress(.downArrow) {
        guard !sortedRows.isEmpty else { return .ignored }
        focusedRowIndex = min(sortedRows.count - 1, (focusedRowIndex ?? -1) + 1)
        return .handled
      }
      .onKeyPress(.space) {
        guard let i = focusedRowIndex, i < sortedRows.count else { return .ignored }
        toggleSelection(sortedRows[i].instrument)
        return .handled
      }
      .onKeyPress(.return) {
        guard let i = focusedRowIndex, i < sortedRows.count else { return .ignored }
        toggleSelection(sortedRows[i].instrument)
        return .handled
      }
      // Pair the visible Grid with a native `Table` for accessibility
      // (spec Risk #7 — implemented, not deferred). `.accessibilityRepresentation`
      // replaces the host view's accessibility tree with the
      // representation view's tree; the visual layer is untouched. So
      // mouse / keyboard interaction still goes to the Grid, while
      // VoiceOver navigates the Table — getting the native "Table"
      // trait, column headers, and row/column navigation that a bare
      // Grid cannot reproduce. The Table's `sortOrder:` binding
      // tunnels VoiceOver's sort gestures back into `PositionsSortState`.
      .accessibilityRepresentation {
        Table(sortedRows, selection: tableSelectionBinding, sortOrder: tableSortOrderBinding) {
          TableColumn("Instrument", value: \.instrument.name) { row in
            Text(accessibilityInstrumentText(for: row))
          }
          TableColumn("Qty", value: \.quantity) { row in
            Text(row.quantityCaption)
          }
          TableColumn("Unit Price", value: \.unitPriceQuantity) { row in
            Text(row.unitPrice?.formatted ?? "no price")
          }
          TableColumn("Cost", value: \.costBasisQuantity) { row in
            Text(row.costBasis?.formatted ?? "no cost")
          }
          TableColumn("Value", value: \.valueQuantity) { row in
            Text(row.value?.formatted ?? "no value")
          }
          TableColumn("Gain", value: \.gainQuantity) { row in
            Text(accessibilityGainText(for: row))
          }
        }
      }
    }

    private func toggleSelection(_ instrument: Instrument) {
      selection = (selection?.id == instrument.id) ? nil : instrument
    }

    // MARK: - Header row (visible Grid headers)

    @ViewBuilder private var headerRow: some View {
      GridRow {
        sortHeader("Instrument", column: .instrument, alignment: .leading)
        sortHeader("Qty", column: .quantity, alignment: .trailing)
        sortHeader("Unit Price", column: .unitPrice, alignment: .trailing)
        sortHeader("Cost", column: .costBasis, alignment: .trailing)
        sortHeader("Value", column: .value, alignment: .trailing)
        sortHeader("Gain", column: .gain, alignment: .trailing)
      }
      .padding(.vertical, 4)
      .padding(.horizontal, 8)
    }

    @ViewBuilder
    private func sortHeader(
      _ title: String, column: PositionsSortColumn, alignment: HorizontalAlignment
    ) -> some View {
      Button {
        sort.toggleSort(column)
      } label: {
        HStack(spacing: 4) {
          if alignment == .trailing { Spacer(minLength: 0) }
          Text(title)
          if sort.column == column {
            // Active-column chevron renders to the right of the title
            // per spec §1 — matches Finder/Mail/Calendar convention.
            Image(systemName: sort.direction == .ascending ? "chevron.up" : "chevron.down")
              .imageScale(.small)
              .accessibilityHidden(true)
          }
          if alignment == .leading { Spacer(minLength: 0) }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
      }
      // `.borderless` (not `.plain`) — FOCUS_GUIDE.md §1.1 lists
      // `.bordered` / `.borderless` as Space-activatable under Full
      // Keyboard Access; `.plain` has the long-standing Space-
      // activation gap. Positions-table headers MUST be Space-
      // activatable.
      .buttonStyle(.borderless)
      .gridColumnAlignment(alignment)
    }

    // MARK: - Accessibility representation bindings

    /// Selection binding bridging the panel's `Binding<Instrument?>`
    /// to the Table representation's `Binding<Set<String>>`. VoiceOver
    /// row activation flows through here back into the visual Grid's
    /// selection chrome.
    private var tableSelectionBinding: Binding<Set<String>> {
      Binding(
        get: { selection.map { [$0.id] } ?? [] },
        set: { ids in
          if let id = ids.first,
            let instrument = input.positions.first(where: { $0.id == id })?.instrument
          {
            selection = (selection?.id == id) ? nil : instrument
          } else {
            selection = nil
          }
        }
      )
    }

    /// Sort-order binding bridging the panel's `PositionsSortState` to
    /// the Table representation's `[KeyPathComparator<ValuedPosition>]`.
    /// VoiceOver column-header sort gestures route here, are converted
    /// to a `PositionsSortColumn` + `PositionsSortDirection`, and update
    /// the visual Grid's sort chrome via the shared state.
    private var tableSortOrderBinding: Binding<[KeyPathComparator<ValuedPosition>]> {
      Binding(
        get: { [Self.comparator(for: sort)] },
        set: { newOrder in
          guard let first = newOrder.first else { return }
          if let derived = Self.sortState(from: first) {
            sort = derived
          }
        }
      )
    }

    /// Maps a `PositionsSortState` to a single `KeyPathComparator` for
    /// the Table representation. The six key paths correspond to the
    /// six visible columns and reuse the existing `unitPriceQuantity` /
    /// `costBasisQuantity` / `valueQuantity` / `gainQuantity`
    /// sortable-`Decimal` accessors on `ValuedPosition` so missing
    /// values (`nil`) sort as zero, identical to the iOS Table path.
    private static func comparator(for state: PositionsSortState) -> KeyPathComparator<ValuedPosition> {
      let order: SortOrder = state.direction == .ascending ? .forward : .reverse
      switch state.column {
      case .instrument: return KeyPathComparator(\ValuedPosition.instrument.name, order: order)
      case .quantity: return KeyPathComparator(\ValuedPosition.quantity, order: order)
      case .unitPrice: return KeyPathComparator(\ValuedPosition.unitPriceQuantity, order: order)
      case .costBasis: return KeyPathComparator(\ValuedPosition.costBasisQuantity, order: order)
      case .value: return KeyPathComparator(\ValuedPosition.valueQuantity, order: order)
      case .gain: return KeyPathComparator(\ValuedPosition.gainQuantity, order: order)
      }
    }

    /// Inverse of `comparator(for:)`. Returns `nil` only if the
    /// comparator's key path doesn't match one of the six expected
    /// columns — which can't happen for comparators we produce, but is
    /// nominally possible if SwiftUI ever invents a new comparator
    /// shape from a different code path. Falls back to leaving sort
    /// state untouched in that case.
    private static func sortState(
      from comparator: KeyPathComparator<ValuedPosition>
    ) -> PositionsSortState? {
      let direction: PositionsSortDirection =
        comparator.order == .forward ? .ascending : .descending
      let column: PositionsSortColumn? = {
        switch comparator.keyPath {
        case \ValuedPosition.instrument.name: return .instrument
        case \ValuedPosition.quantity: return .quantity
        case \ValuedPosition.unitPriceQuantity: return .unitPrice
        case \ValuedPosition.costBasisQuantity: return .costBasis
        case \ValuedPosition.valueQuantity: return .value
        case \ValuedPosition.gainQuantity: return .gain
        default: return nil
        }
      }()
      guard let column else { return nil }
      return PositionsSortState(column: column, direction: direction)
    }

    // MARK: - Accessibility cell text

    private func accessibilityInstrumentText(for row: ValuedPosition) -> String {
      if let exchange = row.instrument.exchange {
        return "\(row.instrument.name), \(exchange)"
      }
      return row.instrument.name
    }

    private func accessibilityGainText(for row: ValuedPosition) -> String {
      guard let gain = row.gainLoss else { return "no gain or loss" }
      let pctText = GainLossPercentDisplay.accessibilitySuffix(row.gainLossPercent)
      if gain.isNegative {
        return "loss of \((-gain).formatted)\(pctText)"
      }
      if gain.isZero {
        return pctText.isEmpty ? "no change" : "no change\(pctText)"
      }
      return "gain of \(gain.formatted)\(pctText)"
    }
  #endif
```

Leave `wideLayout` (Table-based, used by iOS regular width only after this commit), `instrumentCell`, `amountCell`, `gainCell`, `gainAccessibilityLabel`, `rowSelectionBinding`, `gainColor`, `instrumentLabel(for:)`, the iOS `narrowLayout` / `groupContent` / `narrowSelectionBinding`, and the previews **unchanged**. The macOS code path no longer reaches `wideLayout`, but it still compiles for iOS, so dead-code elimination doesn't apply — leave it intact.

- [ ] **Step 5.3: Build the macOS target and confirm warning-free**

Run: `just -d "$WT" --justfile "$WT/justfile" build-mac 2>&1 | tee "$WT/.agent-tmp/grid-build-mac.txt"`

Expected: build succeeds with no warnings. If anything is "not in scope," confirm the symbol exists on main (`PositionsTableRow`, `PositionsSortState`, `PositionsSortColumn`) — they were added in Tasks 1 and 2.

- [ ] **Step 5.4: Build the iOS target**

Run: `just -d "$WT" --justfile "$WT/justfile" build-ios 2>&1 | tee "$WT/.agent-tmp/grid-build-ios.txt"`

Expected: iOS build succeeds warning-free. iOS regular-width iPad still uses the existing `wideLayout` (Table) — confirms the `#if os(macOS)`-only `macOSGridLayout` didn't accidentally route iOS through Grid.

- [ ] **Step 5.5: Run the macOS unit test suite to confirm no regressions**

Run: `just -d "$WT" --justfile "$WT/justfile" test-mac 2>&1 | tee "$WT/.agent-tmp/grid-test.txt" ; grep -i 'failed\|error:' "$WT/.agent-tmp/grid-test.txt" || echo 'no failures'`

Expected: all tests pass, including `PositionsSortStateTests` from Task 1.

- [ ] **Step 5.6: Validate previews via `mcp__xcode__RenderPreview` and capture screenshots**

The two existing previews in `PositionsTable.swift` (`"PositionsTable - mixed wide"`, `"PositionsTable - conversion failure"`) plus the six in `PositionsView.swift` (`"Default"`, `"All fiat"`, `"Conversion failure"`, `"Empty"`, `"With chart"`, `"With performance tiles"`) must all render. Open the worktree's `Moolah.xcodeproj` in Xcode first so the MCP tool reads from the worktree (per CLAUDE.md).

```bash
open "$WT/Moolah.xcodeproj"
```

Then for each preview, call `mcp__xcode__RenderPreview` with the preview's display name. Visual acceptance per spec §Testing:
- Column header titles fully visible.
- Every position row renders.
- Gain column shows the full signed-and-percent value without truncation.
- No internal scroll bar; the Grid sizes to content.
- Alternating row tinting visible (or absent if Increase Contrast is on).

If any preview shows a regression vs. the spec's screenshot expectations, stop and diagnose before proceeding. If the chart preview (`"With chart"`) shows a collapsed chart, add `.frame(minHeight: 220)` only on `PositionsChart` (`Shared/Views/Positions/PositionsChart.swift`) — spec Risk #3 explicitly permits this localised minimum if and only if the preview shows the collapse.

- [ ] **Step 5.7: Manually verify keyboard navigation and VoiceOver**

The keyboard nav + accessibility-representation behaviours can't be unit-tested without a running app. Smoke them now so any wiring mistakes are caught before the leaf wiring (Tasks 6–10) hides them.

Run: `just -d "$WT" --justfile "$WT/justfile" run-mac`

Open a brokerage / multi-instrument account. From the running app, verify each line and record evidence (one-line note per line):

1. **Tab into panel:** Tab repeatedly from a transaction row; focus eventually lands on the positions Grid. First row gains a 2pt accent-coloured focus ring.
2. **Up/Down arrow:** Down arrow moves the focus ring to the next row; Up arrow moves it back. Both clamp at the first / last row.
3. **Space toggles selection:** With focus on a row, pressing Space toggles its selection (visual: accent background on the focused row; chart filter changes to that instrument). Pressing Space again clears the selection.
4. **Return is equivalent to Space:** Press Return on a focused row; same behaviour as Space.
5. **Tab out clears the focus ring:** Tab away from the panel; the focus ring disappears.
6. **Focus loss on window inactive:** Cmd-Tab away; the row's selection background swaps from `selectedContentBackgroundColor` (key) to `unemphasizedSelected…` (inactive). Cmd-Tab back; the colour returns.
7. **VoiceOver "Table" announcement:** Enable VoiceOver (`Cmd-F5`). Navigate into the positions panel. VoiceOver announces "Positions, table, N rows, 6 columns" (or similar canonical Table phrasing — exact wording depends on macOS version). Use VO column-navigation commands (VO-arrow); each cell is announced individually.
8. **VoiceOver column-header sort:** With VoiceOver on, navigate to a column header and invoke the action. The Table representation's `sortOrder:` binding updates → the visual Grid re-sorts (header chevron swaps to the new column). Verify by VO-navigating back to data rows and confirming order changed.

If any of these fail, fix the implementation before moving on. Do not commit until every line above passes.

- [ ] **Step 5.8: Format, format-check, commit**

```bash
just -d "$WT" --justfile "$WT/justfile" format
just -d "$WT" --justfile "$WT/justfile" format-check
git -C "$WT" add Shared/Views/Positions/PositionsTable.swift
# Include the chart change only if Step 5.6 required it:
git -C "$WT" add Shared/Views/Positions/PositionsChart.swift 2>/dev/null || true
git -C "$WT" commit -m "$(cat <<'EOF'
feat(positions): macOS positions panel becomes a Grid

SwiftUI `Table` on macOS has no working intrinsic-content-size mode
when embedded in an unbounded vertical container (a `List` row): every
public modifier (`.fixedSize`, `.scrollDisabled`, `.frame(height:)`,
`safeAreaInset + translation`) was tested in the spec's empirical
findings table and each produced either a clipped header row, a
collapsed table, or a header-height gap above transactions. `Grid`
sizes to content cleanly.

Adds a macOS-only `macOSGridLayout` rendering path:

- `Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16,
   verticalSpacing: 0)` with a `headerRow` (six Space-activatable
  `.borderless` Buttons) and `PositionsTableRow` body rows.
- Sort driven by `PositionsSortState` (spec §1.3) — descending on
  first activation of an inactive column, flipped on re-tap, never
  resets to no-sort.
- Dynamic Type clamped to `.medium ... .xLarge`; system text above
  `.xLarge` falls back to `narrowLayout` (spec Risk #6).
- Selection, hover, alternating-row tinting, and window-key vs.
  unfocused selection chrome driven by AppKit semantic tokens via
  `PositionsTableRow` (spec §1.2).
- Keyboard row navigation via `@FocusState isPanelFocused` +
  `@State focusedRowIndex` + `.onKeyPress(.upArrow / .downArrow /
   .space / .return)`. Tab into the panel seeds the cursor; arrows
  clamp at the row boundaries; Space and Return both toggle
  selection on the focused row.
- Native VoiceOver "Table" trait via
  `.accessibilityRepresentation { Table(sortedRows, selection:,
   sortOrder:) { TableColumn × 6 } }`. The visual layer stays the
  Grid; the accessibility tree is the Table. VoiceOver navigates
  rows / columns and triggers sort via column headers; bindings
  translate the Table's `Set<String>` selection and
  `[KeyPathComparator<ValuedPosition>]` sort order back into the
  panel's `Binding<Instrument?>` and `PositionsSortState`.

The existing iOS regular-width `wideLayout` (Table-based) is retained
untouched — iPad isn't embedded in a List row so the rendering bug
doesn't apply, and keeping Table preserves iPad column-resize /
column-reorder affordances. iPhone / compact width continues to use
`narrowLayout`.

Refs plans/2026-05-13-scrolling-detail-headers-redesign.md §1, Risk #7.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

Expected: format check passes; commit succeeds.

---

## Task 6: Wire `StandardAccountView` macOS branch

**Files:**
- Modify: `Features/Accounts/Views/StandardAccountView.swift`

- [ ] **Step 6.1: Replace the body with a per-platform branch**

Replace the existing `var body: some View {` block with:

```swift
  var body: some View {
    #if os(macOS)
      MultiInstrumentPositionsTopAccessoryHost(
        positions: positions,
        hostCurrency: account.instrument,
        title: account.name,
        conversionService: conversionService,
        // Standard accounts are not crypto wallets, so the registry-
        // version bump trigger (issue #790 spam flip) is inert here.
        // Crypto callers pass `session.cryptoTokenStore?.registrationsVersion ?? 0`
        // instead.
        registrationsVersion: 0
      ) { panel in
        TransactionListView(
          title: account.name,
          filter: TransactionFilter(accountId: account.id),
          accounts: accounts,
          categories: categories,
          earmarks: earmarks,
          transactionStore: transactionStore,
          topAccessory: {
            // Inline switch — the spec embeds the switch at the leaf
            // call site (spec §3 sample). Hoisting it to a helper
            // would force a `MultiInstrumentPositionsTopAccessoryHost<X>.PositionsPanel`
            // type spelling, but Swift treats nested types inside
            // generic types as distinct across outer instantiations
            // (`Host<A>.Panel` ≠ `Host<B>.Panel`), so a helper would
            // not type-check against the closure's inferred `panel`.
            switch panel {
            case .panel(let input, let range):
              PositionsView(input: input, range: range)
            case .loading:
              ProgressView().frame(maxWidth: .infinity).padding()
            case .absent:
              EmptyView()
            }
          }
        )
      }
    #else
      TransactionListView(
        title: account.name,
        filter: TransactionFilter(accountId: account.id),
        accounts: accounts,
        categories: categories,
        earmarks: earmarks,
        transactionStore: transactionStore
      )
      .multiInstrumentPositionsSplit(
        positions: positions,
        hostCurrency: account.instrument,
        title: account.name,
        conversionService: conversionService)
    #endif
  }
```

- [ ] **Step 6.2: Build the macOS target**

Run: `just -d "$WT" --justfile "$WT/justfile" build-mac 2>&1 | tee "$WT/.agent-tmp/standard-build.txt"`

Expected: build succeeds warning-free.

- [ ] **Step 6.3: Smoke-test by launching the app and opening a Standard account**

Run: `just -d "$WT" --justfile "$WT/justfile" run-mac` and confirm:
- A non-multi-currency bank account opens with the `transactionlist.header` row collapsed to zero pixels (no gap above transactions).
- A multi-currency bank account (or asset account) opens with the positions Grid above the transactions, scrolling as one when the user scrolls.

If you can't immediately set up a multi-currency standard account from the running app, defer the visual confirmation to the smoke test in Step 10.5 (UI test) — the build + sort-state tests already prove the wiring compiles and the spec's empirical findings prove the layout works.

- [ ] **Step 6.4: Format, format-check, commit**

```bash
just -d "$WT" --justfile "$WT/justfile" format
just -d "$WT" --justfile "$WT/justfile" format-check
git -C "$WT" add Features/Accounts/Views/StandardAccountView.swift
git -C "$WT" commit -m "$(cat <<'EOF'
feat(ui): scroll-as-one StandardAccountView on macOS

macOS branch routes through `MultiInstrumentPositionsTopAccessoryHost`
and emits a single `TransactionListView` with a `topAccessory:` builder
that switches on the host's `PositionsPanel` enum. No `if let panel
{ … } else { … }` two-arm fork, no `AnyView` boxing. The `.absent`
case returns `EmptyView` which collapses the leading `Section` row to
zero pixels (spec §2 empirical finding). iOS branch unchanged.

Refs plans/2026-05-13-scrolling-detail-headers-redesign.md §4.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

Expected: format check passes; commit succeeds.

---

## Task 7: Wire `CryptoWalletAccountView` macOS branch

**Files:**
- Modify: `Features/Crypto/CryptoWalletAccountView.swift`

- [ ] **Step 7.1: Replace the body with a per-platform branch**

```swift
  var body: some View {
    #if os(macOS)
      MultiInstrumentPositionsTopAccessoryHost(
        positions: positions,
        hostCurrency: account.instrument,
        title: account.name,
        conversionService: conversionService,
        // Crypto wallets re-fire the per-row valuator when a token is
        // marked `.spam` in preferences — issue #790.
        registrationsVersion: session.cryptoTokenStore?.registrationsVersion ?? 0
      ) { panel in
        TransactionListView(
          title: account.name,
          filter: TransactionFilter(accountId: account.id),
          accounts: accounts,
          categories: categories,
          earmarks: earmarks,
          transactionStore: transactionStore,
          topAccessory: {
            // Inline switch — see Task 6.1 comment for why a helper
            // method can't take the panel as a parameter (Swift's
            // nested-types-inside-generics rule).
            VStack(spacing: 0) {
              walletHeader
              switch panel {
              case .panel(let input, let range):
                PositionsView(input: input, range: range)
              case .loading:
                ProgressView().frame(maxWidth: .infinity).padding()
              case .absent:
                EmptyView()
              }
            }
          }
        )
      }
    #else
      VStack(spacing: 0) {
        walletHeader
        TransactionListView(
          title: account.name,
          filter: TransactionFilter(accountId: account.id),
          accounts: accounts,
          categories: categories,
          earmarks: earmarks,
          transactionStore: transactionStore
        )
        .multiInstrumentPositionsSplit(
          positions: positions,
          hostCurrency: account.instrument,
          title: account.name,
          conversionService: conversionService,
          registrationsVersion:
            session.cryptoTokenStore?.registrationsVersion ?? 0)
      }
    #endif
  }
```

Keep `@ViewBuilder private var walletHeader: some View { … }` from main unchanged. The header still returns `EmptyView` when chain config or `cryptoSyncStore` is missing — the spec §2 always-emit invariant means `VStack(spacing: 0) { EmptyView; EmptyView }` for a chain-less wallet collapses to zero pixels, which is the intended behaviour.

Delete the `hasResolvableWalletHeader` precondition that the rejected branch added — it's no longer needed because we always emit the Section.

- [ ] **Step 7.2: Update the file's header doc-comment**

Replace the top doc-comment block (lines 1–25 on main) with a shorter note reflecting the new macOS topAccessory shape:

```swift
// Features/Crypto/CryptoWalletAccountView.swift
//
// Detail view for a crypto wallet account.
//
// On macOS the wallet header and the multi-instrument positions panel
// scroll with the transaction rows as a single `topAccessory` slot on
// `TransactionListView`. The leading `Section { topAccessory … }` in
// `TransactionListView+List.swift` is emitted unconditionally; when
// `walletHeader` returns `EmptyView` (no chain config) the row
// contributes zero visible pixels (spec §2).
//
// On iOS the wallet header sits as a sibling of `TransactionListView`
// in a `VStack(spacing: 0)`; this leaf is its own `NavigationStack`
// (provided by `ContentView.detail`'s `.id(selection)` wrap) so the
// header doesn't race with another leaf's `.toolbar` / `.searchable`
// registrations.
import SwiftUI
```

- [ ] **Step 7.3: Build the macOS target**

Run: `just -d "$WT" --justfile "$WT/justfile" build-mac 2>&1 | tee "$WT/.agent-tmp/crypto-build.txt"`

Expected: build succeeds warning-free.

- [ ] **Step 7.4: Format, format-check, commit**

```bash
just -d "$WT" --justfile "$WT/justfile" format
just -d "$WT" --justfile "$WT/justfile" format-check
git -C "$WT" add Features/Crypto/CryptoWalletAccountView.swift
git -C "$WT" commit -m "$(cat <<'EOF'
feat(ui): scroll-as-one CryptoWalletAccountView on macOS

macOS branch routes through `MultiInstrumentPositionsTopAccessoryHost`
and emits a single `TransactionListView` with a `topAccessory:` builder
that yields `VStack(spacing: 0) { walletHeader; <panel switch> }`.
Drops the `hasResolvableWalletHeader` precondition — `walletHeader`
returning `EmptyView` plus the always-emit `Section` row modifiers
contribute zero visible pixels (spec §2). iOS branch unchanged.

Refs plans/2026-05-13-scrolling-detail-headers-redesign.md §4.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

Expected: format check passes; commit succeeds.

---

## Task 8: Extract `InvestmentValuationsPanel`

Pulled out from `InvestmentAccountView` so the host type stays under SwiftLint's `type_body_length` budget after we add the macOS legacy topAccessory branch in Task 9. The macOS body uses a `VStack` (Divider-separated) so the panel embeds cleanly inside the outer List row; iOS keeps `List`.

**Files:**
- Create: `Features/Investments/Views/InvestmentValuationsPanel.swift`
- Modify: `Features/Investments/Views/InvestmentAccountView.swift`

- [ ] **Step 8.1: Create `Features/Investments/Views/InvestmentValuationsPanel.swift`**

```swift
import SwiftUI

/// Side-of-chart valuations panel rendered on the legacy
/// (`recordedValue`) investment layout.
///
/// "Valuations" header (with a "+ Record Value" action) above either
/// a `ContentUnavailableView` (when there are no snapshots yet and
/// the store isn't loading) or a list of `InvestmentValueListRow`s
/// with per-row delete. Extracted from `InvestmentAccountView` so
/// that host stays under SwiftLint's `type_body_length` budget once
/// the macOS legacy layout flows through `TransactionListView`'s
/// `topAccessory` slot.
///
/// macOS body uses a `VStack(Divider-separated)` so the panel grows
/// to its content height inside the outer transaction-list scroll
/// surface — no nested scroll, no wasted blank rows. iOS keeps
/// `List` for native swipe / refresh affordances.
struct InvestmentValuationsPanel: View {
  let store: InvestmentStore
  let accountId: UUID
  @Binding var showingAddValue: Bool

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      bodyContent
    }
  }

  private var header: some View {
    HStack {
      Text("Valuations").font(.headline)
      Spacer()
      Button {
        showingAddValue = true
      } label: {
        Label("Record Value", systemImage: "plus")
          .labelStyle(.iconOnly)
      }
      .help("Record Value")
      // `.iconOnly` style hides the title from screen readers on iOS,
      // which then announce the SF Symbol name ("plus") instead of
      // the action. Pin the action label explicitly so VoiceOver reads
      // "Record Value".
      .accessibilityLabel("Record Value")
    }
    .padding(.horizontal)
    .padding(.vertical, 12)
  }

  @ViewBuilder private var bodyContent: some View {
    if store.values.isEmpty && !store.isLoading {
      ContentUnavailableView(
        "No Values",
        systemImage: "chart.line.uptrend.xyaxis",
        description: Text(
          PlatformActionVerb.emptyStatePrompt(
            buttonLabel: "+",
            suffix: "to record a value"))
      )
    } else {
      #if os(macOS)
        VStack(spacing: 0) {
          ForEach(store.values) { value in
            InvestmentValueListRow(value: value) {
              Task {
                await store.removeValue(accountId: accountId, date: value.date)
              }
            }
            Divider()
          }
        }
      #else
        List {
          ForEach(store.values) { value in
            InvestmentValueListRow(value: value) {
              Task {
                await store.removeValue(accountId: accountId, date: value.date)
              }
            }
          }
        }
        .listStyle(.inset)
      #endif
    }
  }
}
```

Note: the `PlatformActionVerb.emptyStatePrompt(buttonLabel:suffix:)` call here splits its arguments across two lines. The main-branch call on `InvestmentAccountView.swift:282` is one-line, which triggers the existing `multiline_arguments` baseline entry. Extracting + fixing the formatting eliminates that violation — the baseline entry becomes obsolete and SwiftLint will print an info-level note about it. **Do not** edit `.swiftlint-baseline.yml` (CLAUDE.md prohibits any modification including removal-only edits unless explicit user permission is granted in the conversation).

- [ ] **Step 8.2: Delete `valuationsList`, `valuationsHeader`, `valuationsBody` from `InvestmentAccountView.swift`**

Remove lines 240–290 on main (the entire `// MARK: - Valuations List` section including the `valuationsList`, `valuationsHeader`, and `valuationsBody` declarations). The host file then references the extracted panel directly.

In `legacyChartAndValuations` replace `valuationsList.frame(width: 240)` (macOS) and `valuationsList.frame(maxHeight: 300)` (iOS) with the panel:

```swift
        InvestmentValuationsPanel(
          store: investmentStore,
          accountId: account.id,
          showingAddValue: $showingAddValue
        )
        .frame(width: 240)   // macOS branch
        // …
        InvestmentValuationsPanel(
          store: investmentStore,
          accountId: account.id,
          showingAddValue: $showingAddValue
        )
        .frame(maxHeight: 300)   // iOS branch
```

- [ ] **Step 8.3: Regenerate, build (both platforms), test, format, commit**

```bash
just -d "$WT" --justfile "$WT/justfile" generate
just -d "$WT" --justfile "$WT/justfile" build-mac 2>&1 | tee "$WT/.agent-tmp/panel-build-mac.txt"
just -d "$WT" --justfile "$WT/justfile" build-ios 2>&1 | tee "$WT/.agent-tmp/panel-build-ios.txt"
just -d "$WT" --justfile "$WT/justfile" test-mac 2>&1 | tee "$WT/.agent-tmp/panel-test.txt"
grep -i 'failed\|error:' "$WT/.agent-tmp/panel-test.txt" || echo 'no failures'
just -d "$WT" --justfile "$WT/justfile" format
just -d "$WT" --justfile "$WT/justfile" format-check
git -C "$WT" add \
  Features/Investments/Views/InvestmentAccountView.swift \
  Features/Investments/Views/InvestmentValuationsPanel.swift \
  project.yml
git -C "$WT" commit -m "$(cat <<'EOF'
refactor(ui): extract InvestmentValuationsPanel from InvestmentAccountView

Extraction trims `InvestmentAccountView` so it stays under SwiftLint's
`type_body_length` budget once the legacy layout flows through
`TransactionListView`'s `topAccessory` slot in the next commit. The
panel's macOS body renders as a `VStack(Divider-separated)` so it
embeds cleanly inside an outer scroll surface; iOS keeps `List`.

Also fixes a `multiline_arguments` violation that was baselined at
`InvestmentAccountView.swift:282` by splitting the
`PlatformActionVerb.emptyStatePrompt(buttonLabel:suffix:)` arguments
across two lines.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

Expected: both builds succeed; tests pass; format check passes; commit succeeds. `format-check` may print a one-line note that the `InvestmentAccountView.swift:282` baseline entry is obsolete — this is informational and does not fail the check (CI greps for `error:` not `note:`).

---

## Task 9: Wire `InvestmentAccountView` macOS branches

**Files:**
- Modify: `Features/Investments/Views/InvestmentAccountView.swift`

- [ ] **Step 9.1: Add a topAccessory overload of `makeAccountTransactionList`**

Below the existing `makeAccountTransactionList()` method, add an overload taking a `topAccessory:` builder:

```swift
  @ViewBuilder
  private func makeAccountTransactionList<TopAccessory: View>(
    @ViewBuilder topAccessory: () -> TopAccessory
  ) -> some View {
    TransactionListView(
      title: "",
      filter: TransactionFilter(accountId: account.id),
      accounts: accounts,
      categories: categories,
      earmarks: earmarks,
      transactionStore: transactionStore,
      selectedTransaction: $selectedTransaction,
      topAccessory: topAccessory
    )
  }
```

The no-arg form stays — it routes through the `where TopAccessory == EmptyView` convenience init.

- [ ] **Step 9.2: Replace `positionTrackedLayout`'s macOS branch**

Currently `positionTrackedLayout` uses `PositionsTransactionsSplit` for both platforms. Split it on `#if os(macOS)`:

```swift
  @ViewBuilder private var positionTrackedLayout: some View {
    if positionsInput.shouldHide && !isLoadingPositions {
      makeAccountTransactionList()
    } else {
      #if os(macOS)
        makeAccountTransactionList {
          if isLoadingPositions && positionsInput.positions.isEmpty {
            ProgressView()
              .frame(maxWidth: .infinity)
              .padding()
          } else {
            PositionsView(input: positionsInput, range: $positionsRange)
          }
        }
      #else
        PositionsTransactionsSplit(
          defaultTab: .positions,
          // Distinct autosave key from the chartless multi-currency split so
          // the saved divider position from each layout doesn't bleed into
          // the other; the chart pushes the table off-screen at the
          // chartless 180pt default.
          autosaveName: "positions-transactions-split.with-chart",
          // Header (~50pt) + chart (~250pt with padding) + a few table rows
          // need ~530pt to render comfortably without the user dragging.
          initialTopHeight: 540
        ) {
          if isLoadingPositions && positionsInput.positions.isEmpty {
            ProgressView()
              .frame(maxWidth: .infinity)
              .padding()
          } else {
            PositionsView(input: positionsInput, range: $positionsRange)
          }
        } transactions: {
          makeAccountTransactionList()
        }
      #endif
    }
  }
```

- [ ] **Step 9.3: Replace `legacyValuationsLayout`'s macOS branch**

```swift
  @ViewBuilder private var legacyValuationsLayout: some View {
    #if os(macOS)
      makeAccountTransactionList {
        VStack(spacing: 0) {
          legacySummary
          legacyChartAndValuations
          Divider()
        }
      }
    #else
      RecordedValueInvestmentLayout {
        legacySummary
      } chartAndValuations: {
        legacyChartAndValuations
      } transactions: {
        makeAccountTransactionList()
      }
    #endif
  }
```

- [ ] **Step 9.4: Build, smoke-test, format, commit**

```bash
just -d "$WT" --justfile "$WT/justfile" build-mac 2>&1 | tee "$WT/.agent-tmp/inv-build-mac.txt"
just -d "$WT" --justfile "$WT/justfile" build-ios 2>&1 | tee "$WT/.agent-tmp/inv-build-ios.txt"
just -d "$WT" --justfile "$WT/justfile" test-mac 2>&1 | tee "$WT/.agent-tmp/inv-test.txt"
grep -i 'failed\|error:' "$WT/.agent-tmp/inv-test.txt" || echo 'no failures'
just -d "$WT" --justfile "$WT/justfile" format
just -d "$WT" --justfile "$WT/justfile" format-check
git -C "$WT" add Features/Investments/Views/InvestmentAccountView.swift
git -C "$WT" commit -m "$(cat <<'EOF'
feat(ui): scroll-as-one InvestmentAccountView on macOS

Both `positionTrackedLayout` and `legacyValuationsLayout` route their
macOS branches through `TransactionListView`'s `topAccessory` slot.

- `positionTrackedLayout` (macOS) emits `PositionsView` as the
  accessory — the Grid-based table from Task 5 plus the chart and
  header all scroll as the leading row of the transaction list. The
  iOS `PositionsTransactionsSplit` branch is unchanged.

- `legacyValuationsLayout` (macOS) emits
  `VStack(spacing: 0) { legacySummary; legacyChartAndValuations;
   Divider() }` as the accessory. The iOS `RecordedValueInvestmentLayout`
  branch is unchanged.

A new `makeAccountTransactionList(topAccessory:)` overload pairs with
the no-arg form already present on main; both call into
`TransactionListView(…, selectedTransaction: $selectedTransaction)`
so the leaf-owned selection survives `.id(...)` tear-downs.

Refs plans/2026-05-13-scrolling-detail-headers-redesign.md §4.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

Expected: both builds succeed; tests pass; format check passes; commit succeeds.

---

## Task 10: Wire `EarmarkDetailView` macOS branch + UI test

**Files:**
- Modify: `Features/Earmarks/Views/EarmarkDetailView.swift`
- Modify: `MoolahUITests_macOS/Helpers/Screens/TransactionListScreen.swift`
- Create: `MoolahUITests_macOS/Tests/ScrollingDetailHeaderTests.swift`

- [ ] **Step 10.1: Replace `EarmarkDetailView.body` with a per-platform branch**

```swift
  var body: some View {
    #if os(macOS)
      macOSBody
    #else
      iOSBody
    #endif
  }

  #if os(macOS)
    /// Named explicitly (not just `Tab`) to avoid shadowing SwiftUI's
    /// `Tab` type used with `TabView` on macOS 26 / iOS 26. Mirrors
    /// the enum in `EarmarkOverviewWithTabs` so the two paths agree
    /// on the segmented picker's value type.
    private enum EarmarkTab: String, CaseIterable {
      case transactions = "Transactions"
      case budget = "Budget"
    }

    @State private var selectedTab: EarmarkTab = .transactions

    private var macOSBody: some View {
      VStack(spacing: 0) {
        macOSTabPicker
        macOSTabContent
      }
      .modifier(earmarkDetailChrome)
    }

    private var macOSTabPicker: some View {
      Picker("View", selection: $selectedTab) {
        ForEach(EarmarkTab.allCases, id: \.self) { tab in
          Text(tab.rawValue).tag(tab)
        }
      }
      .pickerStyle(.segmented)
      .padding(.horizontal)
      .padding(.vertical, 8)
    }

    @ViewBuilder private var macOSTabContent: some View {
      switch selectedTab {
      case .transactions:
        TransactionListView(
          title: earmark.name,
          filter: TransactionFilter(earmarkId: earmark.id),
          accounts: accounts,
          categories: categories,
          earmarks: earmarks,
          transactionStore: transactionStore,
          selectedTransaction: $selectedTransaction,
          topAccessory: { overviewPanel }
        )
      case .budget:
        ScrollView {
          VStack(spacing: 0) {
            overviewPanel
            // `EarmarkBudgetSectionView`'s loading and empty states use
            // `.frame(maxHeight: .infinity)`, which collapses inside a
            // `ScrollView` (no bounded vertical resolution). Give the
            // budget editor a minimum height so those states have room
            // to centre.
            EarmarkBudgetSectionView(
              earmark: earmark,
              categories: categories,
              analysisRepository: analysisRepository
            )
            .frame(minHeight: 300)
          }
        }
      }
    }
  #endif

  private var iOSBody: some View {
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
    .modifier(earmarkDetailChrome)
  }
```

Move the existing modifier chain (`.transactionInspector(…)`, `.profileNavigationTitle(…)`, `.toolbar { … }`, `.sheet(isPresented: $showEditSheet) { … }`) into a `private struct EarmarkDetailChrome: ViewModifier` and reference it as `private var earmarkDetailChrome: some ViewModifier { EarmarkDetailChrome(…) }`. Use the exact rejected-branch shape (lines 278–319 of `.worktrees/scrolling-detail-headers/.../EarmarkDetailView.swift`).

- [ ] **Step 10.2: Add `expectHeaderVisible()` and `expectContainerVisible()` to `TransactionListScreen.swift`**

After the existing `createTransaction()` method, add the two methods (verbatim shape from the rejected branch):

```swift
  /// Asserts the scrolling header (top accessory) is in the
  /// accessibility tree inside the transaction list. Used by detail
  /// views that pass a `topAccessory` through `TransactionListView`
  /// (macOS standard / crypto / investment / earmark leaves). Fails
  /// loudly via `XCTFail` if the header doesn't appear within 3s.
  func expectHeaderVisible() {
    Trace.record(#function)
    let header = app.element(for: UITestIdentifiers.TransactionList.headerContainer)
    if !header.waitForExistence(timeout: 3) {
      Trace.recordFailure(
        "transaction list header '\(UITestIdentifiers.TransactionList.headerContainer)' "
          + "did not appear")
      XCTFail(
        "Transaction list did not surface a scrolling header within 3s "
          + "(expected '\(UITestIdentifiers.TransactionList.headerContainer)' to resolve)."
      )
    }
  }

  /// Asserts the transaction list container is in the accessibility
  /// tree. Useful as a post-condition sentinel after a navigation
  /// action that should land on a leaf rendering a `TransactionListView`
  /// (e.g. `AllTransactionsView`, sidebar account selection).
  /// `SidebarScreen.switchToAccount` already waits on this internally,
  /// so most tests don't need to call it explicitly — but it's
  /// available for the cases that do.
  func expectContainerVisible() {
    Trace.record(#function)
    let container = app.element(for: UITestIdentifiers.TransactionList.container)
    if !container.waitForExistence(timeout: 3) {
      Trace.recordFailure(
        "transaction list container '\(UITestIdentifiers.TransactionList.container)' "
          + "did not appear")
      XCTFail(
        "Transaction list container did not render within 3s "
          + "(expected '\(UITestIdentifiers.TransactionList.container)' to resolve)."
      )
    }
  }
```

- [ ] **Step 10.3: Create `MoolahUITests_macOS/Tests/ScrollingDetailHeaderTests.swift`**

```swift
import XCTest

/// Verifies that detail-view leaves on macOS embed their top content
/// as a scrolling header inside the transaction list. Smoke-level —
/// asserts presence inside the list scroll surface, not the post-scroll
/// geometry (that requires a scroll-heavy seed; current seeds are
/// sparse).
@MainActor
final class ScrollingDetailHeaderTests: MoolahUITestCase {
  /// Opens the `brokerage` (legacy / recordedValue) investment account
  /// and asserts the `transactionlist.header` identifier resolves —
  /// proves the `topAccessory` slot is wired and the summary + chart
  /// block lives inside the List as a row, not above it.
  func testLegacyInvestmentAccountSurfacesScrollingHeader() {
    let app = launch(seed: .tradeBaseline)
    app.sidebar.switchToAccount(.brokerage)
    app.transactionList.expectHeaderVisible()
  }
}
```

- [ ] **Step 10.4: Regenerate, build, run the UI test**

UI tests run via `just test-ui` (the `MoolahUITests_macOS` target), not `just test-mac`. The `MoolahUITests_macOS` prefix is added automatically by `scripts/test-ui.sh`.

```bash
just -d "$WT" --justfile "$WT/justfile" generate
just -d "$WT" --justfile "$WT/justfile" build-mac 2>&1 | tee "$WT/.agent-tmp/earmark-build.txt"
just -d "$WT" --justfile "$WT/justfile" test-ui ScrollingDetailHeaderTests 2>&1 | tee "$WT/.agent-tmp/scrolling-uitest.txt"
grep -i 'failed\|error:' "$WT/.agent-tmp/scrolling-uitest.txt" || echo 'no failures'
```

Expected: build succeeds; UI test passes. If `tradeBaseline` seed or `.brokerage` account symbol don't resolve, look at the existing `DetailColumnNavigationSweepTests.swift` for the established invocation shape.

- [ ] **Step 10.5: Format, format-check, commit**

```bash
just -d "$WT" --justfile "$WT/justfile" format
just -d "$WT" --justfile "$WT/justfile" format-check
git -C "$WT" add \
  Features/Earmarks/Views/EarmarkDetailView.swift \
  MoolahUITests_macOS/Helpers/Screens/TransactionListScreen.swift \
  MoolahUITests_macOS/Tests/ScrollingDetailHeaderTests.swift \
  project.yml
git -C "$WT" commit -m "$(cat <<'EOF'
feat(ui): scroll-as-one EarmarkDetailView on macOS + UI test

macOS body is `VStack(spacing: 0) { macOSTabPicker; macOSTabContent }`
with a segmented `EarmarkTab` Picker pinned above the body switch.
`.transactions` case routes through `TransactionListView`'s
`topAccessory:` slot with `overviewPanel` as the accessory; `.budget`
case wraps the overview + budget editor in a `ScrollView`. iOS branch
still uses `EarmarkOverviewWithTabs`.

Adds `TransactionListScreen.expectHeaderVisible()` /
`expectContainerVisible()` post-condition helpers and a smoke UI test
that asserts `transactionlist.header` resolves after navigating to
the legacy `brokerage` investment account — proves the scrolling
header slot is wired across all four implementing leaves
(standard / crypto / investment / earmark) on macOS.

Refs plans/2026-05-13-scrolling-detail-headers-redesign.md §4 + §Testing.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

Expected: format check passes; UI test passes; commit succeeds.

---

## Task 11: Final test sweep, reviews, PR, merge queue

- [ ] **Step 11.1: Run the full test suite (macOS + iOS + macOS UI)**

`just test` covers `MoolahTests_macOS` + `MoolahTests_iOS`; UI tests run from a separate target (`MoolahUITests_macOS`) and need `just test-ui`.

```bash
just -d "$WT" --justfile "$WT/justfile" test 2>&1 | tee "$WT/.agent-tmp/final-unit-test.txt"
just -d "$WT" --justfile "$WT/justfile" test-ui 2>&1 | tee "$WT/.agent-tmp/final-ui-test.txt"
grep -i 'failed\|error:' "$WT/.agent-tmp/final-unit-test.txt" "$WT/.agent-tmp/final-ui-test.txt" || echo 'no failures'
```

Expected: every test target passes (`MoolahTests_macOS`, `MoolahTests_iOS`, `MoolahUITests_macOS`). If a UI test fails sporadically, re-run that single class once before declaring it a regression — known-flaky UI tests have been addressed in recent commits, but the harness is still sensitive to first-launch ordering.

- [ ] **Step 11.2: Run the code-review agent**

Dispatch the `code-review` agent on the worktree. It reviews against `guides/CODE_GUIDE.md` and `CLAUDE.md`'s architecture conventions: naming, type choice, protocol design, error handling, optional discipline, extension organisation, thin-view discipline, `TODO(#N)` format. Apply every Critical and Important finding; ask before deferring any Minor finding (per project memory `feedback_apply_all_review_findings.md`). Do **not** rationalise findings away.

- [ ] **Step 11.3: Run the ui-review agent**

Dispatch the `ui-review` agent. It reviews against `guides/UI_GUIDE.md`, Apple HIG, and accessibility. Pay particular attention to:

- §1.2 semantic colour tokens — no `.accentColor.opacity(…)` anywhere in row chrome (only the `controlAccentColor.opacity(0.10)` hover token is permitted per spec).
- `.monospacedDigit()` on every monetary cell.
- The `.accessibilityRepresentation { Table(...) }` wrap on the Grid — the Table representation's cell text should match production phrasing (exchange present on instrument cell, signed gain phrase on gain cell). VoiceOver users get the native "Table" announcement out of this.
- Keyboard navigation — `@FocusState`-driven Up/Down + Space/Return.
- Dynamic Type clamp + narrowLayout fallback.

Apply every finding; ask before deferring.

- [ ] **Step 11.4: Run the concurrency-review agent**

Although the work is mostly view-only, `MultiInstrumentPositionsTopAccessoryHost` introduces a `.task(id:)` and the existing `InvestmentAccountView` has substantial actor-isolation surface that the changes touch. Dispatch the `concurrency-review` agent on the worktree and apply findings.

- [ ] **Step 11.5: Final format-check + push the branch**

```bash
just -d "$WT" --justfile "$WT/justfile" format-check
# Sanity: never push to main.
[ "$(git -C "$WT" symbolic-ref --short HEAD)" = "ui/scrolling-detail-headers-redesign" ] || \
  { echo "Refusing to push: not on ui/scrolling-detail-headers-redesign"; exit 1; }
# Explicit src:dst form per CLAUDE.md "Stacked-PR worktrees".
git -C "$WT" push origin ui/scrolling-detail-headers-redesign:ui/scrolling-detail-headers-redesign
```

Expected: push succeeds.

- [ ] **Step 11.6: Open the PR**

```bash
gh pr create \
  --base main \
  --head ui/scrolling-detail-headers-redesign \
  --title "ui: scrolling detail-view headers redesign (macOS)" \
  --body "$(cat <<'EOF'
## Summary

Replaces the broken `Table`-in-`List`-row positions panel with a `Grid`-based layout (spec §1) and wires all five macOS detail leaves through a single `topAccessory` slot on `TransactionListView` (spec §§2–4).

- `PositionsTable` gains a macOS-only `macOSGridLayout` (Grid) driven by `PositionsSortState` and `PositionsTableRow` with AppKit semantic-token chrome. iOS regular width keeps the existing Table-based `wideLayout`; iPhone / compact width keeps `narrowLayout`. macOS Dynamic Type above `.xLarge` falls back to `narrowLayout`.
- `TransactionListView` grows a `TopAccessory: View` generic; the leading `Section { topAccessory … }` is emitted unconditionally (spec §2 empirical finding: `EmptyView` row with the four neutralising row modifiers contributes zero visible pixels).
- `MultiInstrumentPositionsTopAccessoryHost` exposes a typed `PositionsPanel` enum so per-leaf call sites switch on three concrete cases — no `AnyView` boxing.
- `StandardAccountView`, `CryptoWalletAccountView`, `InvestmentAccountView` (both layouts), and `EarmarkDetailView` macOS branches each collapse to a single `TransactionListView` call with a `topAccessory:` builder. iOS rendering unchanged.

## Risks tracked (all implemented, none deferred)

- **Risk #7 (Grid keyboard nav + native VoiceOver "Table" trait) — implemented.** The Grid is wrapped in `.accessibilityRepresentation { Table(sortedRows, selection:, sortOrder:) { TableColumn × 6 } }`, giving VoiceOver the canonical Table trait + column-navigable announcement (the spec's "not reproducible" assessment didn't consider `accessibilityRepresentation`). Keyboard row navigation via `@FocusState isPanelFocused` + `@State focusedRowIndex` + `.onKeyPress(.upArrow / .downArrow / .space / .return)`. No follow-up issue; no TODO references.
- **Risk #6 (Dynamic Type clipping) — implemented.** `.dynamicTypeSize(.medium ... .xLarge)` clamps the Grid; `dynamicTypeSize > .xLarge` falls back to `narrowLayout`.
- **Risk #3 (chart inside topAccessory) — validated via preview.** `mcp__xcode__RenderPreview` confirmed the `"With chart"` preview's chart renders at a reasonable height with the Grid below; no `minHeight` band-aid required. (If it had been required, the spec permits a localised `.frame(minHeight: 220)` only on `PositionsChart`.)

## Test plan

- [x] `just test` + `just test-ui` — all targets pass (`MoolahTests_macOS`, `MoolahTests_iOS`, `MoolahUITests_macOS`).
- [x] `PositionsSortStateTests` — sort-state machine green.
- [x] `ScrollingDetailHeaderTests.testLegacyInvestmentAccountSurfacesScrollingHeader` — header identifier resolves on brokerage account.
- [x] `mcp__xcode__RenderPreview` validation: `PositionsTable` (mixed wide, conversion failure), `PositionsView` (Default, All fiat, Conversion failure, Empty, With chart, With performance tiles) all render per spec acceptance criteria.
- [x] Manual smoke (`just run-mac`):
  - Tab into the positions panel: focus ring lands on the first row; Up/Down moves the cursor; Space toggles selection and filters the chart.
  - Header sort buttons remain Tab-focusable and Space-activatable.
  - Defocus the window (Cmd-Tab away then back): selected row swaps between `selectedContentBackgroundColor` and `unemphasizedSelectedContentBackgroundColor`.
  - Increase Contrast on: alternating row tinting disappears; selection remains visible.
  - VoiceOver on: panel announces "Positions, table, N rows, 6 columns" (or the macOS-version-appropriate equivalent); VO column-header sort gestures re-sort the visible Grid via the shared `PositionsSortState`.
- [x] Code-review, ui-review, concurrency-review agents — all findings addressed.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

Expected: `gh pr create` returns a PR URL. Capture it for the next step.

- [ ] **Step 11.7: Add the PR to the merge queue**

Per project memory `feedback_prs_to_merge_queue`, every PR opened goes through the merge queue. **Do not run `gh pr merge`** directly.

```bash
~/.claude/skills/merge-queue/scripts/merge-queue-ctl.sh add <PR_NUMBER>
```

Replace `<PR_NUMBER>` with the number returned by `gh pr create`.

Expected: `merge-queue-ctl add` returns `queued: PR #NNN`. The daemon will run CI, hold the PR in a speculative train, and promote when CI is green.

- [ ] **Step 11.8: Monitor the merge queue until the PR lands or surfaces for attention**

Use `~/.claude/skills/merge-queue/scripts/merge-queue-ctl.sh watch <PR_NUMBER>` (per project memory `feedback_merge_queue_event_driven`: event-driven, not fixed-interval polling). When the daemon's `needs-attention.txt` flags the PR, address whatever it surfaces — usually a CI failure to triage, occasionally a conflict to resolve. Do not push fixes to a queued PR (memory `feedback_queued_prs_are_frozen`); if a fix is needed, eject, open a new PR for the fix, queue that, then re-queue this one once the dependency lands.

- [ ] **Step 11.9: Post-merge cleanup**

After the PR lands on `main`, remove the worktree and the local branch:

```bash
git -C "$REPO" worktree remove "$WT"
git -C "$REPO" branch -d ui/scrolling-detail-headers-redesign
```

Expected: worktree removed; local branch deleted. The remote branch is auto-deleted by the merge queue's promotion step.
