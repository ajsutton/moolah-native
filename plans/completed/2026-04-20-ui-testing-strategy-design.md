# UI Testing Strategy Design

**Date:** 2026-04-20
**Status:** Proposed
**Supersedes:** `plans/completed/UI_TESTING_PLAN.md` Part B (XCUITest), which was abandoned after an earlier attempt failed

## Goal

Reliable automated coverage for interactive UI in `TransactionDetailView` (the view that handles trades via multi-leg transactions since the removal of `RecordTradeView`), focused on the failure classes currently felt manually:

- Wrong `@FocusState` after state changes.
- Autocomplete popups showing or hiding at the wrong times.
- Keyboard navigation (arrow keys, Return, Escape) not producing the expected behaviour.

Store-level tests (`MoolahTests_macOS`) validate business logic but cannot exercise the real SwiftUI event loop, focus system, or overlay-positioned autocomplete dropdowns. This design closes that gap with XCUITest — but treats the previous attempt's failure as an infrastructure problem rather than a tool-choice problem.

## Non-goals (for v1)

- Full-app UI coverage.
- iOS UI tests. iOS-specific behaviour (decimal keyboard, swipe delete, navigation stack) is covered manually or by future additions.
- Visual / pixel snapshot regression testing.
- Replacing store-level tests. Those remain the first line of defence.

## Scope (v1 test suite)

Six tests, all targeting `TransactionDetailView`:

1. Opening a simple trade focuses the payee field (or amount when the draft is earmark-only).
2. Typing into payee shows the autocomplete dropdown; clearing it hides the dropdown.
3. Arrow-down then Return selects the highlighted suggestion and closes the dropdown.
4. Escape clears the payee text and closes the dropdown.
5. In multi-leg mode, typing in one leg's category field shows only that leg's dropdown, not any other leg's.
6. Switching a transfer to cross-currency reveals the counterpart amount field and its instrument label.

**Success criterion:** the six tests pass 20 consecutive runs locally with no retries; suite completes in under 60 seconds.

## Platform

macOS only. No simulator. One test target, one scheme, one `just` target.

## Why the previous attempt failed (and what changes)

The earlier XCUITest effort ran aground when an agent could not reliably click sidebar account rows. Two root causes:

1. **No stable `accessibilityIdentifier`s.** Views rely on `accessibilityLabel` (for VoiceOver) but have almost no identifiers for test targeting. Text-based element finding is fragile in SwiftUI `List`s where the accessibility tree is deep and inconsistent across OS versions.
2. **No introspection during failures.** When a click missed, the agent had no way to see what was actually in the accessibility tree and spiralled guessing, rather than debugging against reality.

This design addresses both directly: an identifier discipline plus a failure-artefact regime that makes the tree visible to both humans and agents.

## Architecture

### Test target

`MoolahUITests_macOS` — `bundle.ui-testing` target in `project.yml`, depends on `Moolah_macOS`, runs via a dedicated scheme (`Moolah-macOS-UITests`) and a `just test-ui` target. Output captured to `.agent-tmp/test-ui-output.txt` following existing conventions.

### Deterministic seed via `--ui-testing` launch arg

When `CommandLine.arguments.contains("--ui-testing")`, the app:

- Uses `TestBackend` (`CloudKitBackend` + in-memory `ModelContainer`) for fast, network-free test runs.
- Skips sync, telemetry, and login flows. A profile is pre-seeded as signed-in.
- Reads a seed name from `ProcessInfo.processInfo.environment["UI_TESTING_SEED"]` and hydrates the backend from `UITestSeeds` with fixed-UUID fixtures.

### Shared `UITestSupport` module

Added to both the main app and the UI test target via `project.yml` sources:

```
UITestSupport/
  UITestSeeds.swift         // named seed definitions with hard-coded UUIDs
  UITestIdentifiers.swift   // identifier string constants
```

Both sides reference the same constants, so there is one place to change them. The main app file size cost is trivial (fixture data compiled but only executed when the launch arg is set).

### Accessibility identifier discipline

One-time pass adding `.accessibilityIdentifier(_:)` to every element a test needs to target. Naming format `area.element[.id]`, centralised in `UITestIdentifiers.swift`:

```
sidebar.account.<uuid>
sidebar.view.<name>                       // e.g. "upcoming", "analysis"

detail.payee
detail.amount
detail.category
detail.date
detail.leg.<legIndex>.category
detail.leg.<legIndex>.amount
detail.leg.<legIndex>.account
detail.toolbar.save
detail.toolbar.delete

autocomplete.payee                         // dropdown container
autocomplete.payee.suggestion.<index>
autocomplete.category.suggestion.<index>
autocomplete.leg.<legIndex>.category.suggestion.<index>
```

`accessibilityLabel` calls remain for VoiceOver; identifiers are a separate, test-facing concern. Identifiers are added incrementally — only what the current tests need — not via an app-wide pass.

### `MoolahUITestCase` base + debug helpers

Every UI test inherits this. Responsibilities:

- `setUp` launches `XCUIApplication()` with `--ui-testing` and the per-test seed env var.
- `tearDown` on failure attaches four artefacts (see [Failure artefacts](#failure-artefacts)).
- Exposes low-level primitives used internally by drivers: `waitForIdentifier(_:timeout:)`, `assertFocused(_:)`, `typeInto(_:text:)`, `pressKey(_:modifiers:)`. Element resolution lives on `MoolahApp` (see [Screen-driver pattern](#screen-driver-pattern)). Tests never call any of these directly.

## Screen-driver pattern

**Inviolable rule:** test files reference only `XCTest`. No `XCUIApplication`, no `XCUIElement`, no `XCUIElementQuery`, no raw identifier strings. Tests call helper methods on typed screen-driver objects and nothing else. The reviewer agent enforces this mechanically.

### Driver hierarchy

```
MoolahApp                          // owns XCUIApplication; launches with seed
├── sidebar           → SidebarScreen
├── transactionList   → TransactionListScreen
├── transactionDetail → TransactionDetailScreen
│     ├── payee        → AutocompleteFieldDriver
│     ├── amount       → AmountFieldDriver
│     ├── category     → AutocompleteFieldDriver
│     ├── date         → DatePickerDriver
│     └── leg(_:)      → LegSectionDriver (.category, .amount, .account)
└── dialogs           → DialogScreen        // error alerts, delete confirmations
```

### Two method kinds per driver

- **Actions** (imperative verbs): perform a thing and wait for the post-condition before returning. When an action returns, the UI is in a known state.
- **Expectations** (`expect…` verbs): assert current state, no mutation.

No getters return raw values to the test. If a test needs to know "payee equals X", it calls `app.transactionDetail.payee.expectValue("X")`.

### Driver invariants (the contract)

Every driver method upholds these:

1. **Actions wait for post-conditions.** `switchToAccount(_:)` does not return until the transaction list has re-rendered for that account. `type(_:)` does not return until the text binding has propagated.
2. **Actions fail loudly.** If a precondition fails (e.g. sidebar not visible), the driver calls `XCTFail(...)` with the failure artefacts already attached — no silent no-ops.
3. **Expectations never mutate.** Read-only assertion methods.
4. **Single element resolver.** All identifier lookups go through `MoolahApp.element(for:)` so there is one place to add logging.
5. **Stateless from the test's perspective.** Drivers re-resolve elements on each call; no caching, no stale references after re-render.
6. **First line logs to the trace.** Every action method begins with `Trace.record(#function, ...)` so failure traces show which actions ran.

### Test style (user stories)

Tests read as user stories, comprehensible to a non-Swift reader:

```swift
func testArrowDownEnterSelectsPayeeSuggestion() {
  let app = MoolahApp.launch(seed: .tradeBaseline)
  app.sidebar.switchToAccount(.checking)
  app.transactionList.openTransaction(.coffeeShop)

  app.transactionDetail.payee.type("Woo")
  app.transactionDetail.payee.expectSuggestionsVisible(count: 2)
  app.transactionDetail.payee.pressArrowDown()
  app.transactionDetail.payee.expectHighlightedSuggestion(at: 0)
  app.transactionDetail.payee.pressEnter()

  app.transactionDetail.payee.expectValue("Woolworths")
  app.transactionDetail.payee.expectSuggestionsHidden()
}
```

### What goes where

- Multi-step UI sequences ("type, wait for dropdown, arrow-down, enter") → **driver**.
- Post-condition checks that belong to an action's definition ("list reloaded after account switch") → **driver** (the action would have failed otherwise; the test does not repeat the check).
- Scenario-specific assertions ("transaction is for Woolworths, $4.50") → **test**, via `expect…` driver methods.

**Rule of thumb:** if two tests need the same multi-step sequence, it belongs in a driver. Tests are compositions of driver calls, never of XCUI primitives.

## Failure artefacts

On any UI test failure, `MoolahUITestCase.tearDown` attaches four files to the test result and mirrors them to `.agent-tmp/ui-fail-<TestName>/` for direct inspection without spelunking `.xcresult` bundles:

1. **`tree.txt`** — custom accessibility-tree dump. One element per line, indented by depth, columns: `identifier | type | label | value | frame | focused?`. More compact and more useful than `XCUIApplication.debugDescription`, which omits identifiers when empty and is not diff-friendly. This is the single most important artefact — it shows exactly which identifiers exist at the moment of failure.
2. **`screenshot.png`** — the full app window.
3. **`seed.txt`** — the seed name and the fixtures (UUIDs, names, amounts, dates) the test started from. Lets the reader correlate expected vs. actual state.
4. **`trace.txt`** — breadcrumb of every driver action called in the test, in order, with `✓` / `✗` marks. Recorded by `Trace.record(...)` at the top of each action method.

### Agent debugging loop (codified in the guide)

When a UI test fails:

1. Run only that test: `just test-ui <ClassName>/<testName> 2>&1 | tee .agent-tmp/test-ui.txt`.
2. Read `.agent-tmp/ui-fail-<TestName>/trace.txt` to find the first failing action.
3. Read `.agent-tmp/ui-fail-<TestName>/tree.txt` to see which identifiers actually exist at that point.
4. Fix at the right layer:
   - Missing identifier → add via `UITestIdentifiers.swift` and the view.
   - Seed state wrong → fix the seed.
   - Driver post-condition wrong → fix the driver's wait.
   - Genuine product change → update the driver, never the test.
5. Never modify the test to work around a failure.

### No retries, no sleeps, no "flaky" flag

- All waits are explicit, bounded (default 3 s), and target a post-condition the driver knows about.
- No `Thread.sleep`, no `DispatchQueue.main.asyncAfter` in drivers or tests.
- A test that fails intermittently is a driver bug. Fix the driver's post-condition, do not retry.
- Reviewer agent flags any occurrence of sleeps, unbounded waits, or retry mechanisms.

## Guides, skill, and reviewer agent

### Two guides

**`guides/TEST_GUIDE.md`** — generic test discipline for every test in the repo:

- Tests read as user stories. One behaviour per test. Plain-English names.
- No `sleep`, no unbounded timeouts. Waits target post-conditions.
- No retries, no "known-flaky" flag. Flaky = broken.
- No test-only branches in production code. Test modes gated by explicit launch args / env vars, not `#if DEBUG` scattered through logic.
- TDD order for store-level tests remains the convention.
- Failing tests produce self-sufficient artefacts — readers do not re-run to understand failures.

**`guides/UI_TEST_GUIDE.md`** — UI-specific add-on, cross-references `TEST_GUIDE.md`:

- Screen-driver rule (tests import only `XCTest`; no raw identifier strings; extend drivers when needed).
- Driver invariants (trace-first line, post-condition waits, loud failures, no element caching).
- Identifier conventions and registry.
- Seed registry (fixed UUIDs, how to add new seeds).
- Failure artefacts and the debugging loop.
- How to add a new screen driver (file location, required methods, checklist).

### Skill: `writing-ui-tests`

Fires proactively when an agent is editing files in `MoolahUITests_macOS/Tests/`, adding a UI test for a view, or fixing a failing UI test. The skill body (short — the guide holds detail):

1. Read `guides/TEST_GUIDE.md` and `guides/UI_TEST_GUIDE.md`.
2. Decide whether a UI test is warranted. If the logic can be tested at the store level, do that instead and stop.
3. Identify the screen driver(s). If a needed method is missing, extend the driver first — with the required trace log and post-condition wait — and only then write the test.
4. Identify the seed. Reuse an existing one; otherwise add to `UITestSeeds.swift` with fixed UUIDs.
5. Write the test as a user story: launch + seed → driver actions → driver expectations. No XCUI*.
6. Run in isolation (`just test-ui <TestName>`). On failure, read `.agent-tmp/ui-fail-*/` artefacts and fix the right layer — never the test.
7. Run three times locally before committing. Divergence is a driver bug, not a flake.

### Reviewer agent: `ui-test-review`

Added under `.claude/agents/ui-test-review.md` alongside existing review agents. Enforces the guide mechanically.

**In test files** (`MoolahUITests_macOS/Tests/**/*.swift`):
- Only `XCTest` is imported from UI-test frameworks; `XCUIElement`, `XCUIApplication`, `XCUIElementQuery` not referenced.
- No raw identifier-like string literals (regex: `"[a-z]+\.[a-z]+(\.[^"]+)?"`).
- Class inherits `MoolahUITestCase`.
- Test bodies call only driver methods — no `.buttons[…]`, `.exists`, `.waitForExistence`.

**In driver files** (`MoolahUITests_macOS/Helpers/Screens/**`, `.../Fields/**`):
- Every action method starts with `Trace.record(#function, ...)`.
- Every action method contains at least one bounded wait, or delegates to another driver action that does.
- No `sleep`, `Thread.sleep`, `DispatchQueue.main.asyncAfter`, or unbounded timeouts.
- Element lookups go through `MoolahApp.element(for:)`.

**In view files** (main app):
- Every `.accessibilityIdentifier(…)` call uses a `UITestIdentifiers` constant, not an inline literal.
- Identifiers match the namespace regex.

**In seed files** (`UITestSupport/UITestSeeds.swift`):
- UUIDs are hard-coded constants, not generated.
- Every seed is referenced by at least one test (else dead).

**Escape hatch.** A `// ui-test-review: allow <rule> — <reason>` comment skips a rule with PR justification, following the SwiftLint exception pattern. The guide notes these are exceptional.

**Possible future split.** If the reviewer's output gets noisy, spin off a focused `ui-test-trace-review` agent that only checks the trace/logging discipline. One agent to start.

## Rollout order

1. Land this design doc (PR).
2. Implement `guides/TEST_GUIDE.md` and `guides/UI_TEST_GUIDE.md`.
3. Add the reviewer agent `.claude/agents/ui-test-review.md`.
4. Add the `writing-ui-tests` skill.
5. Add `MoolahUITests_macOS` target + `UITestSupport/` module (seeds, identifiers).
6. Add the `--ui-testing` launch arg handling to the app.
7. Add `MoolahUITestCase` + failure-artefact infrastructure + first driver scaffold (`MoolahApp`, `SidebarScreen`, `TransactionListScreen`, `TransactionDetailScreen`, `AutocompleteFieldDriver`).
8. Write the first test (opening a trade focuses payee). Run 20 consecutive times. Only expand once stable.
9. Add the remaining five tests, extending drivers and identifiers as needed, running the reviewer agent after each.
10. CI integration — add UI test step to the macOS workflow once the suite is stable locally.

## Open questions

None at spec time. Decisions made during brainstorming:

- Platform: macOS only (v1).
- Scope: six tests on `TransactionDetailView`.
- Single reviewer agent to start; split if noisy.
- Shared `UITestSupport` module compiled into both app and test targets.
- Launch-arg detection in `MoolahApp`, not a separate build config.
- Identifiers added incrementally; no app-wide pass.
