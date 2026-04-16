# Cross-Currency Transfers UI Design

## Overview

Support cross-currency transfers in the transaction detail panel with two complementary features:

1. **Simple cross-currency transfer UI** — a streamlined view for transfers between accounts with different currencies, showing from/to amounts separately while maintaining the simple transfer UX (no exposed legs).
2. **Custom leg instrument picker** — allow each sub-transaction leg in custom mode to specify any available instrument, independent of its account's instrument.

## Feature 1: Simple Cross-Currency Transfer

### Detection

A new `Transaction.isSimpleCrossCurrencyTransfer` property identifies eligible transactions:

- Exactly 2 legs
- Both legs have type `.transfer`
- Both legs have an `accountId` (non-nil), and they differ
- Second leg has no `categoryId` or `earmarkId`
- Legs have different instruments
- Each leg's instrument matches its respective account's instrument (requires `Accounts` to verify)

This is `isSimple` without the `a.quantity == -b.quantity` constraint, plus requiring different instruments and the instrument-matches-account check.

### Draft Initialisation

`TransactionDraft.init(from:viewingAccountId:)` gains an `accounts:` parameter. When a transaction satisfies `isSimpleCrossCurrencyTransfer` and each leg's instrument matches its account's instrument, `isCustom` is set to `false` — the transaction renders in simple mode.

```swift
let isCrossCurrency = transaction.isSimpleCrossCurrencyTransfer
    && transaction.legs.allSatisfy { leg in
        guard let acctId = leg.accountId,
              let account = accounts.by(id: acctId)
        else { return false }
        return leg.instrument == account.instrument
    }

let isCustom = !(transaction.isSimple || isCrossCurrency)
```

### Amount Editing

`TransactionDraft.setAmount(_:)` stops mirroring to the counterpart leg when accounts have different instruments. Each amount is edited independently.

A new `TransactionDraft.setCounterpartAmount(_:)` method sets the counterpart leg's amount text directly.

A new `TransactionDraft.isCrossCurrencyTransfer(accounts:)` computed property returns true when both legs' accounts exist and have different instruments.

### UI Layout

The "Received" amount field and derived exchange rate appear in the account section, grouped with the "To Account" picker.

**In account context** (from account is the viewing account, hidden):

```
[Details Section]
  Payee:       Currency Exchange
  Amount:      100.00 USD
  Date:        16 Apr 2026

[Account Section]
  To Account:  AU Savings
  Received:    155.00 AUD
  ≈ 1 USD = 1.55 AUD
```

**Without account context** (both account rows visible):

```
[Details Section]
  Payee:       Currency Exchange
  Amount:      100.00 USD
  Date:        16 Apr 2026

[Account Section]
  Account:     US Checking
  To Account:  AU Savings
  Received:    155.00 AUD
  ≈ 1 USD = 1.55 AUD
```

**Label flipping:** When `showFromAccount` is true (the reversed case where the relevant leg is index 1), the label reads "Sent" instead of "Received".

**Derived rate:** Shown as a subtle label (e.g. "≈ 1 USD = 1.55 AUD") when both amounts parse to non-zero values. Hidden otherwise.

**"Received" field layout:** Use an `HStack { Text("Received") Spacer() TextField(...).multilineTextAlignment(.trailing) Text(currencyCode) }` pattern matching the recurrence "Every" field, so the label aligns with adjacent `Picker` row labels in the account section.

**Focus management:** Add a `.counterpartAmount` case to the `Field` enum. Wire focus so the primary amount field's `.onSubmit` advances to `.counterpartAmount` (when visible), and `.counterpartAmount` advances to the date picker.

**Accessibility:**
- The "Received"/"Sent" field must have `.accessibilityLabel(draft.showFromAccount ? "Sent amount" : "Received amount")` set explicitly.
- The derived rate label must have `.accessibilityLabel("Approximate exchange rate: 1 USD equals 1.55 AUD")` (computed with actual values, replacing the `≈` and `=` symbols with natural language).
- Both the "Received" field and the derived rate label must apply `.monospacedDigit()` to numeric content and trailing currency codes.

### Account Picker

The "To Account" picker removes the same-currency filter. All non-hidden accounts are eligible, excluding the from account. This replaces the current `eligibleTransferAccounts(excluding:)` filtering which restricts to same-currency.

### Edge Cases

- **Switch To Account from cross-currency to same-currency:** "Received" field disappears. Counterpart amount snaps to the negated value of the primary amount (standard mirroring resumes).
- **Switch To Account from same-currency to cross-currency:** "Received" field appears with the counterpart's current amount (which was the mirrored value). User edits to the correct received amount.
- **Both amounts zero:** Derived rate is hidden (avoid division by zero).
- **Autofill from payee:** Works as today — `applyAutofill` replaces the whole draft. If the autofilled transaction is cross-currency, both amounts populate correctly.
- **Type change from transfer while cross-currency:** When the user changes the type away from transfer (to income/expense), `setType(_:accounts:)` removes the counterpart leg as it does today. The cross-currency state is naturally cleared since only one leg remains.

### Previews

Add a `#Preview("Cross-Currency Transfer")` block showing a simple transfer between accounts with different instruments (e.g., USD checking → AUD savings). This enables visual validation of the "Received" field, derived rate label, and label flipping.

### `canSwitchToSimple`

The amount-negation check (`aVal == -bVal`) is dropped. The structural checks remain: 2 legs, both transfers, different accounts, no category/earmark on second leg. This allows both same-currency and cross-currency transfers to switch to simple mode.

### No LegDraft Changes Needed

The simple cross-currency transfer path does not need `LegDraft.instrumentId`. Instruments are derived from accounts in `toTransaction()` as today — each leg's account simply has a different instrument.

## Feature 2: Custom Leg Instrument Picker

### LegDraft Change

`LegDraft` gains an optional instrument override:

```swift
var instrumentId: String?  // nil = derive from account/earmark (current behavior)
```

### UI

A `Picker` row labeled "Currency" appears on each sub-transaction in custom mode, between the Account and Amount rows. It lists all available instruments (initially the 17 fiat currencies from `CurrencyPicker`, expanding to stocks and crypto later). The label should be revisited when non-fiat instruments are added — "Currency" is clearer for the initial fiat-only implementation, but "Instrument" may be more appropriate when stocks/crypto are supported.

The picker defaults to the account's instrument when an account is selected. When the user changes the account, the instrument resets to the new account's instrument (simple approach — no tracking of manual overrides).

The currency label next to the Amount field reflects the current instrument selection.

**Accessibility:** Add `.accessibilityHint("Overrides the currency derived from the account")` to the Currency picker row.

### Available Instruments

A new `availableInstruments: [Instrument]` parameter is passed into `TransactionDetailView`. Initially populated from the existing fiat currency list. This keeps the view decoupled from the instrument source for future expansion.

### `toTransaction()` Change

When `legDraft.instrumentId` is non-nil, resolve it from the available instruments list instead of deriving from the account/earmark. If the instrument ID doesn't resolve, return nil (invalid draft).

When nil, current behavior is preserved (derive from account/earmark).

## Negation Display Rules

Unchanged from current behavior. For cross-currency simple transfers:

- The relevant leg's amount is negated for display (same as today)
- The counterpart leg's amount is shown as-is (same as today)
- This means a transfer of 10 USD → 5 AUD stores as legs [-10 USD, +5 AUD], displays as "Amount: 10.00 USD" and "Received: 5.00 AUD"
- A reversed transfer (relevant leg is index 1) would show both values as negative — this correctly models edge cases like rejected/bounced transfers

## Scope

### In Scope
- `Transaction.isSimpleCrossCurrencyTransfer` property
- `TransactionDraft` changes: `accounts` parameter on init, `isCrossCurrencyTransfer(accounts:)`, `setCounterpartAmount(_:)`, relaxed `canSwitchToSimple`, conditional mirroring in `setAmount`
- `TransactionDetailView` changes: "Received"/"Sent" amount field in account section, derived rate label, unrestricted account picker, instrument picker on custom legs
- `LegDraft.instrumentId` for custom mode
- `toTransaction()` instrument resolution from available instruments
- Tests for all new TransactionDraft methods and Transaction properties

### Out of Scope
- Stock/crypto instrument support (future expansion of the instrument list)
- Exchange rate lookup or auto-calculation
- Multi-currency reporting or aggregation
