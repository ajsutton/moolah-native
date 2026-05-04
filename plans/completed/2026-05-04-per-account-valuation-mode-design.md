# Per-Account Valuation Mode — Design

**Date:** 2026-05-04
**Status:** Implemented (PRs #730, #731, #732, #733, #734, #735, #736)
**Scope:** Replace today's implicit "if any `InvestmentValueRecord` exists for
this account, render the legacy snapshots view and use the latest snapshot as
the current value; otherwise render the positions view and sum positions"
auto-detect with an explicit, **per-account, reversible** toggle. The toggle
selects between two valuation modes: **Recorded value** (user-entered
snapshots) and **Calculated from trades** (sum of positions valued at current
prices). The same toggle drives the account-detail view layout *and* every
surface that aggregates the account's "current value" (sidebar, net worth,
reports, forecast, intents). Snapshots and trade transactions are both
preserved across mode changes — switching is reversible at any time.

## Motivation

The product is mid-transition from "investment account = manual valuation
snapshot whenever I remember to update it" toward "investment account = ledger
of trades that compute a live value." CSV import already emits trade
transactions for an investment account (`Transaction` of type `.trade` with
multi-leg cash + position legs). What's missing is the user's ability to flip
an individual account from the old model to the new one — *and back* — while
they verify that the imported trades reproduce the historical snapshot value
to their satisfaction.

Today, `InvestmentAccountView` decides which layout to show via
`investmentStore.values.isEmpty`, `InvestmentStore.loadAllData` decides which
data set to load via the same predicate (`hasLegacyValuations`), and
`AccountBalanceCalculator.displayBalance` prefers any externally-provided
snapshot over summing positions. All three are implicit consequences of data
presence. Once a user adds a snapshot — even by accident or via an old
client — they're locked into the legacy view until every snapshot is deleted.
There is no way to "preview" trades-mode while keeping snapshots around as a
safety net.

## Goals

- Add an explicit per-account toggle that selects the valuation mode.
- Make the toggle reversible (no destructive switch, no data loss either way).
- Apply the mode atomically across **every** surface that reads "current
  value": sidebar balance, net worth total, investment total, reports,
  forecast starting points, App Intents (`GetAccountBalanceIntent`,
  `GetNetWorthIntent`, `ListAccountsIntent`), the `InvestmentStore` data
  load, and the account-detail view layout.
- Sync the per-account mode across devices.
- Preserve today's appearance for every existing account on first launch.
- Bias new investment accounts toward the trade-based model (deliberately
  shipped only after every read site honours the mode — see
  Migration & Rollout).

## Non-Goals

- No automatic flip on CSV import. The user verifies first, then flips.
- No side-by-side comparison view, no overlaid charts, no diff display. The
  user flips, eyeballs, flips back.
- No "permanent commit" affordance that destroys snapshots. Snapshots remain
  in CloudKit forever.
- No improvement to the historical net-worth chart for trades-mode accounts.
  See "Pre-Existing Limitation: Historical Chart" below.
- No new mode beyond the two listed (no "blended", no "snapshot-then-trades").
  The enum is extensible; we just don't ship a third case now.
- No change to non-investment accounts. The new field exists in the schema
  for them but is never read.
- No change to the trade ledger, position computation, snapshot CRUD, or CSV
  import behaviour.

## Pre-Existing Limitation: Historical Chart

`GRDBAnalysisRepository+DailyBalancesInvestmentValues.swift` folds
investment-value snapshots into per-day balances. There is **no equivalent
fold for trade-derived position market values over time** —
`PositionsValuator` valuates *current* positions at *current* prices; it
does not produce a daily series. Today this means an account with no
snapshots and only trades silently contributes zero (or only the cash leg of
each trade) to the historical net-worth chart. **This feature does not fix
that.** Trades-mode accounts will continue to render an inaccurate or empty
historical-net-worth contribution. A proper fix requires a new "valued
positions over time" series and is tracked separately. The user has accepted
this in scoping (the goal here is to enable the mode toggle; chart accuracy
is a follow-up).

The current value (today's number) is correct in trades mode — only the
historical series is impacted.

## User-Facing Concepts

The account settings sheet for an investment account gains one control: a
two-option picker with the labels:

- **Recorded value** — "The account's current value comes from the latest
  valuation snapshot you entered."
- **Calculated from trades** — "The account's current value is computed from
  your trade history and current instrument prices."

The control is hidden for non-investment accounts. There is no other UI
affordance — the toggle is a settings-sheet decision, not an in-context
switch.

## Design

### 1. Domain model

Add a new enum in `Domain/Models/`:

```swift
public enum ValuationMode: String, Codable, Sendable, CaseIterable {
    case recordedValue
    case calculatedFromTrades
}
```

Extend `Account` with one field:

```swift
struct Account: ... {
    // ... existing fields ...
    var valuationMode: ValuationMode  // default .recordedValue
}
```

The default is `.recordedValue`. This is the safe default: if a record syncs
in from an old client without the field, the account behaves as it did before
this feature shipped (legacy view + snapshot drives balance), so users on a
mixed-client setup don't see surprise balance changes.

`Account.init(...)` gains a parameter `valuationMode: ValuationMode = .recordedValue`.

`Account` uses a manual `Codable`. The new field's `init(from:)` line **must**
use `decodeIfPresent` and fall back to the `.recordedValue` default:

```swift
valuationMode = try container.decodeIfPresent(
    ValuationMode.self, forKey: .valuationMode) ?? .recordedValue
```

Without `decodeIfPresent`, sync from a not-yet-upgraded client would trap on
decode (the field would simply be missing). The encode side always writes the
field. `Equatable` and `Hashable` include `valuationMode`. `Comparable` is
unchanged (still position-only).

The field is meaningful **only** when `account.type == .investment`. For other
account types it exists in the schema but is never consulted by any
balance-computing code. (We deliberately keep it on the single `Account`
struct rather than introducing a sub-type, to avoid touching every call site
that pattern-matches on `AccountType`.)

### 2. CloudKit schema

Add a single field to the `Account` record type in `CloudKit/schema.ckdb`:

```
valuationMode  STRING  QUERYABLE
```

Field is non-required at the CloudKit level; missing field decodes to
`.recordedValue` per the `decodeIfPresent` above.

Procedure: follow the `modifying-cloudkit-schema` skill — edit
`schema.ckdb`, run `just generate` to regenerate
`Backends/CloudKit/Sync/Generated/AccountRecordCloudKitFields.swift`. Update
`AccountRecord` mapping (encode/decode) and the GRDB cache row
(`AccountRow` + mapping) to include the field. Round-trip the field through
both backends.

### 3. GRDB cache

Add a `valuationMode TEXT NOT NULL DEFAULT 'recordedValue'` column to the
`account` table via a new `DatabaseMigrator` step. Register the step in
`Backends/GRDB/Schema/ProfileSchema+CoreFinancialGraph.swift` (or its
nearest sibling that owns the `account` table) **after** all currently-
registered migrations, with the identifier
`addAccountValuationMode`. Migration ordering is load-bearing across other
schema work; appending preserves replay determinism.

The default-on-add covers existing rows; `AccountRow` write paths always
specify the column explicitly. No index on the column (it's never a query
predicate; it's read alongside other account fields).

### 4. One-time profile migration

On first launch after upgrade, run a one-shot migration per profile, gated by
a UserDefaults flag `didMigrateValuationMode_<profileID>`.

**Where it runs:** added to `App/ProfileSession+Bootstrap.swift` (or the
nearest existing equivalent) immediately after the GRDB cache is hydrated
and `AccountRepository` is reachable, but **before** the first
`AccountStore.refreshBalances()` call. This ensures users never see a
transient "default `.recordedValue` then re-flip to `.calculatedFromTrades`"
flicker. The migration runs on the main actor (it mutates the
profile-scoped `AccountRepository`).

**Algorithm:**

1. Read the gate flag. If set, return immediately (no log spam).
2. Load every `Account` with `type == .investment` via `AccountRepository`.
3. For each, call `InvestmentRepository.fetchValues(accountId:page:pageSize:)`
   with `page: 0, pageSize: 1`.
4. If `result.values.isEmpty == false` → leave the account at its current
   `valuationMode` (which is `.recordedValue` from the schema default). No
   write — the field is already correct, and writing back invites a sync
   storm of no-op record updates.
5. If `result.values.isEmpty == true` → set
   `valuationMode = .calculatedFromTrades` and persist via
   `AccountRepository.update(account:)`.
6. **After** the loop completes successfully, set the UserDefaults flag.
   Setting the flag last (rather than per-account) ensures a crash mid-loop
   re-runs the entire migration on next launch — and because step 4 is a
   no-op write and step 5 is idempotent for accounts that haven't gained a
   snapshot since, re-running is safe.

**Tie-breaker for accounts that gained a snapshot since a partial run:**
the algorithm sees a snapshot present, takes the no-op path, and the account
remains at `.recordedValue`. This matches the documented "snapshot presence
wins" rule.

**New investment accounts** created by the in-app account-creation flow
default to `.calculatedFromTrades`. This is set explicitly at the call site
(`AccountStore.create(...)`), not by changing the struct default. **This
default change ships in the final PR** of the rollout (after every read
site honours the mode), so the new default is never observable while wiring
is incomplete. See Migration & Rollout below.

Investment accounts arriving via sync from a not-yet-upgraded peer will land
with the missing-field default (`.recordedValue`). The upgrading device's
migration runs once at startup; if a sync delivers such an account *after*
that, it stays at `.recordedValue` until the user flips it manually. We
accept this — sync from old clients is a transient, narrow window.

### 5. Behaviour wiring (read sites)

The toggle is consulted at five read sites. Each site swaps an implicit
"do snapshots exist?" check for an explicit "is this account in Recorded
value mode?" check.

**5a. `AccountBalanceCalculator.displayBalance(for:investmentValue:)`**
(`Features/Accounts/AccountBalanceCalculator.swift:117`)

Today:
```swift
if account.type == .investment, let investmentValue {
  return investmentValue
}
// else sum positions
```

After:
```swift
if account.type == .investment, account.valuationMode == .recordedValue {
  // recorded-value mode: use the snapshot (zero if missing)
  return investmentValue ?? .zero(instrument: account.instrument)
}
// trades mode (or non-investment): sum positions
```

The `?? .zero` change is deliberate: an account explicitly set to Recorded
value mode with no snapshot means "user hasn't entered a value yet" — that's
a $0 balance, not "fall back to summing positions." Falling back would
silently re-introduce auto-detect at the read site.

**5b. `AccountBalanceCalculator.totalConverted(for:to:using:)`**
(`Features/Accounts/AccountBalanceCalculator.swift:86`)

The predicate must be **`account.type == .investment && account.valuationMode == .recordedValue`** — non-investment accounts must always position-sum
regardless of `valuationMode` (which is unread for them but defaults to
`.recordedValue` on the field). Today the method only consults
`investmentValues` when present; replace that consultation with the explicit
mode check, and use `.zero(instrument: account.instrument)` when the cache
has no entry but the account is in recorded mode (mirrors 5a).

**5c. `InvestmentAccountView` layout selection**
(`Features/Investments/Views/InvestmentAccountView.swift`)

Today branches on `investmentStore.hasLegacyValuations` at line 130 (the
`legacyValuationsLayout` summary tile at line 83 reads the same predicate).
After:
```swift
switch account.valuationMode {
case .recordedValue:    legacyValuationsLayout
case .calculatedFromTrades: positionTrackedLayout
}
```

**Preserve the two-frame gate.** Lines 21–28 explain that the body is gated
behind a "have we loaded values yet?" check to prevent a Release-only AppKit
toolbar crash when `TransactionListView`'s toolbar is torn down and re-
mounted in the same render pass. With explicit mode the gate's *condition*
changes (we no longer need to wait for snapshot loading to know which layout
to render), but the **toolbar must still not be torn down by a mid-session
mode flip**. Concretely: ensure the same `TransactionListView` instance is
mounted in both layouts (or that switching layouts goes through a stable
identity that doesn't tear the toolbar down). If that turns out to be
infeasible, keep the two-frame gate but key it on a `@State Bool` that
flips after a `Task.yield()` post-mode-change. Either way, the implementer
must verify in Release on macOS that flipping the picker mid-session does
not crash.

**Empty-state predicates** (`InvestmentValuesView.swift:11`,
`InvestmentAccountView.swift:225`) currently use
`investmentStore.values.isEmpty` to render an empty state inside the legacy
layout. Keep that as-is — it's the right predicate for "no snapshots
recorded yet". The mode flag picks the *layout*; data presence picks the
*populated/empty* state within the layout.

**5d. `InvestmentStore.loadAllData(accountId:profileCurrency:)`**
(`Features/Investments/InvestmentStore.swift:119`)

Today branches on `hasLegacyValuations` — but `hasLegacyValuations` is a
*post-load* predicate (`!values.isEmpty`), so the store has to load values
first to know which path to take. With explicit mode, the branch can be made
on the account passed in:

```swift
func loadAllData(account: Account, profileCurrency: Instrument) async {
  loadedHostCurrency = profileCurrency
  accountPerformance = nil
  switch account.valuationMode {
  case .recordedValue:
    await loadValues(accountId: account.id)
    await loadDailyBalances(accountId: account.id, hostCurrency: profileCurrency)
    guard !Task.isCancelled else { return }
    accountPerformance = AccountPerformanceCalculator.computeLegacy(...)
  case .calculatedFromTrades:
    await loadPositions(accountId: account.id)
    await valuatePositions(profileCurrency: profileCurrency, on: Date())
    await refreshPositionTrackedPerformance(...)
  }
}
```

Signature change: `accountId: UUID` → `account: Account`. Update every call
site (currently the `.task` block in `InvestmentAccountView`). Same change
applies to `reloadPositionsIfNeeded`.

`hasLegacyValuations` (line 232) is removed. The store no longer derives the
mode — it receives it. Code that previously asked the store "are we in legacy
mode?" reads `account.valuationMode` directly.

In recorded mode we still load values; users may also have legacy snapshots
they want to view in trades mode is handled by **not** loading them — the
trades-layout view doesn't need them. Snapshots remain in CloudKit; flipping
back to recorded mode triggers `loadAllData` again and re-loads them.

**5e. Daily-balance / chart aggregation**

`GRDBAnalysisRepository+DailyBalancesInvestmentValues.swift:23`
(`fetchInvestmentAccountIds`) returns every investment account regardless of
mode. The fold then walks each account's snapshots. Modify the SQL to filter
by mode:

```sql
SELECT id FROM account
WHERE type = 'investment' AND valuationMode = 'recordedValue'
```

Trades-mode accounts therefore don't participate in the snapshot fold. Their
historical contribution falls through to whatever the existing trade-leg
fold produces — which, per the "Pre-Existing Limitation" section above, is
not market-valued. This is an acknowledged limitation of this feature, not a
regression: today, an investment account with no snapshots already had this
behaviour; we just make it consistent with the explicit mode.

The pinning test for the index (`DailyBalancesPlanPinningTests`) needs to
be re-pinned for the new predicate; the composite index still serves the
new SELECT.

### 6. UI — settings sheet

`EditAccountView.detailsSection` (`Features/Accounts/Views/EditAccountView.swift:68`)
gains a new row, **inside a separate `Section`** (not the existing details
section), conditionally rendered when `type == .investment`:

```swift
if type == .investment {
  Section {
    Picker("Valuation", selection: $valuationMode) {
      Text("Recorded value").tag(ValuationMode.recordedValue)
      Text("Calculated from trades").tag(ValuationMode.calculatedFromTrades)
    }
  } footer: {
    Text(valuationMode == .recordedValue
         ? "The account's current value comes from the latest valuation snapshot you entered."
         : "The account's current value is computed from your trade history and current instrument prices.")
  }
}
```

Section grouping with a footer is the macOS Form idiom for "control + brief
explanation"; it places the description below the row in `.secondary`
foreground without us hand-styling a `Text`. The footer text updates as the
user changes the picker (live preview of the chosen mode's behaviour). The
section is hidden entirely for non-investment accounts so the sheet stays
visually unchanged for them.

The Picker reads from a new `@State var valuationMode: ValuationMode`
initialised from `account.valuationMode` in `init`. `save()` writes the
field through `AccountStore.update(updated)` exactly like the other fields.

**Mid-edit sync delivery:** if the underlying `account` changes (e.g., a
remote device flips the mode while the sheet is open), the sheet's local
`@State` is *not* updated — this matches the existing behaviour for `name`,
`type`, etc. The user's Save will overwrite. We accept this ("last writer
wins" semantics extend to open edit sheets); a separate concurrent-edit
warning is out of scope.

### 7. App Intents

- `GetAccountBalanceIntent` and `ListAccountsIntent` call
  `AccountStore.displayBalance(for:)`, which goes through 5a. Once 5a
  ships, both intents honour the mode automatically. No intent changes.
- `GetNetWorthIntent` reads `AccountStore.netWorth`, which is populated by
  `AccountBalanceCalculator.compute` — same path. No intent changes.
- `AddInvestmentValueIntent` writes a snapshot via
  `AutomationService.setInvestmentValue`. **Write a snapshot regardless of
  the account's current mode.** Rationale: the user invokes this intent
  intentionally (Shortcuts, voice command) — silently rejecting the write
  because the account happens to be in trades mode is surprising. The
  snapshot lands in CloudKit and is immediately visible if the user flips
  back. If the user wants the snapshot to drive balance, they flip to
  recorded mode. Document this in the intent's
  `IntentDescription.searchKeywords` is unnecessary, but the intent's
  unit test should explicitly exercise the trades-mode case.

### 8. Sync

The new field is part of the existing `Account` record. It rides existing
sync infrastructure. Conflict policy is the existing `Account` last-writer-
wins policy. The toggle is a rare write — contention is unlikely. No new
zone, no new sync handler, no new precondition.

When a recorded-mode field arrives from sync and the local user's UI is
showing the account-detail view in trades mode, the view re-renders to
legacy mode (and vice versa). The active edit sheet (if any) does **not**
re-render its picker (per §6's "Mid-edit sync delivery" note); a save will
last-writer-win.

### 9. Edit affordances per mode

- **Recorded value mode:** snapshots editor (in `InvestmentAccountView`
  legacy layout) is fully active. User can add, edit, delete snapshots.
  Trade transactions still appear in the transaction list (they exist as
  normal `Transaction` records); they do not contribute to the displayed
  balance in this mode.
- **Calculated from trades mode:** snapshots editor is hidden (we don't
  render the legacy layout at all). Snapshots in CloudKit are preserved but
  unreachable from the UI in this mode. To edit a snapshot, the user flips
  back to Recorded value mode. Position-affecting trade transactions are
  edited via the standard transaction editor regardless of mode.
  `AddInvestmentValueIntent` can still write snapshots in this mode (§7).

This asymmetry is intentional: Recorded value is the legacy mode and we
expose it fully. Calculated from trades is the forward mode and snapshots
are a footnote in it.

## Edge Cases & Invariants

- **Empty account, recorded mode:** balance = 0; legacy layout shows the
  empty-snapshots state ("No valuations yet — add one to record this
  account's value").
- **Empty account, trades mode:** balance = 0; trades layout shows the
  empty-positions state.
- **Mid-period mode change while reports are open:** the report observes the
  account via `AccountStore`; an `Account` mutation publishes a state change
  and the report re-renders. No special handling.
- **Account hidden:** the toggle is unaffected by visibility. Hidden accounts
  are excluded from sidebar/totals as today; the toggle still applies if/when
  they're un-hidden.
- **Account type changed from `.investment` to something else:** unsupported
  today (the app doesn't expose this), so unchanged. `valuationMode` would
  become dead data on the renamed account; harmless.
- **CSV import into a recorded-mode account:** trades are created as normal.
  Balance does not move (snapshot still drives it). User toggles when ready.
- **Two devices flip in opposite directions while offline:** last-writer-wins
  on `Account`. The losing device sees the winner's choice on next sync.
  Acceptable for a rare, user-driven setting.
- **Migration race:** the gate flag is per-profile UserDefaults; if the user
  switches profile mid-migration we re-run for the new profile. Profile-A's
  flag does not affect Profile-B.
- **Mid-session mode flip in `InvestmentAccountView`:** the layout switches
  but the toolbar must remain stable (§5c). Verify in Release on macOS.

## Testing

All tests use Swift Testing. Patterns follow `guides/TEST_GUIDE.md`. Test
files live alongside their existing siblings.

### Domain & repository contract tests

- `MoolahTests/Domain/AccountTests.swift`: `valuationMode` round-trips
  through `Codable` (default decode = `.recordedValue` when key absent;
  explicit decode for both cases; encode always emits the key).
- `MoolahTests/Domain/AccountRepositoryContractTests.swift`:
  `valuationMode` round-trips through the repository (set, fetch, update,
  delete).
- `MoolahTests/Backends/CloudKit/AccountRecordMappingTests.swift`:
  encode/decode both cases; decode missing field as `.recordedValue`.
- `MoolahTests/Backends/GRDB/AccountRowMappingTests.swift`: same.

### Migration tests

`MoolahTests/App/ValuationModeMigrationTests.swift` builds fixture profiles
and asserts the post-migration mode for each account class:

- Investment account with one snapshot, no trades → `.recordedValue` (no
  write performed; verify via repository call counter or write log).
- Investment account with no snapshot, no trades → `.calculatedFromTrades`
  (write performed).
- Investment account with no snapshot, one trade → `.calculatedFromTrades`.
- Investment account with both snapshots and trades → `.recordedValue`
  (snapshot presence wins).
- Non-investment account → field stays `.recordedValue` (default), unread.
- Re-running the migration with the gate flag already set is a no-op
  (no writes; gate-flag short-circuits).
- Re-running with the gate flag cleared is safe and idempotent.
- Per-profile gate flag isolation: setting the flag for profile A does not
  short-circuit migration for profile B.

### Balance / aggregate tests

`MoolahTests/Features/AccountBalanceCalculatorTests.swift` (extend existing):

- Investment account, recorded mode, snapshot present → balance = snapshot.
- Investment account, recorded mode, snapshot absent → balance = 0
  (does **not** fall back to summing positions; this is the regression
  guard for "auto-detect creep").
- Investment account, trades mode, positions present → balance = sum of
  positions converted to account instrument.
- Investment account, trades mode, snapshot present (but unused) →
  balance = sum of positions (snapshot is ignored).
- Non-investment account, regardless of `valuationMode` → balance = sum of
  positions (the mode field is ignored).
- `totalConverted` aggregates honour mode per account; mixed-mode profile
  totals correctly.

### `InvestmentStore` tests

`MoolahTests/Features/InvestmentStoreTests.swift` (extend existing):

- `loadAllData` with `account.valuationMode == .recordedValue` calls the
  legacy-loading path (`loadValues`, `loadDailyBalances`, `computeLegacy`).
- `loadAllData` with `account.valuationMode == .calculatedFromTrades`
  calls the trades-loading path (`loadPositions`, `valuatePositions`,
  `refreshPositionTrackedPerformance`).
- Snapshot data left over in `values` from a previous load does not affect
  the branch (the branch is on `account.valuationMode`, not on
  `values.isEmpty`).

### View tests

`MoolahUITests_macOS/InvestmentAccountView_ValuationModeTests.swift`
(or extend the existing UI test driver):

- `valuationMode == .recordedValue` → legacy layout rendered, regardless
  of whether positions exist.
- `valuationMode == .calculatedFromTrades` → trades layout rendered,
  regardless of whether snapshots exist.
- Toggling mode via the settings sheet re-renders to the new layout (and
  the toolbar does not crash — Release-only smoke test on macOS).

### Daily-balance / chart tests

`MoolahTests/Backends/GRDB/GRDBAnalysisRepositoryDailyBalancesTests.swift`
(extend):

- Investment account in recorded mode contributes snapshot folds to daily
  balances.
- Investment account in trades mode does **not** contribute snapshot folds;
  the row is filtered out of `fetchInvestmentAccountIds`.
- Mixed: profile with one of each, totals reflect each account's mode.
- Re-pin `DailyBalancesPlanPinningTests` for the new SELECT predicate.

### Settings UI

`MoolahUITests_macOS/EditAccountView_ValuationModeTests.swift`:

- Picker visible only when `type == .investment` (toggle the type picker
  and verify the valuation row appears/disappears).
- Saving the sheet with a changed mode persists through the repository.
- Cancelling does not persist.

### Intent tests

`MoolahTests/Automation/AddInvestmentValueIntentTests.swift` (extend or
create):

- `AddInvestmentValueIntent` writes a snapshot when the account is in
  trades mode (asserts the snapshot lands in CloudKit; does not assert
  any UI/balance change).

## Out-of-Scope Followups

- A "blended mode" enum case that uses snapshots before the first trade and
  trades thereafter.
- A snapshots manager reachable from trades mode.
- An automatic prompt at the end of a CSV import.
- A "valued positions over time" series so trades-mode accounts contribute
  accurately to the historical net-worth chart (the **Pre-Existing
  Limitation** above).
- A concurrent-edit warning when a sync delivery would overwrite an
  in-progress edit sheet.

## Migration & Rollout

The rollout splits into PRs in this order. Each is independently revertable.

1. **Schema + domain model + mappings.** Adds `ValuationMode`, the
   `Account.valuationMode` field, the CloudKit schema field, the GRDB
   migration, and the AccountRecord/AccountRow encode/decode. No call site
   reads the field yet. Existing accounts use the schema default
   (`.recordedValue`) — every existing investment account behaves exactly
   as before because today's auto-detect read sites still see snapshots.
2. **Migration logic.** Adds the one-shot `ValuationModeMigration` in
   profile bootstrap. After this PR, every existing investment account has
   the correct `valuationMode` for its current data — but no read site uses
   it yet, so behaviour is unchanged.
3. **Wire 5a + 5b (`AccountBalanceCalculator`).** Switch the balance
   calculator to read the mode. Sidebar, net worth totals, intents
   instantly reflect the migrated value for every account — but for every
   existing account this matches the old behaviour exactly (the migration
   set the mode to match what was there).
4. **Wire 5c + 5d (`InvestmentAccountView` + `InvestmentStore`).** Switch
   the layout and data load. Same invariant: existing accounts behave the
   same.
5. **Wire 5e (daily-balance fold).** Filter the snapshot fold by mode.
   Existing `recordedValue` accounts unchanged; existing trades-mode
   accounts (which today get nothing useful from the fold either) also
   unchanged.
6. **Settings UI + new-account default.** Add the picker to
   `EditAccountView`; flip `AccountStore.create(...)` to default new
   investment accounts to `.calculatedFromTrades`. **This is the first PR
   that lets a user observably change behaviour.**

The new-account default change in PR 6 is what we delay until everything
is wired. Existing-account migration in PR 2 is silent because every
read site is still on auto-detect at that point and the migration sets
the mode to match.

Each PR runs the relevant review agent (`code-review`,
`database-schema-review`, `database-code-review`, `concurrency-review`,
`sync-review`, `ui-review`, `instrument-conversion-review` as
applicable) before opening, per project policy. Each PR opens through
the `merge-queue` skill, per project policy.
