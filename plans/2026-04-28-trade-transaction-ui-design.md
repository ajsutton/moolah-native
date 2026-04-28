# Trade Transaction UI — Design

**Date:** 2026-04-28
**Status:** Draft
**Author:** brainstorming session with Adrian

## Problem

Trades — exchanges of one instrument for another within a single account, e.g. `300 AUD → 20 ASX:VGS`, optionally with brokerage fees — are currently expressed as multi-leg transactions with no first-class concept. They render in `TransactionRowView` with the generic "custom" treatment (purple branch icon, "(N sub-transactions)" caption) and edit through the full multi-leg `customModeContent` editor. Both are heavier and less informative than the underlying transaction is conceptually.

This design adds a first-class `Trade` mode parallel to Income / Expense / Transfer / Custom. It preserves all existing simple-mode functionality and keeps Income / Expense / Transfer fast to enter.

## Scope

**In scope**

- New domain leg type `TransactionType.trade`.
- Detection rule, structural invariants, and round-trip storage of trade transactions.
- Dedicated `tradeModeContent` section in `TransactionDetailView` for create/edit.
- Mode-switching rules between `Trade` and the other modes.
- New row layout in `TransactionRowView`, including a generalised per-instrument amount-summing rule that applies to **all** transaction types.
- `TradeEventClassifier` rewrite to filter by `type == .trade`.
- Adapt `CapitalGainsCalculator` and `InvestmentStore+PositionsInput` to the simplified classifier.
- Test fixture and UI-test seed updates.

**Out of scope (tracked separately)**

- Updating `SelfWealthParser` to attach brokerage / GST as fee legs on the trade transaction. Tracked in [#558](https://github.com/ajsutton/moolah-native/issues/558). Today the parser emits separate single-leg `.expense` transactions; that behaviour is unchanged by this work.
- Production-data migration. There are no production-shape trade transactions yet; only test data, fixtures, and seeds need updating, and they are updated directly in this work.
- A "Convert to Trade" affordance for old-shape custom transactions. Could be added later; out of scope now.

## Design

### 1. Domain model

#### 1.1 `TransactionType.trade`

Add a new case:

```swift
enum TransactionType: String, Codable, Sendable, CaseIterable {
  case income, expense, transfer, openingBalance, trade
  // ...
}
```

- `displayName`: `"Trade"`.
- `userSelectableTypes` includes `.trade` so the mode picker can offer it.
- Trade legs preserve the natural sign of the stored quantity end-to-end: there is no display-time negation (cf. `.expense` / `.transfer`, which `TransactionDraft.displaysNegated` flips). Whether the editor field shows a positive or negative number is a per-field UI concern (see §3.2), not a per-type rule.

#### 1.2 Trade transaction shape

`Transaction.isTrade` is true iff:

- Exactly two legs have `type == .trade`, and
- Both `.trade` legs have `categoryId == nil` and `earmarkId == nil`, and
- All legs (trade legs **and** any optional fee legs) reference the same non-nil `accountId`, and
- Every non-`.trade` leg has `type == .expense` (these are "fee" legs); fee legs may carry a `categoryId` and/or `earmarkId` but otherwise have no extra constraints.

Notes / non-constraints:

- The two `.trade` legs are **not** required to have opposite signs. Same-sign and zero-quantity combinations are allowed and round-trip cleanly through storage; they're weird but the model doesn't outlaw them.
- The two `.trade` legs **may** share an instrument. Same-instrument paid/received is permissible.
- Fee legs may use any instrument; they don't have to match the account or either trade leg.
- Zero or more fee legs are allowed — if there are no fee legs, the transaction is still a trade.

`Transaction` gains:

```swift
var isTrade: Bool { /* the rule above */ }
```

`isSimple` and `isSimpleCrossCurrencyTransfer` are unchanged — a trade is neither simple nor a cross-currency transfer.

#### 1.3 Decoding compatibility

`TransactionType` is stored as its raw string. The new value `"trade"` is added to the set of valid strings. Decoding `"trade"` on a client that does not yet ship the new case throws. This is a single-user multi-device app; the rollout requirement is therefore: **ship the change to all platforms in the same release before any device starts emitting `.trade` legs.** No CloudKit schema change is required (the field is a free-form string in the leg record).

### 2. `TradeEventClassifier`

Rewrite to filter by `type == .trade` instead of inferring shape from instrument kinds.

```swift
static func classify(legs: [TransactionLeg], on date: Date,
                     hostCurrency: Instrument,
                     conversionService: any InstrumentConversionService)
  async throws -> TradeEventClassification
```

Algorithm:

1. Collect legs with `type == .trade`. If fewer than two, return an empty classification (consistent with today's "not classifiable" behaviour for shapes the classifier couldn't recognise).
2. For each `.trade` leg with a positive quantity: emit a `TradeBuyEvent`. The `costPerUnit` is `convert(otherTradeLegQty, from: otherInstrument, to: hostCurrency, on: date) / quantity` — i.e. the converted value of the *other* `.trade` leg, divided by this leg's quantity. (Same scheme as today's "non-fiat swap" branch, generalised.)
3. For each `.trade` leg with a negative quantity: emit a `TradeSellEvent`, with `proceedsPerUnit` analogous to the buy case.
4. Fee legs are ignored. Conventionally brokerage / GST *are* part of cost basis for capital-gains purposes, but folding them in is bundled with the importer work in [#558](https://github.com/ajsutton/moolah-native/issues/558) — that issue owns both the importer change and the cost-basis decision. This design preserves today's behaviour (fees excluded from cost basis), even though the new editor lets a user record fees on a single trade transaction; cost basis for such manually-entered trades will under-count fees until #558 is resolved. Documented as a known limitation.

Consumers (`CapitalGainsCalculator`, `InvestmentStore.costBasisSnapshot` via `InvestmentStore+PositionsInput`, `PositionsHistoryBuilder`) do not need logic changes — they continue to consume the classifier's output. The shape of inputs to the classifier changes (legs are typed differently) but the output shape (`TradeEventClassification`) is unchanged.

### 3. Detail view (`TransactionDetailView`)

#### 3.1 Mode picker

`TransactionDetailModeSection` extends `TransactionMode` with `.trade`, sitting between `.transfer` and `.custom`:

```swift
private enum TransactionMode: Hashable {
  case income, expense, transfer, trade, custom
}
```

`availableModes` always includes `.trade` for any transaction (no `supportsComplexTransactions` gate). The existing read-only "Custom" / "Opening Balance" fall-through cases are unchanged.

#### 3.2 `tradeModeContent`

A new top-level branch in `TransactionDetailView.modeAwareSections` parallel to `simpleModeContent` / `customModeContent` / `earmarkOnlyContent`. The brainstorm considered embedding trade-specific fields in `simpleModeContent` via conditional rendering (the way the cross-currency transfer row is folded in today), but the layout diverges enough — single shared account picker, dual paid/received rows, optional dynamic-count fee subsection — that a dedicated view is cleaner than the resulting cascade of conditionals. This matches the existing `earmarkOnlyContent` precedent.

Layout (top to bottom inside the form):

1. **Type** — the standard mode picker (§3.1). Trade is selected.
2. **Trade** section
   - `Account` row — single picker; applies to both `.trade` legs and to all fees.
   - `Paid` row — amount text field + instrument picker. Field is editable as a positive number; the draft maps it to a negative-quantity `.trade` leg.
   - `Received` row — amount text field + instrument picker. Field is editable as a positive number; the draft maps it to a positive-quantity `.trade` leg.
   - Derived-rate caption: `≈ 1 {received} = X.XX {paid}` (or vice versa, mirroring `TransactionDetailCrossCurrencyRow`'s pattern). Hidden when either side is unparseable or zero.
3. **Fee** sections — zero or more, dynamically inserted. Each fee section contains:
   - `Amount` row — text field + instrument picker.
   - `Category` row — autocomplete, same component as elsewhere.
   - `Earmark` picker — optional, "None" allowed.
   - `Remove fee` button (destructive).
4. **`+ Add fee`** button — appends a fee section initialised with quantity `0`, instrument = the account's primary instrument, no category, no earmark.
5. **Payee** field — same `PayeeAutocompleteRow` used by simple mode.
6. **Date** picker — same component used elsewhere.
7. **Notes** — same component.
8. **Recurrence** — same component, when `showRecurrence` is true.
9. **Pay** / **Delete** sections — same as other modes.

Editing semantics:

- Paid and Received fields independently editable; no auto-mirroring (unlike same-currency transfer's amount mirroring). The derived-rate caption is read-only.
- A `Trade` is **valid for save** iff: account is set, both Paid and Received amounts parse (zero allowed), and each fee row's amount parses. Trade legs may share an instrument; trade legs may have any sign combination.
- The first `+ Add fee` press is the only point at which a new fee row appears; existing fee rows persist across edits and only disappear via Remove.

#### 3.3 Mode switching

Implemented in `TransactionDraft+SimpleMode.swift` (or a new `TransactionDraft+TradeMode.swift` companion if the file size requires the split). Behaviour:

**Forward (other → Trade)**

| From      | Behaviour                                                                                              |
| --------- | ------------------------------------------------------------------------------------------------------ |
| Income    | Existing `.income` leg becomes the **Received** `.trade` leg (positive quantity preserved). New **Paid** `.trade` leg added with quantity 0, account = same, instrument = account's primary instrument. No fee. |
| Expense   | Existing `.expense` leg becomes the **Paid** `.trade` leg (its negated stored quantity preserved). New **Received** `.trade` leg added with quantity 0, account = same, instrument = account's primary instrument. No fee. |
| Transfer  | Counterpart-account leg dropped, then identical to **Expense → Trade** on the remaining (relevant) leg. No fee. |
| Custom    | Only offered when the existing legs already match the trade-shape rule (§1.2). Then no structural change — `isCustom` flips to `false`, and the picker shows Trade. |

**Reverse (Trade → other)**

| To        | Behaviour                                                                                              |
| --------- | ------------------------------------------------------------------------------------------------------ |
| Income    | Keep the **Received** `.trade` leg, retype as `.income`. Drop the Paid leg and any fees.               |
| Expense   | Keep the **Paid** `.trade` leg, retype as `.expense`. Drop the Received leg and any fees.              |
| Transfer  | Keep the **Paid** `.trade` leg, retype as `.transfer`. Add a counterpart account leg using the existing Expense → Transfer logic. Drop the Received leg and any fees. |
| Custom    | `isCustom` flips to `true`. All legs preserved (including their `.trade` types). Lossless escape hatch. |

No confirmation dialog. The lost fields are visible in the form being switched away from, so the loss is as visible as the existing Transfer ⇆ Income/Expense switches today. The debounced save provides a brief recovery window via undo navigation.

#### 3.4 Simple-mode flow unchanged

`simpleModeContent`, `earmarkOnlyContent`, `customModeContent`, the autocomplete states, payee anchor overlays, category overlays, leg-category overlays, and the existing focus / autofill discipline are not modified by this design. Income / Expense / Transfer entry remains a single-section, fast flow.

### 4. Row view (`TransactionRowView`)

#### 4.1 Iconography

A trade row uses:

- Icon: `arrow.up.arrow.down`.
- Colour: `.indigo`.

Same icon and colour for buy / sell / swap; direction is conveyed through the title verb (§4.3). The existing icons for income / expense / transfer / opening balance / custom are unchanged.

#### 4.2 Generalised amount column (applies to all transaction types)

The amount column changes its rule globally — not just for trades:

> Sum the legs that match the current scope by instrument; render each non-zero per-instrument total inline using `InstrumentAmount.formatted`, wrapping only when there isn't horizontal room.

"Current scope" is determined the same way it is today inside `TransactionPage.computeDisplayAmount`:

- An `accountId` filter is provided → match legs with `leg.accountId == accountId`.
- An `earmarkId` filter is provided → match legs with `leg.earmarkId == earmarkId`.
- Neither → match every leg in the transaction.

After filtering, group by `leg.instrument`, sum `leg.amount` per group, and emit one inline element per group whose net is non-zero.

Examples:

| Transaction                                          | Scope             | Amount column                               |
| ---------------------------------------------------- | ----------------- | ------------------------------------------- |
| `−$50 AUD` expense, Groceries category               | Account A (AUD)   | `−$50.00`                                   |
| Trade: `−$300 AUD`, `+2 ASX:BHP`, fee `−$10 USD`     | Account A (AUD)   | `−$300.00  +2 BHP  −$10.00 USD`             |
| Trade: `−$300 AUD`, `+2 ASX:BHP`, fee `−$10 AUD`     | Account A (AUD)   | `−$310.00  +2 BHP` (AUD legs sum)           |
| Cross-currency transfer: `−1000 AUD`, `+660 USD`     | Account A (AUD)   | `−$1,000.00`                                |
| Cross-currency transfer: `−1000 AUD`, `+660 USD`     | Account B (USD)   | `+$660.00 USD`                              |
| Same-currency transfer: `−$200 AUD`, `+$200 AUD`     | Unfiltered        | `−$200.00` (zero-sum fallback, see below)   |

**Zero-sum transfer fallback.** If, after filtering and grouping, every per-instrument net is zero, fall back to the existing rule: show the `.transfer` leg(s) with negative quantity. This keeps same-currency transfers in the unfiltered / scheduled view sensible, matching today's behaviour. The fallback is only triggered when *all* per-instrument sums are zero — a normal income or expense never hits it.

#### 4.3 Title

Title is built as: `{payee}{maybe-parenthetical-action}`.

- If `payee` is non-empty, the title is `payee` followed by the action sentence in parentheses, e.g. `Bob (Bought 2 ASX:BHP)`.
- If `payee` is empty, the title is the action sentence alone, e.g. `Bought 2 ASX:BHP`.

For non-trade transactions, the title rule is unchanged from today (it remains `displayPayee` as defined in `Transaction+Display.swift`).

**Action sentence selection** — uses a *scope reference instrument*:

- Account-scoped row → `account.instrument`.
- Earmark-scoped row → `earmark.instrument`.
- Unfiltered row → `profile.currency`.

Then:

- If exactly one of the two `.trade` legs has the same instrument as the reference, and that leg's quantity is **negative**: `Bought {other-amount} {other-instrument}`.
- If exactly one `.trade` leg matches the reference, and that leg's quantity is **positive**: `Sold {other-amount} {other-instrument}`.
- Otherwise (neither matches, or both match): `Swapped {paid-amount} {paid-instrument} for {received-amount} {received-instrument}`.

Examples (same trades, different scope):

| Trade legs                       | Scope ref | Title appendix                          |
| -------------------------------- | --------- | --------------------------------------- |
| `−300 AUD`, `+20 ASX:VGS`        | AUD       | `Bought 20 ASX:VGS`                     |
| `+300 AUD`, `−20 ASX:VGS`        | AUD       | `Sold 20 ASX:VGS`                       |
| `−1 ETH`, `+30,000 USDC`         | AUD       | `Swapped 1 ETH for 30,000 USDC`         |
| `−100 USD`, `+50 GBP`            | AUD       | `Swapped 100 USD for 50 GBP`            |
| `−100 USD`, `+5 ASX:VGS`         | AUD       | `Swapped 100 USD for 5 ASX:VGS`         |
| `−300 USD`, `+20 ASX:VGS`        | USD       | `Bought 20 ASX:VGS`                     |

The numeric portion uses `InstrumentAmount.formatted` for consistency with the rest of the row.

#### 4.4 Caption (metadata row)

The caption row is unchanged in structure: date · category names · earmark names. Trade rows simply have no `.trade`-leg categories or earmarks (per §1.2); fee categories / earmarks appear there normally.

#### 4.5 Balance line

Unchanged. The running-balance line below the amount column is still a single converted scalar in the target instrument, computed by `TransactionPage.withRunningBalances` per-leg-converted-to-target. For a trade, the legs sum (after conversion) to roughly the fee amount or zero — the running balance stays roughly flat across a trade, which is the correct depiction of the account's total value.

#### 4.6 View signature

`TransactionRowView` gains awareness of the scope reference instrument so it can compute the title verb. The exact wiring is an implementation detail; the new input is a value that resolves to an `Instrument` — sourced from `Account.instrument` / `Earmark.instrument` / `Profile.currency` at the call site. Existing call sites that already know `viewingAccountId` extend naturally; the unfiltered scheduled-view call site supplies the profile currency.

### 5. Tests

#### 5.1 New tests

- **`TransactionTradeShapeTests`** (Domain) — round-trip of trade transactions through `Transaction` ↔ `TransactionLeg`, `TransactionType.trade` Codable, `Transaction.isTrade` for: 2 trade legs no fee; 2 trade legs + 1 fee; 2 trade legs + multiple fees; same-instrument paid/received; same-sign trade legs; zero-quantity trade leg; rejection of: shapes with one trade leg, with categories on trade legs, with earmarks on trade legs, with mixed accounts, with non-`.expense` extra legs.
- **`TradeEventClassifierTests`** (already exists; rewrite) — the rule "filter by `type == .trade`" against fixtures covering: fiat-paid buy, fiat-paid sell, non-fiat swap, multi-fee trade, no-fee trade, one-trade-leg (returns empty), zero trade legs (returns empty).
- **`TransactionDraftTradeModeTests`** (Shared) — forward switches Income/Expense/Transfer/Custom → Trade; reverse switches Trade → Income/Expense/Transfer/Custom; Custom → Trade only when shape matches; round-trip Trade ↔ Custom is lossless.
- **`TransactionRowAmountColumnTests`** (Features) — per-instrument summation for: simple expense, simple income, same-currency transfer (account-scoped), same-currency transfer (unfiltered, zero-sum fallback), cross-currency transfer (each side's account scope), trade with fee in different fiat, trade with fee in same fiat (legs sum), non-fiat swap.
- **`TransactionRowTitleVerbTests`** (Features) — verb selection for the table in §4.3, plus payee + parenthetical concatenation.

#### 5.2 Updated tests

- `TransactionIsSimpleTests` — extend to assert that trade-shaped transactions are not `isSimple`.
- `TransactionRepositoryMultiInstTests` — coverage for storing/loading trade legs.
- `CapitalGainsCalculator` and `InvestmentStore+PositionsInput` test fixtures — switch trade fixtures to use `.trade` legs.

#### 5.3 UI tests

A new `TradeFlowUITests` test in `MoolahUITests_macOS` drives an end-to-end flow:

1. Open transaction detail.
2. Switch mode to Trade.
3. Enter Paid + Received amounts and instruments.
4. Add a fee, set its amount, instrument, and category.
5. Save and assert the row renders with the indigo trade icon and the expected title and per-instrument amount column.

This requires:

- A test seed exposing a trade-eligible account (use an existing investment-style seed if one exists; otherwise add a minimal one to `UITestSeeds.swift`).
- `accessibilityIdentifier(_:)` values on the new Trade-mode fields and the `+ Add fee` / `Remove fee` buttons, registered in `UITestSupport/`.

### 6. Open questions

None at design time. Implementation-time judgement calls (e.g. exact SwiftUI primitive for inline-with-wrap layout in the amount column; choice of `ViewThatFits` vs `Layout` vs an ad-hoc `HStack` with `.layoutPriority`) are deferred to the implementation plan.

### 7. Follow-up issues

- [#558](https://github.com/ajsutton/moolah-native/issues/558) — `SelfWealthParser` should attach brokerage / GST as fee legs on the parent trade transaction rather than emitting them as standalone `.expense` transactions. That issue also owns the decision about whether `TradeEventClassifier` should fold fees into cost basis.
