# Earmark Creation Bootstrap — Design

## Problem

A user with zero earmarks has no way to create one on iOS, and a constrained way on macOS.

Today, "create earmark" entry points are:

1. The `+` button inside the **Earmarks section header** in the sidebar (`Features/Navigation/SidebarView.swift:326-332`) — but the entire section is gated by `if !earmarkStore.visibleEarmarks.isEmpty` (line 156), so a user with no earmarks never sees the header or its `+`.
2. The `\.newEarmarkAction` focused-scene action — only reachable via the macOS menu bar.
3. `EarmarksView`'s own `+` toolbar button — orphaned; the view is not registered in `SidebarSelection` and is unreferenced outside its own `#Preview`.

On iOS, none of (1)–(3) are reachable from the empty state, so a fresh user is stuck. On macOS the menu bar (2) works, but a sidebar-local create affordance disappears with the section.

## Goal

Always provide a discoverable "create earmark" affordance, on both platforms, regardless of whether earmarks exist yet.

## Non-Goals

- Wire up the orphaned `EarmarksView`. That is a separate decision.
- Change how editing works. `EarmarkDetailView` already has an "Edit" `.primaryAction` toolbar button (`Features/Earmarks/Views/EarmarkDetailView.swift:66-72`) reachable on both platforms after navigating to an earmark from the sidebar.
- Change `New Account` button or any other sidebar entry.

## Design

All changes are confined to `Features/Navigation/SidebarView.swift`.

### 1. Always render the Earmarks section

Drop the `if !earmarkStore.visibleEarmarks.isEmpty { ... }` guard at line 156. The `Section` always renders, with:

- `ForEach(earmarkStore.visibleEarmarks)` — empty when there are no earmarks (renders nothing, no row).
- `totalRow(label: "Earmarked Total", value: earmarkStore.convertedTotalBalance)` — always renders.
- `sectionHeader(title: "Earmarks", addAction: addEarmarkAction)` — always renders.

This matches the always-visible behaviour of `currentAccountsSection`.

### 2. macOS toolbar "New Earmark" button

Add a second `ToolbarItem(placement: .primaryAction)` to the existing `#if os(macOS)` toolbar block (lines 81-92), alongside "New Account":

```swift
ToolbarItem(placement: .primaryAction) {
  Button {
    showCreateEarmarkSheet = true
  } label: {
    Label("New Earmark", systemImage: "bookmark.fill")
  }
  .help("Create new earmark")
}
```

`bookmark.fill` is chosen because:

- It is the established earmark glyph in this app (sidebar rows at `SidebarView.swift:161`, empty-state at `EarmarksView.swift:164`).
- It distinguishes the button from `New Account` (`plus`).
- `bookmark.badge.plus` was investigated and does not exist in the SF Symbols set available on macOS 26.

`showCreateEarmarkSheet` already exists at line 26 and is already wired to `CreateEarmarkSheet` at lines 99-109 — no new state, no new sheet.

### 3. iOS section-header `+` — unchanged

The existing `sectionHeader(title:addAction:)` helper (lines 322-334) renders an iOS-only `+` button. With the section always visible (change 1), this button is now reachable from the empty state. No code change needed.

### 4. Editing — unchanged

`EarmarkDetailView` already has an "Edit" button (`EarmarkDetailView.swift:66-72`). On iOS the sidebar's per-earmark `NavigationLink` opens this view; on macOS the same navigation feeds the detail column. Both platforms can edit any existing earmark today. No change needed.

## Edge Cases

- **All earmarks hidden.** `visibleEarmarks` filters out hidden earmarks; if the user has earmarks but all are hidden, the section will appear "empty" today and would appear "empty with header" after the change. Same fix; same behaviour as no earmarks.
- **`Earmarked Total` when empty.** `EarmarkStore.convertedTotalBalance` is `nil` briefly during initial observation, then resolves to `.zero(...)` once the earmark stream emits. The existing `totalRow(...)` shows a `ProgressView` for `nil` and the formatted amount otherwise — both are acceptable in the empty case.
- **Available Funds row** (`SidebarView.swift:192-213`) only renders when `earmarkedTotal.isPositive`. With zero earmarks this is `.zero` (not positive), so the row stays hidden — correct behaviour, no change.
- **`onMove` on an empty `ForEach`.** SwiftUI handles this without crashing; the gesture is simply unreachable.
- **macOS toolbar overflow.** Two `.primaryAction` items (`New Account`, `New Earmark`) at narrow window widths — the system collapses overflow into a `›` menu automatically. Verify visually but no special handling required.

## Risks

- **Visual noise from an always-empty section.** Acceptable. `Earmarked Total: 0` (or `ProgressView`) above an empty list is symmetrical with `Current Total` in `currentAccountsSection`, which behaves the same way in the (rare) zero-account state.
- **Two toolbar buttons on macOS.** A second `+` would have been confusing; `bookmark.fill` distinguishes them clearly. The buttons are also separable via `.help(...)` tooltips.

## Testing

- **Manual.** Launch macOS app with a profile that has zero earmarks; confirm the toolbar "New Earmark" button appears, opens `CreateEarmarkSheet`, creates an earmark, and the new row appears in the sidebar.
- **Manual (iOS).** Run iOS Simulator with a profile that has zero earmarks; confirm the "Earmarks" header and `+` are visible in the sidebar, opens `CreateEarmarkSheet`, creates an earmark, and the new row appears.
- **Preview.** `SidebarView`'s `#Preview` (line 351-377) seeds one earmark; add a second preview seeded with zero earmarks to validate the empty-section header rendering visually.
- **No new XCUITest.** The existing earmark create-sheet flow is covered by the create/edit store tests (`EarmarkStoreMutationTests`); the change here is structural sidebar rendering, not new behaviour.

## Acceptance Criteria

1. With zero earmarks on iOS, the sidebar shows an "Earmarks" section header with a tappable `+` that opens `CreateEarmarkSheet`.
2. With zero earmarks on macOS, the sidebar's toolbar shows a "New Earmark" button (icon `bookmark.fill`, tooltip "Create new earmark") that opens `CreateEarmarkSheet`.
3. The `Earmarked Total` row renders in the empty state on both platforms.
4. With one or more earmarks, behaviour is unchanged (rows render, totals correct, section header `+` on iOS, macOS toolbar still shows both `New Account` and `New Earmark`).
5. `Available Funds` row continues to be gated by `earmarkedTotal.isPositive` (no regression for zero-earmark users).
