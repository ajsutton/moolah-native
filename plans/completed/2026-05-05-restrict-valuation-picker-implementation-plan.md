# Implementation plan — restrict Edit Account valuation picker

**Companion to:** `plans/2026-05-05-restrict-valuation-picker-design.md`.
**Date:** 2026-05-05.
**Owner:** Adrian.

## How to read this plan

The work is split into five independent or sequenced stages. Each
stage is small enough to land as a single PR (or a single commit on a
combined branch), and each ends with reviewer-verifiable acceptance
criteria so progress is checkable without running the app.

Dependency graph:

```
Stage 1 (Model text)        ────┐
                                 ├──▶ Stage 3 (View wiring)
Stage 2 (Resolver + tests)  ────┘                            ╲
                                                              ▶  Stage 5 (UI test)
Stage 4 (UI test seed surface)  ─────────────────────────────╱
```

Stages 1, 2, 4 are independent and can run in any order. Stage 3
requires Stages 1 and 2. Stage 5 requires Stages 3 and 4.

Per repo convention, all production work happens in a worktree
(`CLAUDE.md` Git Workflow). Each stage lives on its own feature branch
unless explicitly bundled.

## Pre-flight (every stage)

Before opening a PR for any stage:

1. `just format` (apply swift-format + SwiftLint --fix).
2. `just format-check` clean (CI gate).
3. `just test` clean.
4. `mcp__xcode__XcodeListNavigatorIssues` shows no warnings in user code (project has `SWIFT_TREAT_WARNINGS_AS_ERRORS: YES`).
5. No diff to `.swiftlint-baseline.yml`.

---

## Stage 1 — `ValuationMode` display-text extension

**Branch:** `feat/valuation-mode-display-text`.
**Depends on:** nothing.

### Files

- **New:** `Domain/Models/ValuationMode+DisplayText.swift` — extension
  with `dataSourceHint: String` and `dataSourceDescription: String`.
  Per CLAUDE.md "one extension per protocol/topic" file convention.
- **New:** `MoolahTests/Domain/ValuationModeDisplayTextTests.swift` —
  Swift Testing `@Suite` with two `@Test` methods,
  `dataSourceHint_returnsExpectedString` and
  `dataSourceDescription_returnsExpectedString`.

### Implementation

Verbatim per design §3.4 — use the exact strings from the existing
`EditAccountView.swift:104-114` so the move is behaviour-preserving.
Doc comments per design §3.4.

### Acceptance criteria

- Both new computed properties exist on `ValuationMode` and return
  the strings quoted in design §3.6 / §3.4.
- Both unit tests pass against `swift test` and `just test`.
- No production call site changes yet — Stage 3 will wire the view.
- Pre-flight checklist clean.

### Reviewers

- `code-review` — model naming, doc comments, file location, test
  shape per `TEST_GUIDE.md`.

---

## Stage 2 — `EditAccountView.resolvePickerVisibility` resolver + tests

**Branch:** `feat/edit-account-picker-visibility-resolver`.
**Depends on:** nothing (does not yet wire into the view body).

### Files

- **Modified:** `Features/Accounts/Views/EditAccountView.swift` —
  add the static `PickerVisibility` enum and the static
  `resolvePickerVisibility(accountId:snapshotProbe:)` method per
  design §3.3. Add `private static let logger = Logger(...)`. Do
  **not** yet add the `@State` flags or the `.task` modifier —
  Stage 3 wires those.
- **New:** `MoolahTests/Features/EditAccountVisibilityTests.swift` —
  Swift Testing `@Suite` with the four resolver tests per design
  §5.2 (cases 1–4).

### Implementation order (TDD — strict)

CLAUDE.md "Testing & TDD" rule: write the test file before the
implementation file. Concretely:

1. Create `EditAccountVisibilityTests.swift` with all four `@Test`
   methods. Bodies reference `EditAccountView.resolvePickerVisibility`
   and `PickerVisibility` types that don't exist yet → the test file
   fails to compile.
2. Add `enum PickerVisibility { … }` and the `static func
   resolvePickerVisibility(...)` body in `EditAccountView.swift`,
   stubbed to `fatalError("unimplemented")` (or returning `.hidden`)
   so compilation succeeds and the four tests fail at runtime.
3. Run `just test EditAccountVisibilityTests` (or the equivalent)
   and confirm four red tests.
4. Implement the resolver per design §3.3.
5. Run again — four green tests.

The resolver and `PickerVisibility` enum are nested inside
`EditAccountView` (private to the type, since they have no consumer
outside it). `WelcomeHero.swift` is the precedent for two
private-nested types in a single SwiftUI `View`; SwiftLint's
`nesting type_level: 1` rule allows it (the rule limits depth,
not count, of nested types).

Test bodies pass closure literals as the `snapshotProbe`, no
`TestBackend` needed (the resolver only sees the closure):

```swift
@Test("probeReturnsTrue → .shown")
func probeReturnsTrue_returnsShown() async throws {
  let result = try await EditAccountView.resolvePickerVisibility(
    accountId: UUID(), snapshotProbe: { true })
  #expect(result == .shown)
}
```

### Acceptance criteria

- `EditAccountView.resolvePickerVisibility` and `PickerVisibility`
  compile and are reachable from the test target (project's existing
  `@testable import Moolah` path).
- All four resolver tests pass — verified by `just test
  EditAccountVisibilityTests`.
- Test 3 (`probeThrowsGenericError_returnsShownAfterFailure`)
  passing implicitly proves the `Self.logger.warning(...)` call site
  is reachable, since the warning branch and the `return
  .shownAfterFailure` are in the same `catch` block. No separate
  logger-emission verification required.
- Pre-flight checklist clean.

### Reviewers

- `code-review` — resolver naming, enum shape, error handling,
  thin-view discipline.
- `concurrency-review` — actor isolation of the static method,
  cancellation propagation, `Sendable` on `PickerVisibility`.

---

## Stage 3 — Wire visibility into the Edit Account form

**Branch:** `feat/edit-account-picker-visibility-wiring`.
**Depends on:** Stages 1 and 2.

### Files

- **Modified:** `Features/Accounts/Views/EditAccountView.swift` —
  - Add `@Environment(ProfileSession.self) private var session`.
  - Add `@State private var showValuationPicker: Bool` (initialised
    in `init` to `account.valuationMode == .recordedValue`).
  - Add `@State private var pickerShownDueToProbeFailure: Bool = false`.
  - Replace `valuationSection`'s inline strings with
    `valuationMode.dataSourceHint` and
    `valuationMode.dataSourceDescription` (from Stage 1).
  - Replace inline footer `Text` with the `VStack { Text(…); if …
    Label(…) }` pattern per design §3.4.
  - Add `.task(id: account.id)` body per design §3.3 (guard +
    do/catch with typed `catch is CancellationError`).
  - Update `valuationSection` guard to `if type == .investment,
    showValuationPicker`.
  - Add two new `#Preview` configs per design §5.3 ("no snapshots"
    and "calculatedFromTrades with snapshots"). Existing previews
    unchanged in their bodies but adjust for any environment glue if
    needed.
- **Unchanged (verify):** `Features/Navigation/SidebarView.swift` —
  no call-site changes; `.sheet` propagates ProfileSession from the
  parent environment automatically.

### Implementation

Per design §3.3 + §3.4. Key invariants:

- `.task(id: account.id)` not `.task` — must be id-keyed so it
  doesn't re-fire on field edits.
- The `.task` closure must capture `session.backend.investments` via
  the closure passed to the resolver, not via a stored property —
  the resolver receives only the closure, keeping it pure.
- The `switch` in the `.task` body must be exhaustive (the compiler
  enforces this — no `default:` clause).

**File-organisation note.** After this stage,
`EditAccountView.swift` will be ~300 lines (existing ~170 + ~30 new
state/env + ~30 new `valuationSection` + ~50 new previews +
`PickerVisibility` enum + resolver from Stage 2). At or above 300
lines, `CODE_GUIDE.md` §2 requires `// MARK: - <Section>` headers.
Add at minimum: `// MARK: - State`, `// MARK: - Body`, `// MARK: -
Sections`, `// MARK: - Picker visibility`, `// MARK: - Save`. Adjust
to match what the file naturally divides into.

**Third preview (`shownAfterFailure` state).** In addition to the
two previews from design §5.3 ("no snapshots", "calculatedFromTrades
with snapshots"), add a third preview that renders the fail-open
`Label` so its layout, symbol, and copy are visually verified.

**Approach:** a wrapper-view declared **inside** the `#Preview`
block, not a debug initializer on `EditAccountView`. The wrapper
imitates only the slice of `EditAccountView` we need to inspect —
the conditional footer `Label` — without forking the production
view's initialiser surface or compiling preview-only code into
release builds:

```swift
#Preview("Investment account, fail-open footer") {
  struct FailOpenPreview: View {
    var body: some View {
      Form {
        Section {
          Picker("Valuation", selection: .constant(ValuationMode.calculatedFromTrades)) {
            Text("Recorded value").tag(ValuationMode.recordedValue)
            Text("Calculated from trades").tag(ValuationMode.calculatedFromTrades)
          }
        } footer: {
          VStack(alignment: .leading, spacing: 4) {
            Text(ValuationMode.calculatedFromTrades.dataSourceDescription)
            Label(
              "Couldn't confirm your valuation history. Reopen the dialog to check again.",
              systemImage: "info.circle"
            )
            .foregroundStyle(.secondary)
          }
        }
      }
      .formStyle(.grouped)
    }
  }
  return FailOpenPreview()
}
```

This keeps the production `init` unchanged, avoids `#if DEBUG` API
pollution per CODE_GUIDE.md §10 ("custom init only to maintain
invariants"), and matches the precedent in `WelcomeHero.swift` for
state-pinned previews. The dialog-level coverage of fail-open
(initial → revealed) is left to the unit test
`probeThrowsGenericError_returnsShownAfterFailure` from Stage 2 plus
the manual exercise via `.task` in dev — visual fidelity of the
`Label` is what this preview pins.

### Acceptance criteria

Verifiable by manual smoke + previews + retained tests:

- All design-spec acceptance criteria §7.1–§7.8 pass:
  1. (§7.1) New investment account → no Valuation section.
  2. (§7.2) `.recordedValue` legacy account → section visible, picker
     on "Recorded value".
  3. (§7.3) `.calculatedFromTrades` with snapshots → section reveals
     after probe. *Verified via the "calculatedFromTrades with
     snapshots" preview from design §5.3 — the seeded preview shows
     the post-probe steady state.*
  4. (§7.4) `.calculatedFromTrades` without snapshots → section
     absent.
  5. (§7.5) Probe failure → section + fail-open `Label`. *Verified
     via the third preview defined above.*
  6. (§7.6) Bank/credit-card/asset → no Valuation section.
  7. (§7.7) Save / Cancel paths unchanged.
  8. (§7.8) `AccountStoreUpdateValuationTests` passes.
- All three new previews render in canvas without runtime errors on
  **both macOS and iOS** simulator/device targets. The project
  targets iOS 26+ and macOS 26+; verify both.
- The third preview renders the fail-open `Label` without clipping
  or wrapping at `.dynamicTypeSize(.accessibility3)` — the project's
  Dynamic Type ceiling per `guides/UI_GUIDE.md` line 109
  (`.dynamicTypeSize(.medium...(.accessibility3))`). Pin via a
  `.dynamicTypeSize(_:)` modifier on a `#Preview` variant or via
  Xcode's preview-canvas accessibility-size toggle.
- VoiceOver hint duplication is verified in Stage 5's UI test
  (`testRecordedValueLegacyAccountShowsValuationPicker` asserts the
  picker's accessibility hint matches `valuationMode.dataSourceHint`
  exactly and that no other element in the dialog exposes the same
  hint string). Manual VoiceOver verification is therefore not part
  of Stage 3's AC — automation in Stage 5 catches regressions in
  CI.
- Pre-flight checklist clean.
- No new compiler warnings.

### Reviewers

- `code-review` — view-body naming, exhaustive switch, env usage,
  thin-view discipline (logic delegated to Stage-1 model and Stage-2
  resolver).
- `ui-review` — fail-open Label pattern, footer VStack stability,
  preview audits, accessibility.
- `concurrency-review` — `.task(id:)` lifecycle, cancellation catch,
  closure capture of `session`.

---

## Stage 4 — UI test seed surface for `InvestmentValue`

**Branch:** `feat/uitest-seed-investment-value`.
**Depends on:** nothing (purely additive; no other stages need it
until Stage 5).

### Files

- **Modified:** `UITestSupport/UITestSeed.swift` — extend the seed
  payload with an `investmentValues: [InvestmentValueSeed]` field.
  Define a new **named struct** (not a tuple, not a typealias over
  a tuple — explicitly):

  ```swift
  public struct InvestmentValueSeed: Codable, Sendable {
    public let accountId: UUID
    public let date: Date
    public let instrumentId: String
    public let cents: Int
  }
  ```

  All `date` values **must** be constructed as
  `Date(timeIntervalSince1970: …)` literals with a UTC-comment
  suffix (matching the existing seed convention at
  `UITestSeed.swift:206-221`). `Date()` is banned because it breaks
  the diffability of `seed.txt` artefacts run-to-run.

- **Modified:** `App/UITestSeedHydrator+Upserts.swift` — add a new
  static helper `upsertInvestmentValue(_:in:)` following the exact
  shape of the existing synchronous `upsertAccount`,
  `upsertCategory`, etc. (lines 73–141). The helper takes the seed
  struct + a `Database` and inserts via `InvestmentValueRow.upsert`.
  No `async`, no `Task` — `UITestSeedHydrator.hydrate(...)` itself
  is `static func ... throws`, not async, and runs entirely inside
  a `database.write { … }` block during synchronous app init. The
  earlier draft of this plan said "iterate inside the existing
  `Task`" — that was wrong; there is no `Task`.

- **Modified:** `App/UITestSeedHydrator.swift` — add an iteration
  loop in `hydrateTradeBaseline` (and any other seed scenario that
  needs investment values) that calls
  `upsertInvestmentValue(seed, in: database)` for each
  `InvestmentValueSeed`. Order: after `upsertAccount` calls (the
  pre-FK-removed schema cascade was on `account.id`; we're past
  v5_drop_foreign_keys but the logical dependency stands — accounts
  must exist before their values).

- **Modified:** `UITestSupport/UITestSeed.swift` — extend the
  `tradeBaseline` seed (or whichever scenario Stage 5 elects) with
  the two `InvestmentValueSeed` fixtures used by the UI tests.

### Implementation

Use the existing synchronous pattern (`UITestSeedHydrator+Upserts.swift`
already exposes `upsertAccount`, `upsertCategory`,
`upsertHistoricalExpense`, etc., all `static func ... throws` taking
a `Database`). The new `upsertInvestmentValue` is the same shape:

```swift
static func upsertInvestmentValue(
  _ spec: InvestmentValueSeed, in database: Database
) throws {
  let row = InvestmentValueRow(
    id: ..., // deterministic UUID derived from accountId+date or
             // explicit per-seed UUID literal
    accountId: spec.accountId,
    date: spec.date,
    instrumentId: spec.instrumentId,
    cents: spec.cents,
    encodedSystemFields: nil)
  try row.upsert(database)
}
```

Concrete UUID-derivation strategy — explicit `UUID(uuidString:
"...")!` literal per seed entry, declared alongside other seed
fixtures (mirrors `UITestFixtures.TradeBaseline.bhpPurchaseDate`
pattern at `UITestSeed.swift:156`). Force-unwrap is acceptable in
test-only code.

### Acceptance criteria

- Existing UI tests still pass (`just test` includes UI tests on
  macOS).
- Manual local verification: launch the app under `--ui-testing`
  with a seed scenario that includes investment values, then
  inspect OSLog. `InvestmentValueCache.preload(...)` runs at
  AccountStore.load and is observable via the
  `Logger(subsystem: "com.moolah.app", category:
  "InvestmentValueCache")` subsystem — a non-zero
  `cache.values.count` after preload confirms hydration.
- This verification is **local only** — do not commit a smoke-test
  file. The criterion's purpose is to catch hydration bugs before
  Stage 5 depends on the seed data.
- Pre-flight checklist clean.

### Reviewers

- `code-review` — seed struct naming, hydrator placement,
  concurrency of the hydration loop.
- `ui-test-review` — seed identifier discipline, deterministic
  fields (no `Date()` literals — use seeded fixed dates).

---

## Stage 5 — UI test for visibility outcomes

**Branch:** `feat/edit-account-picker-visibility-uitest`.
**Depends on:** Stages 3 and 4.

### Files

- **New:** `MoolahUITests_macOS/Helpers/Screens/EditAccountScreen.swift`
  — no existing screen driver owns the Edit Account dialog
  (verified via `MoolahUITests_macOS/Helpers/Screens/` listing —
  there is `CreateAccountScreen.swift` for the create-flow
  but no edit-flow driver). New file, mirrors
  `CreateAccountScreen.swift` structure (`@MainActor`, `let app:
  MoolahApp`, `Trace.record(#function)` at the top of every action,
  post-condition `waitForExistence(timeout: 3)` before returning).

  Surface:

  ```swift
  @MainActor
  struct EditAccountScreen {
    let app: MoolahApp

    /// Opens the Edit Account dialog for the named account from
    /// the sidebar's context menu (or whichever path the app uses).
    /// Returns once the dialog's name field is visible — this is
    /// the presence sentinel required by UI_TEST_GUIDE §7.
    func open(accountName: String) { … }

    /// Presence sentinel for cases where the test opens the dialog
    /// via a different path. Asserts the dialog is on screen.
    func expectVisible() { … }

    /// Asserts the Valuation section is present in the dialog.
    /// Looks up the picker by `editAccount.valuationMode` identifier
    /// and waits up to 3s.
    func expectValuationSectionVisible() { … }

    /// Asserts the Valuation section is **not** present after
    /// `expectVisible()` has confirmed the dialog rendered. Uses
    /// the existence-then-absence pattern (wait for a known-present
    /// element first, then assert the picker identifier resolves
    /// to no element).
    func expectValuationSectionAbsent() { … }

    /// Asserts the picker's currently-selected mode equals
    /// `expected`. UI_TEST_GUIDE §3 forbids drivers from returning
    /// raw values to tests; expectations live in the driver. Reads
    /// the picker via the existing `editAccount.valuationMode`
    /// identifier.
    func expectValuationMode(_ expected: ValuationMode) { … }

    /// Asserts the picker's `accessibilityHint` equals
    /// `mode.dataSourceHint` exactly. Used by the recordedValue
    /// test to pin the VoiceOver string and detect duplicate-hint
    /// regressions.
    func expectAccessibilityHint(for mode: ValuationMode) { … }

    /// Closes the dialog via the Cancel button.
    func cancel() { … }
  }
  ```

  Key invariants (UI_TEST_GUIDE §7):
  - **Presence sentinel.** `open(...)` AND `expectVisible()` BOTH
    wait for the dialog's name field to materialise — otherwise an
    `expectValuationSectionAbsent()` call could pass vacuously
    because the sheet never opened.
  - **No element caching** — every accessor resolves through
    `app.element(for:)`.
  - **Trace logs.** Every action method begins with
    `Trace.record(#function, detail: "...")`.

- **New:** `MoolahUITests_macOS/Tests/EditAccountValuationPickerTests.swift`
  with two tests using `MoolahUITestCase`:
  - `testRecordedValueLegacyAccountShowsValuationPicker` — seed an
    account in `.recordedValue` mode with one `InvestmentValue`,
    open Edit, `expectValuationSectionVisible()`,
    `expectValuationMode(.recordedValue)`,
    `expectAccessibilityHint(for: .recordedValue)`, `cancel()`.
  - `testCalculatedFromTradesAccountWithNoSnapshotsHidesValuationPicker`
    — seed an account in `.calculatedFromTrades` mode with zero
    `InvestmentValue` rows, open Edit, `expectVisible()`
    (presence sentinel), `expectValuationSectionAbsent()`,
    `cancel()`.

  Project convention is `testCamelCase` (per
  `MoolahUITests_macOS/Tests/WelcomeViewTests.swift` and
  `TradeFlowUITests.swift`). The `test` prefix is required for
  `XCTestCase` discovery; underscores are not used.

### Implementation

Per design §5.4. Use the seed payload defined in Stage 4 to set up
each scenario. Driver follows the project's existing screen-driver
conventions (post-condition waits, single resolver, no element
caching, no sleeps — see `guides/UI_TEST_GUIDE.md`).

The accessibility identifier `"editAccount.valuationMode"` already
exists on the picker (verified at
`Features/Accounts/Views/EditAccountView.swift:103`); add a constant
for it in `UITestIdentifiers.swift` if not already present (Stage 5
must check and either add or reuse). Define a new
`UITestIdentifiers.EditAccount.dialog` for the dialog presence
sentinel; pin it via an `.accessibilityIdentifier(...)` modifier on
the form's outermost container. This is part of Stage 5's deliverable.

### Acceptance criteria

- Both UI tests pass on macOS via `just test
  EditAccountValuationPickerTests` (or `just test-mac`).
- 20 consecutive runs of the new tests locally without flakes
  (UI_TEST_GUIDE §10 checklist).
- Acceptance criterion §7.10 from the design spec is now satisfied.
- Pre-flight checklist clean.

### Reviewers

- `ui-test-review` — driver invariants, identifier discipline,
  deterministic seeds, no element caching, no sleeps.
- `ui-review` — accessibility identifier on the picker section is
  preserved/exposed.

---

## Out-of-stage cleanup

- After all five stages land, delete this plan and the design from
  `plans/` and move them to `plans/completed/`. Project convention
  per CLAUDE.md "Plans Directory."
- Open follow-up issue(s) only if any reviewer surfaces a deferral
  during execution (none expected).
