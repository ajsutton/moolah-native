# Earmark Creation Bootstrap Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Surface a discoverable "create earmark" affordance on both iOS and macOS regardless of whether earmarks exist yet.

**Architecture:** Two structural changes to `Features/Navigation/SidebarView.swift` — drop the empty-state guard on the Earmarks section so its iOS section-header `+` is always reachable, and add a macOS toolbar `New Earmark` button (icon `bookmark.fill`) alongside the existing `New Account` button. Wires through the already-present `showCreateEarmarkSheet` state and `CreateEarmarkSheet` sheet (lines 26 and 99-109 of `SidebarView.swift` today). Adds a stable accessibility identifier on the new toolbar button for parity with `newAccountButton`.

**Tech Stack:** SwiftUI (iOS 26+ / macOS 26+), Xcode 26, Swift 6 concurrency, `just` task runner. Validation via Xcode `#Preview` rendered through `mcp__xcode__RenderPreview` and `just build-mac` / `just format-check`.

**Spec:** `plans/2026-05-09-earmark-creation-bootstrap-design.md`

---

## File Structure

**Modified:**
- `UITestSupport/UITestIdentifiers.swift` — add `Sidebar.newEarmarkButton` constant.
- `Features/Navigation/SidebarView.swift` — drop empty-state guard, add macOS toolbar button, add empty-state preview.

**Not modified:** No tests, no view models, no schema. The change is pure SwiftUI structure inside one view; the existing `EarmarkStore`, `CreateEarmarkSheet`, `EditEarmarkSheet`, and `EarmarkDetailView` are unchanged. Per the spec's "No new XCUITest" decision, we pin a stable identifier on the new button so a future test can address it without further view changes, but no test is added in this plan.

---

## Task 1: Verify baseline is clean

Confirm the worktree builds and passes format-check before any change, so any later failure is attributable to this work.

**Files:** none (verification only).

- [ ] **Step 1.1: Run format-check on the working tree**

Run from the worktree root:

```bash
just format-check
```

Expected: exit code 0, no diff. If it reports drift, stop and report — the worktree was created from `origin/main`, so a dirty result means a CI baseline drift unrelated to this plan.

- [ ] **Step 1.2: Build macOS to confirm a clean baseline**

```bash
mkdir -p .agent-tmp
just build-mac 2>&1 | tee .agent-tmp/build-baseline.txt
```

Expected: `BUILD SUCCEEDED`, no warnings (recall `SWIFT_TREAT_WARNINGS_AS_ERRORS: YES`). If the build fails, stop and report — fixing pre-existing breakage is not in scope.

- [ ] **Step 1.3: Clean up the baseline log**

```bash
rm .agent-tmp/build-baseline.txt
```

(Nothing to commit; this task is verification only.)

---

## Task 2: Add `newEarmarkButton` test identifier

Add the constant the macOS toolbar button will pin in Task 3, in the same file and same shape as the existing `newAccountButton`.

**Files:**
- Modify: `UITestSupport/UITestIdentifiers.swift:35` (add a new constant directly after `newAccountButton`).

- [ ] **Step 2.1: Add the constant**

Open `UITestSupport/UITestIdentifiers.swift`. Find this block (currently lines 34-35):

```swift
    /// "New Account" toolbar button in the sidebar (macOS only).
    public static let newAccountButton = "sidebar.toolbar.newAccount"
```

Add a sibling constant immediately below it (before the `editAccountContextMenuItem` declaration):

```swift
    /// "New Earmark" toolbar button in the sidebar (macOS only). Pinned for
    /// symmetry with `newAccountButton` so a future UI test can drive the
    /// create-earmark flow from a zero-earmark seed without further view
    /// changes. No test references this constant yet.
    public static let newEarmarkButton = "sidebar.toolbar.newEarmark"
```

Final ordering inside `enum Sidebar` (top to bottom): `account(_:)`, `view(_:)`, `newAccountButton`, `newEarmarkButton`, `editAccountContextMenuItem`. The two `*Button` constants live next to each other.

- [ ] **Step 2.2: Build and format-check**

```bash
just format-check && just build-mac 2>&1 | tail -20
```

Expected: format-check passes; build succeeds with no new warnings. The constant is unreferenced yet — Swift does not warn on unused `static let` declarations on a `public enum` so the build will be warning-free.

- [ ] **Step 2.3: Commit**

```bash
git -C $(pwd) add UITestSupport/UITestIdentifiers.swift
git -C $(pwd) commit -m "$(cat <<'EOF'
feat(ui-test-ids): pin newEarmarkButton sidebar toolbar identifier

Add UITestIdentifiers.Sidebar.newEarmarkButton in symmetry with
newAccountButton so the macOS sidebar's upcoming "New Earmark" toolbar
button has a stable hook for future UI tests. Constant is unreferenced
on its own; the production view consumes it in the next commit.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Always render the Earmarks section + add macOS toolbar button

Drop the empty-state guard so the iOS section-header `+` is reachable from a fresh state, and add the macOS `New Earmark` toolbar button alongside `New Account`.

**Files:**
- Modify: `Features/Navigation/SidebarView.swift:80-92` (extend the macOS `.toolbar` block).
- Modify: `Features/Navigation/SidebarView.swift:155-174` (drop the `if !earmarkStore.visibleEarmarks.isEmpty` guard).

- [ ] **Step 3.1: Add the macOS "New Earmark" toolbar button**

In `Features/Navigation/SidebarView.swift`, find the `#if os(macOS)` toolbar block. Today it is:

```swift
    #if os(macOS)
      .toolbar {
        ToolbarItem(placement: .primaryAction) {
          Button {
            showCreateAccountSheet = true
          } label: {
            Label("New Account", systemImage: "plus")
          }
          .help("Create new account")
          .accessibilityIdentifier(UITestIdentifiers.Sidebar.newAccountButton)
        }
      }
    #endif
```

Add a second `ToolbarItem` inside the same `.toolbar { ... }` closure, immediately after the existing one:

```swift
    #if os(macOS)
      .toolbar {
        ToolbarItem(placement: .primaryAction) {
          Button {
            showCreateAccountSheet = true
          } label: {
            Label("New Account", systemImage: "plus")
          }
          .help("Create new account")
          .accessibilityIdentifier(UITestIdentifiers.Sidebar.newAccountButton)
        }
        ToolbarItem(placement: .primaryAction) {
          Button {
            showCreateEarmarkSheet = true
          } label: {
            Label("New Earmark", systemImage: "bookmark.fill")
          }
          .help("Create new earmark")
          .accessibilityIdentifier(UITestIdentifiers.Sidebar.newEarmarkButton)
        }
      }
    #endif
```

Notes:
- `showCreateEarmarkSheet` is already declared as `@State private var` at line 26 — no new state.
- The sheet binding at lines 99-109 already presents `CreateEarmarkSheet` when this flag flips, so wiring is complete.
- `bookmark.fill` is the icon (verified to exist on macOS 26; `bookmark.badge.plus` does not).

- [ ] **Step 3.2: Drop the empty-state guard on `earmarksSection`**

Find `earmarksSection` (today at lines 155-174):

```swift
  @ViewBuilder private var earmarksSection: some View {
    if !earmarkStore.visibleEarmarks.isEmpty {
      Section {
        ForEach(earmarkStore.visibleEarmarks) { earmark in
          NavigationLink(value: SidebarSelection.earmark(earmark.id)) {
            SidebarRowView(
              icon: "bookmark.fill", name: earmark.name,
              amount: earmarkStore.convertedBalance(for: earmark.id),
              isSelected: selection == .earmark(earmark.id))
          }
        }
        .onMove { source, destination in
          Task { await earmarkStore.reorderEarmarks(from: source, to: destination) }
        }
        totalRow(label: "Earmarked Total", value: earmarkStore.convertedTotalBalance)
      } header: {
        sectionHeader(title: "Earmarks", addAction: addEarmarkAction)
      }
    }
  }
```

Replace it with the unguarded form:

```swift
  private var earmarksSection: some View {
    Section {
      ForEach(earmarkStore.visibleEarmarks) { earmark in
        NavigationLink(value: SidebarSelection.earmark(earmark.id)) {
          SidebarRowView(
            icon: "bookmark.fill", name: earmark.name,
            amount: earmarkStore.convertedBalance(for: earmark.id),
            isSelected: selection == .earmark(earmark.id))
        }
      }
      .onMove { source, destination in
        Task { await earmarkStore.reorderEarmarks(from: source, to: destination) }
      }
      totalRow(label: "Earmarked Total", value: earmarkStore.convertedTotalBalance)
    } header: {
      sectionHeader(title: "Earmarks", addAction: addEarmarkAction)
    }
  }
```

Two diffs:
1. Remove `@ViewBuilder` (no longer required — the body returns a single `Section` unconditionally rather than a conditional `if`).
2. Remove the `if !earmarkStore.visibleEarmarks.isEmpty { ... }` wrapper; the `Section` always renders.

- [ ] **Step 3.3: Format and build**

```bash
just format && just build-mac 2>&1 | tail -20
```

Expected: `just format` may rewrite layout but should not error. Build prints `BUILD SUCCEEDED` with no warnings.

- [ ] **Step 3.4: List Xcode navigator issues**

Use the Xcode MCP tool to confirm there are no warnings introduced anywhere in the project (per CLAUDE.md pre-commit checklist):

Call: `mcp__xcode__XcodeListNavigatorIssues` with `{ "severity": "warning" }`.

Expected: zero warnings in user code (Preview macro warnings from `#Preview` are acceptable per CLAUDE.md and can be ignored).

- [ ] **Step 3.5: Commit**

```bash
git -C $(pwd) add Features/Navigation/SidebarView.swift
git -C $(pwd) commit -m "$(cat <<'EOF'
feat(sidebar): always show Earmarks section and add macOS create toolbar

Drops the empty-state guard on the sidebar's Earmarks section so the
iOS section-header "+" button is reachable from a fresh state (a user
with zero earmarks now sees the section header and can create the
first one). Adds a macOS "New Earmark" toolbar button alongside the
existing "New Account" button, distinguished by the bookmark.fill icon
so the two are clearly separable. Wires to the existing
showCreateEarmarkSheet binding and CreateEarmarkSheet sheet, so no new
state or presentation logic is introduced.

Closes the discoverability gap captured in
plans/2026-05-09-earmark-creation-bootstrap-design.md.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Add an empty-earmarks `#Preview` for visual validation

The existing `SidebarView` `#Preview` (lines 351-377) seeds one earmark; add a second preview that seeds zero earmarks so the empty-state header rendering is visually inspectable in the Xcode canvas and via the `mcp__xcode__RenderPreview` MCP tool.

**Files:**
- Modify: `Features/Navigation/SidebarView.swift` (append a second `#Preview`).

- [ ] **Step 4.1: Add the empty-state preview**

Find the existing `#Preview` block at the bottom of `SidebarView.swift` (today at lines 351-377). Add a second `#Preview` immediately after it:

```swift
#Preview("Empty earmarks") {
  let (backend, _) = PreviewBackend.create()
  let accountStore = AccountStore(
    repository: backend.accounts,
    conversionService: backend.conversionService,
    targetInstrument: .AUD)
  let earmarkStore = EarmarkStore(
    repository: backend.earmarks,
    conversionService: backend.conversionService,
    targetInstrument: .AUD)
  // In-memory preview session can't fail in practice: opens an ephemeral
  // GRDB queue with no disk access. A trap here is acceptable in #Preview.
  // swiftlint:disable:next force_try
  let session = try! ProfileSession.preview()

  return NavigationSplitView {
    SidebarView(selection: .constant(nil))
      .environment(accountStore)
      .environment(earmarkStore)
      .environment(session)
      .task {
        // Seed only an account — no earmarks. Validates that the
        // Earmarks section header (and its iOS "+" button) renders in
        // the empty-state, and that the macOS toolbar shows both the
        // "New Account" and "New Earmark" buttons.
        _ = try? await backend.accounts.create(
          Account(name: "Bank", type: .bank, instrument: .AUD),
          openingBalance: InstrumentAmount(quantity: 1000, instrument: .AUD))
      }
  } detail: {
    Text("Detail")
  }
}
```

Both previews use the same `ProfileSession.preview()` / `PreviewBackend.create()` pattern as the original — no new helper.

- [ ] **Step 4.2: Render the empty-earmarks preview via the Xcode MCP tool**

Call `mcp__xcode__RenderPreview` to render the new preview by name `"Empty earmarks"` for `SidebarView.swift`. Inspect the rendered image and confirm:
1. An "Earmarks" section header is visible.
2. An "Earmarked Total" row renders below the header (with `0` or a `ProgressView` — both acceptable).
3. (macOS rendering only) Two toolbar buttons are present: `+` (New Account) and `bookmark.fill` (New Earmark).

If any of those is missing, stop and report. Do not modify the design without going back to the user — the design fixed those acceptance criteria.

- [ ] **Step 4.3: Format and build**

```bash
just format && just build-mac 2>&1 | tail -20
```

Expected: format-check passes; build succeeds.

- [ ] **Step 4.4: Commit**

```bash
git -C $(pwd) add Features/Navigation/SidebarView.swift
git -C $(pwd) commit -m "$(cat <<'EOF'
test(sidebar): add empty-earmarks #Preview for empty-state validation

Adds a second SidebarView #Preview that seeds an account but no
earmarks, so the empty-state Earmarks section header (with its iOS "+"
button) and the macOS "New Earmark" toolbar button render together in
the Xcode canvas. Used as the visual smoke check for the
earmark-creation-bootstrap change.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Final verification

Run the full build and format pipeline one more time to confirm the three commits land cleanly.

**Files:** none.

- [ ] **Step 5.1: Format-check across the worktree**

```bash
just format-check
```

Expected: exit code 0, no diff.

- [ ] **Step 5.2: Build macOS**

```bash
mkdir -p .agent-tmp
just build-mac 2>&1 | tee .agent-tmp/build-final.txt
```

Expected: `BUILD SUCCEEDED`, zero warnings (preview-macro warnings excepted).

- [ ] **Step 5.3: Build iOS**

```bash
just build-ios 2>&1 | tee .agent-tmp/build-ios.txt | tail -10
```

Expected: `BUILD SUCCEEDED`. The change touches `#if os(macOS)` and a `@ViewBuilder` removal — both are compiled by the iOS target through the same source file, so an iOS build is needed to catch any iOS-only fallout (e.g., the `@ViewBuilder` removal compiling differently in the iOS slice).

- [ ] **Step 5.4: Confirm git log**

```bash
git -C $(pwd) log --oneline origin/main..HEAD
```

Expected: three commits in order:
1. `feat(ui-test-ids): pin newEarmarkButton sidebar toolbar identifier`
2. `feat(sidebar): always show Earmarks section and add macOS create toolbar`
3. `test(sidebar): add empty-earmarks #Preview for empty-state validation`

- [ ] **Step 5.5: Clean up agent-tmp**

```bash
rm -f .agent-tmp/build-final.txt .agent-tmp/build-ios.txt
```

---

## Out of Scope

- **No XCUITest.** The spec deferred this. The `newEarmarkButton` identifier is pinned so a follow-up plan can add a test without re-touching production code.
- **No `EarmarksView` wiring.** Still orphaned after this plan; that's a separate decision.
- **No change to `New Account` button or any other sidebar element.**
- **No refactor of `sectionHeader(title:addAction:)`.** Its existing iOS-only `+` is now reachable; no change needed.

## Acceptance Criteria (from the design)

1. **iOS empty state:** Sidebar shows an "Earmarks" header with a tappable `+` that opens `CreateEarmarkSheet`. ✅ Validated via the empty-earmarks `#Preview` (Step 4.2) on the iOS canvas.
2. **macOS empty state:** Sidebar toolbar shows a "New Earmark" button (icon `bookmark.fill`, tooltip "Create new earmark") that opens `CreateEarmarkSheet`. ✅ Validated via the same preview, and via the build success in Steps 3.3 and 5.2 (toolbar is `#if os(macOS)`).
3. **`Earmarked Total` renders in empty state on both platforms.** ✅ Validated via the empty-earmarks `#Preview`.
4. **Behaviour with one or more earmarks is unchanged.** ✅ Validated via the original `#Preview` (lines 351-377) which seeds one earmark.
5. **`Available Funds` row remains gated by `earmarkedTotal.isPositive`.** ✅ No change to that code path; the gating logic at lines 192-213 is untouched.
