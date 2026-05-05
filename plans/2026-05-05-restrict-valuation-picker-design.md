# Restrict Edit Account valuation picker to legacy snapshot accounts

**Status:** Design — pending implementation plan.
**Owner:** Adrian.
**Date:** 2026-05-05.

## 1. Problem

The Edit Account dialog (`EditAccountView`) currently shows a "Valuation"
picker for **every** investment account, letting the user toggle between
`recordedValue` (snapshot-driven) and `calculatedFromTrades` (positions ×
current prices).

`recordedValue` is a legacy mode kept alive for accounts created before
trade-based valuation existed. New investment accounts always land in
`calculatedFromTrades` (`AccountStore.create` enforces this). Showing
the picker on accounts that have no `InvestmentValue` snapshot data
gives users a feature they shouldn't be reaching for, and lets them
silently flip into a mode that will display zero until they manually
enter a snapshot.

We want the picker to disappear for the post-migration default case
("calculated, no snapshots") and remain available for genuine legacy
accounts.

## 2. Visibility rule

The picker is shown iff **either** of these is true:

1. `account.valuationMode == .recordedValue` — the account is currently
   driven by snapshots; the user must be able to switch off.
2. The account has at least one `InvestmentValue` row — the account has
   legacy snapshot data on file, even if presently in
   `.calculatedFromTrades` mode (e.g. user already toggled away but
   hasn't deleted the data).

When neither condition holds, the picker section is omitted from the
form. The account stays in `.calculatedFromTrades` permanently from
this dialog's point of view; clearing the last snapshot does not
auto-flip the mode (avoids a jarring on-save mode change), and a
trades-mode account with no snapshots cannot be flipped back from this
dialog. That is the intended end state.

## 3. Implementation

### 3.1 Repository access via environment

`EditAccountView` reads the `InvestmentRepository` from the existing
`ProfileSession` environment value rather than via a constructor
parameter:

```swift
struct EditAccountView: View {
  @Environment(ProfileSession.self) private var session
  // … existing fields …
}
```

This matches the established pattern in `ImportSettingsView.swift:102,
111`, which already reads `session.backend.csvImportProfiles` from the
environment in production view code. The codebase has **no**
`@Environment(BackendProvider.self)` consumers; `BackendProvider` is
exposed via `ProfileSession.backend`. The `EditAccountView`
constructor signature is unchanged.

`AccountStore` is **not** the right home for the snapshot probe. It
already owns an `InvestmentValueCache`, but that cache deliberately
preloads only `.recordedValue` accounts (see
`AccountStore.preloadInvestmentValues` at
`Features/Accounts/AccountStore.swift:106-114`), so it cannot answer
the rule-2 case (`.calculatedFromTrades` with snapshots) without
changing its scope.

### 3.2 Caller wiring (no change)

`SidebarView` is the only call site. Because the dialog now reads the
session from the environment, the existing call site:

```swift
.sheet(item: $accountToEdit) { account in
  EditAccountView(account: account, accountStore: accountStore)
}
```

is **unchanged**. SwiftUI's `.sheet` propagates the parent's
`@Environment(ProfileSession.self)` into the sheet content
automatically.

### 3.3 Picker visibility state

`EditAccountView` adds two `@State` flags:

```swift
@State private var showValuationPicker: Bool
@State private var pickerShownDueToProbeFailure: Bool = false
```

`showValuationPicker` is initialised in `init` to
`account.valuationMode == .recordedValue`.
`pickerShownDueToProbeFailure` is `false` initially and only set
`true` when the resolver returns via the fail-open branch (§3.5).

The form runs an async `.task` (gated on `account.id` so it doesn't
re-fire when local fields change) that delegates to a pure async
resolver and assigns the result back to state. The `.task` body uses
a typed `catch is CancellationError` so the invariant ("only
cancellation reaches this catch") is compiler-checked, not just
asserted in a comment:

```swift
.task(id: account.id) {
  guard !showValuationPicker else { return }
  do {
    let result = try await Self.resolvePickerVisibility(
      accountId: account.id,
      snapshotProbe: {
        try await session.backend.investments
          .fetchValues(accountId: account.id, page: 0, pageSize: 1)
          .values.isEmpty == false
      })
    switch result {
    case .hidden:
      showValuationPicker = false
      pickerShownDueToProbeFailure = false
    case .shown:
      showValuationPicker = true
      pickerShownDueToProbeFailure = false
    case .shownAfterFailure:
      showValuationPicker = true
      pickerShownDueToProbeFailure = true
    }
  } catch is CancellationError {
    // View is being dismissed or `account.id` changed; leave state
    // unchanged so SwiftUI's teardown is clean. If the resolver
    // ever starts throwing a non-cancellation error, the compiler
    // will surface the unhandled case, forcing a decision rather
    // than silently swallowing the error.
  }
}
```

The resolver is a `static` method on `EditAccountView` so it can be
unit-tested without SwiftUI. It returns a closed-set `enum` so the
`.task` body must handle every case exhaustively:

```swift
enum PickerVisibility: Equatable, Sendable {
  case hidden
  case shown
  case shownAfterFailure
}

static func resolvePickerVisibility(
  accountId: UUID,
  snapshotProbe: () async throws -> Bool
) async throws -> PickerVisibility {
  do {
    return try await snapshotProbe() ? .shown : .hidden
  } catch let error as CancellationError {
    // Re-propagate the original cancellation — the
    // structured-concurrency contract requires callers see
    // cancellation rather than a synthesised fallback value. The
    // `.task` body catches it and leaves state unchanged.
    throw error
  } catch {
    Self.logger.warning(
      "valuation snapshot probe failed for \(accountId, privacy: .public): \(error.localizedDescription, privacy: .public)")
    // Fail-open — see §3.5 Failure mode.
    return .shownAfterFailure
  }
}
```

`accountId` is threaded through purely to populate the warning log
line; the resolver does not use it for control-flow decisions (the
probe closure has already closed over it at the call site). Documented
explicitly so a future refactor doesn't drop it.

`Self.logger` is `private static let logger = Logger(subsystem: "com.moolah.app", category: "EditAccountView")` declared on the type. The static placement is required so the `static func resolvePickerVisibility` can reach it via `Self.logger` without an instance. Both placements exist in the codebase (`private static let` on the type — `InvestmentAccountView.swift:16-17`; file-scope `private let` — `ImportSettingsView.swift:5`, `InvestmentValueCache.swift:21`) and either is acceptable; the choice here is dictated by the static-method call site, not by `View`-vs-non-`View` convention.

**Visibility outcomes:**

| State | Initial `showValuationPicker` | Resolver result | `pickerShownDueToProbeFailure` | Footer note |
|------ |--------- |------------- |--------------- |--------------- |
| `.recordedValue` (any snapshots) | true | not called (guarded) | false | normal |
| `.calculatedFromTrades`, no snapshots | false | `.hidden` | false | section absent |
| `.calculatedFromTrades`, has snapshots | false | `.shown` | false | normal |
| `.calculatedFromTrades`, probe fails | false | `.shownAfterFailure` | true | fail-open hint (§3.4) |
| `.calculatedFromTrades`, probe cancelled | false | throws (state unchanged) | false | section absent |

The `valuationSection` already checks `if type == .investment`; the new
guard combines them: `if type == .investment && showValuationPicker`.

### 3.4 Form section gating

The two pieces of mode-dependent text (the `.accessibilityHint` and
the section footer) move out of the view into a `ValuationMode`
extension so they can be read from a model layer and reused:

```swift
extension ValuationMode {
  /// Short, sentence-fragment description of where this mode's
  /// balance comes from. Used as a VoiceOver `.accessibilityHint`
  /// in the Edit Account picker; reusable wherever a brief one-line
  /// description of the mode's data source is needed.
  var dataSourceHint: String {
    switch self {
    case .recordedValue:
      return "Balance comes from the value you last recorded"
    case .calculatedFromTrades:
      return
        "Balance is calculated from your trade history and current prices of your holdings"
    }
  }

  /// Full-sentence description of the mode's data source, with
  /// terminating period. Used as the Edit Account picker's section
  /// footer; reusable as descriptive copy elsewhere.
  var dataSourceDescription: String {
    switch self {
    case .recordedValue:
      return "The balance comes from the value you last recorded manually."
    case .calculatedFromTrades:
      return
        "The balance is calculated from your trade history and the current prices of your holdings."
    }
  }
}
```

Per CLAUDE.md "Thin Views, Testable Stores" — display strings derived
from a domain enum belong on the model, not as private view
computeds, so they can be unit-tested and reused by other views (e.g.
`InvestmentAccountView` if it ever needs to mirror the same labels).

`valuationSection` becomes:

```swift
@ViewBuilder private var valuationSection: some View {
  if type == .investment, showValuationPicker {
    Section {
      Picker("Valuation", selection: $valuationMode) {
        Text("Recorded value").tag(ValuationMode.recordedValue)
        Text("Calculated from trades")
          .tag(ValuationMode.calculatedFromTrades)
      }
      .accessibilityIdentifier("editAccount.valuationMode")
      .accessibilityHint(valuationMode.dataSourceHint)
    } footer: {
      VStack(alignment: .leading, spacing: 4) {
        Text(valuationMode.dataSourceDescription)
        if pickerShownDueToProbeFailure {
          Label(
            "Couldn't confirm your valuation history. Reopen the dialog to check again.",
            systemImage: "info.circle"
          )
          .foregroundStyle(.secondary)
        }
      }
    }
  }
}
```

The fail-open hint uses `Label(_:systemImage:)` so the symbol gives
VoiceOver and sighted users a semantic cue ("this is a notice, not
the primary description") and the text inherits the section footer's
existing typographic style without a manual `.font(.footnote)`
override (which would double-shrink the line on top of the footer's
already-secondary style — bad at large Dynamic Type sizes).

The fail-open hint appears **only** when the section was revealed
because the probe failed (`pickerShownDueToProbeFailure == true`).
Voice matches BRAND_GUIDE "Calm, helpful, no alarm" — no
exclamation, no "error", suggests a recovery action.

**On layout stability:** when the `.task` resolver returns
`.shownAfterFailure`, both `showValuationPicker` and
`pickerShownDueToProbeFailure` flip in the same render pass, so the
section appears with its hint already attached. Because the `.task`
fires once on dialog open and completes before the user can
realistically reach the footer, the layout growth is not
user-observable and no `withAnimation(.none)` suppression is needed.
Documented here so a future change doesn't try to animate the
appearance and reintroduce flicker.

### 3.5 Failure mode

If `fetchValues` throws a non-cancellation error (transient I/O, db
contention, profile teardown), the resolver **fails open** and reveals
the picker. Rationale:

- `.recordedValue` accounts already see it — unaffected (the `guard`
  short-circuits before the probe).
- `.calculatedFromTrades` accounts with snapshots see the picker —
  preserves the user's ability to flip back to recordedValue mode,
  which is the whole point of rule 2 in §2.
- `.calculatedFromTrades` accounts **without** snapshots see the
  picker briefly. Mildly off-spec (the user sees an option we'd
  ordinarily hide), but recoverable on next open and never traps the
  user. Picker default selection is still
  `.calculatedFromTrades`, so no accidental mode flip occurs unless
  the user explicitly chooses one.

The error is logged at `warning` level. No user-facing error surface
— the picker's appearance is the recovery path. `CancellationError`
is treated separately (silent, no log) since it represents normal
view-dismissal lifecycle, not a real failure.

### 3.6 Accessibility

The Section appears (rather than disappears), which means VoiceOver
will read it when the user navigates past the existing fields. The
existing `.accessibilityHint` on the picker reads either:

- "Balance comes from the value you last recorded" (when
  `valuationMode == .recordedValue`), or
- "Balance is calculated from your trade history and current prices
  of your holdings" (when `valuationMode == .calculatedFromTrades`).

Both adequately describe the modes for VoiceOver users. No additional
`.accessibilityElement` or live-region announcement is needed. The
common case (`.recordedValue`) shows the picker before the user has
time to tab into the form, so no in-flight reveal is announced.

The "post-probe additive reveal" case (`.calculatedFromTrades` with
snapshots, or fail-open) is the only path where VoiceOver focus could
already be past the section's logical position when it appears.
Acceptable: the user is editing fields, not auditing the section
list, and the section's controls are reachable on the next pass
through the form. The fail-open footer note (§3.4) is plain `Text`
and is read in document order along with the rest of the section.
Documented here so future changes don't accidentally rely on mid-edit
announcement.

## 4. Out-of-scope

- **`AccountStore.create` behaviour.** Already promotes `.recordedValue`
  → `.calculatedFromTrades` for new investment accounts. No change.
- **Migration (`ValuationModeMigration`).** Already flips
  snapshot-less investment accounts to `.calculatedFromTrades`. No
  change.
- **`InvestmentAccountView`** (the snapshot editor). Visibility there
  is driven by `account.valuationMode`, not by this dialog. Unchanged.
- **Auto-clearing snapshots when mode flips.** Out of scope; the
  user explicitly preferred *not* to couple the two so the dialog
  doesn't surprise them on save.

## 5. Tests

### 5.1 Existing coverage

- `MoolahTests/Features/AccountStoreUpdateValuationTests` pins the save
  flow used by the picker. Unchanged — still valid because the save
  path itself is unchanged.

### 5.2 New unit coverage (mandatory)

The visibility resolver `EditAccountView.resolvePickerVisibility` is a
pure async function over a closure-typed probe — directly unit-testable
without SwiftUI. The project uses Swift Testing (`@Suite`, `@Test`,
`#expect`, `#require`); see `AccountStoreUpdateValuationTests.swift`
for the canonical shape. New file
`MoolahTests/Features/EditAccountVisibilityTests.swift` with one test
per branch:

1. `probeReturnsTrue_returnsShown` — probe yields `true` (snapshots
   exist) → resolver returns `.shown`.
2. `probeReturnsFalse_returnsHidden` — probe yields `false` (no
   snapshots) → resolver returns `.hidden`.
3. `probeThrowsGenericError_returnsShownAfterFailure` — probe throws
   `BackendError.notFound(...)` → resolver returns
   `.shownAfterFailure` (fail-open).
4. `probeThrowsCancellationError_propagates` — probe throws
   `CancellationError` → resolver re-throws the original
   `CancellationError`. Verified via
   `await #expect(throws: CancellationError.self) { try await … }`.

A small additional pair of tests pins the `ValuationMode` extension
introduced in §3.4:

5. `dataSourceHint_returnsExpectedString` — exact-string assertion
   for both modes' `.dataSourceHint`.
6. `dataSourceDescription_returnsExpectedString` — exact-string
   assertion for both modes' `.dataSourceDescription`.

Lives in `MoolahTests/Domain/ValuationModeDisplayTextTests.swift`
(model-layer test, not feature-layer).

The `.recordedValue` short-circuit lives outside the resolver (it's
the `.task` body's `guard`), and is a one-line read of an
`@State` flag, so it does not need its own test — it is exercised in
the Preview audits in §5.3.

The probe-construction step inside the `.task` body
(`session.backend.investments.fetchValues(...).values.isEmpty == false`)
is exercised by the existing `InvestmentRepository` contract tests in
`MoolahTests/Domain/`; no new contract test required.

### 5.3 Preview audits (visual)

Add two new `#Preview` configurations to make the visibility branching
reviewable in canvas:

- "Investment account, no snapshots" → backend has no `InvestmentValue`
  rows for the account; picker stays hidden.
- "Investment account, calculatedFromTrades with snapshots" → seed one
  `InvestmentValue` via `backend.investments.setValue(accountId:date:value:)`
  before constructing the view (using the existing `async`-wrapped
  preview pattern in `InvestmentAccountView+Previews.swift`); the
  `.task` probe then reveals the picker.

Existing previews "Bank account" and "Investment account
(calculatedFromTrades)" remain. Constructors are unchanged because
the new `InvestmentRepository` is read from the environment, not from
a constructor parameter; previews already inject `ProfileSession` /
`PreviewBackend` via `.environment(...)`.

**Canvas limitation:** the seeded preview shows the picker as already
revealed (probe completes before the snapshot is captured). The
`hidden → visible` transition itself is **not** exercised by either
preview — there is no animation we need to verify, but a future
reviewer should be aware that the canvas captures the post-probe
steady state, not the in-flight transition.

### 5.4 UI test (mandatory, in-scope)

A UI test exercises the visibility rule end-to-end and is part of the
implementation plan rather than deferred:

1. Seed: investment account with `valuationMode = .recordedValue` and
   one `InvestmentValue` snapshot. Open Edit. Picker present.
2. Seed: investment account with `valuationMode = .calculatedFromTrades`
   and zero snapshots. Open Edit. Picker absent.

**Prerequisite work** (one implementation stage of its own — see the
forthcoming implementation plan):

- Extend `UITestSeed` with an `investmentValues` collection of
  `(accountId, date, instrument, cents)` tuples.
- Hydrate via `InvestmentRepository.setValue(accountId:date:value:)`
  in `UITestSeedHydrator+Upserts.swift`.
- Add an `EditAccountScreen` driver (or extend an existing one)
  exposing the dialog open/inspect operations needed by the test.

The fail-open path (probe failure) is **not** UI-tested — it requires
fault injection that the project's UI test surface does not support.
The unit tests in §5.2 cover that branch.

## 6. Risks & considerations

- **Per-keystroke async work.** The `.task(id: account.id)` block
  fires once per dialog open and never on field edits because the id
  is stable across the dialog's lifetime. Confirmed by reading
  `EditAccountView`'s state ownership.
- **Repository availability under previews.** `PreviewBackend.create()`
  returns a backend whose `investments` is functional against
  in-memory storage. The previews already inject `ProfileSession` via
  the environment; no preview signature changes.
- **Locked picker for a hybrid account whose probe fails on first
  open.** Documented in §3.5. Reopening retries.

## 7. Acceptance criteria

1. New investment account (created via Create Account dialog) opens in
   Edit Account with **no** Valuation section.
2. Legacy investment account in `recordedValue` mode opens with the
   Valuation section visible; picker preselected to "Recorded value".
3. Investment account in `calculatedFromTrades` mode that has at least
   one `InvestmentValue` row opens with the Valuation section visible
   after a brief async probe.
4. Investment account in `calculatedFromTrades` mode with zero
   `InvestmentValue` rows opens — and stays — without the Valuation
   section under normal (probe-success) conditions.
5. On probe failure, the Valuation section reveals (fail-open) **and**
   a footnote-styled secondary text reads "Couldn't confirm your
   valuation history. Reopen the dialog to check again." so the user
   has a clear signal the section appeared due to a transient error.
   Default selection is still `.calculatedFromTrades`, so no
   accidental mode flip occurs.
6. Bank/credit-card/asset accounts continue to show no Valuation
   section (unchanged from current behaviour).
7. Save / Cancel paths and field validation are unchanged.
8. `AccountStoreUpdateValuationTests` still passes.
9. New `EditAccountVisibilityTests` covers all four resolver
   branches in §5.2 (returns `.shown` / `.hidden` /
   `.shownAfterFailure`; re-throws `CancellationError`).
10. New UI test exercises the two visibility outcomes (rule-1 and
    rule-2-negative) with the seeded investment-account dataset
    described in §5.4.
11. `just format-check` clean; no new SwiftLint baseline entries.
