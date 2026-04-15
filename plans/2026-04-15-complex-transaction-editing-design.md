# Complex Transaction Editing — Design Spec

**Date:** 2026-04-15
**Status:** Draft

## Problem

Transactions with `isSimple == false` (multiple legs with differing properties) are currently read-only in the detail view. Users cannot edit or create complex transactions from the native app.

## Solution

Extend `TransactionDetailView` to support a "Complex" transaction mode that shows per-leg editing UI. Simple transactions continue to use the existing form.

---

## Type Picker

Replace the current menu `Picker` for transaction type with a **platform-adaptive picker**:

- **iOS:** `.pickerStyle(.segmented)` — fits well in full-width forms
- **macOS:** Default picker style (renders as menu) — segmented controls inside `Form` sections are non-standard on macOS per HIG

The picker uses a local `TransactionMode` enum to unify the type and structure selection:

```swift
private enum TransactionMode: Hashable {
    case income, expense, transfer, custom
}
```

A computed binding maps between `TransactionMode` and the draft's `type`/`isCustom` fields:
- `.income`/`.expense`/`.transfer` → `draft.isCustom = false`, `draft.type = ...`
- `.custom` → `draft.isCustom = true`

| Segment | Behaviour |
|---------|-----------|
| Income | Simple form (as today) |
| Expense | Simple form (as today) |
| Transfer | Simple form with To Account (as today) |
| Custom | Sub-transaction editing mode |

**When the transaction is already complex (`isSimple == false`):**
SwiftUI's segmented picker has no API to disable individual segments. Instead, replace the picker entirely with a read-only `LabeledContent("Type") { Text("Custom") }`. This clearly communicates that the transaction mode cannot be changed. The same read-only fallback applies on macOS (menu picker also lacks per-item disable). Add `.accessibilityHint("This transaction has custom sub-transactions and cannot be changed to a simpler type.")` to the read-only label for VoiceOver users.

**When `profile.supportsComplexTransactions == false`:** the Custom option is **not included** in the picker — it displays only Income/Expense/Transfer.

**Opening balance transactions** remain fully read-only as today.

## Profile Capability

Add a computed property to `Profile`:

```swift
var supportsComplexTransactions: Bool {
    backendType == .cloudKit
}
```

Remote/Moolah backends do not support arbitrary multi-leg transactions, so the Custom option is omitted entirely for those profiles.

`TransactionDetailView` receives a `supportsComplexTransactions: Bool` parameter. This must be threaded through `TransactionInspectorModifier` and **all other call sites** that construct `TransactionDetailView` (including `#Preview` blocks). The implementation plan should enumerate these call sites.

## Form Section Order

Both simple and complex modes follow the style guide's canonical section order:

**Simple mode:** Type → Details (payee, amount, date) → Account(s) → Category/Earmark → Recurrence → Notes → Pay → Delete *(unchanged from today)*

**Complex mode:** Type → Details (payee, date) → Sub-transaction sections → Recurrence → Notes → Pay → Delete

Notes and Recurrence remain in their standard positions after the main content, consistent with the style guide. The existing `notesSection` view is reused unchanged in complex mode.

## Sub-Transaction Sections (Complex Mode)

When "Custom" is selected, the details/account/category sections from the simple form are replaced with repeating per-leg sections. Each sub-transaction renders as its own `Form` `Section` with no visible header label (flat, unnumbered). Sections are visually separated by the standard Form section spacing. Fields within each section:

- **Type** — Picker (income/expense/transfer) per leg. Transfer is selectable per-leg (the server already supports transfer legs within complex transactions).
- **Account** — Picker from sorted accounts
- **Amount** — TextField + instrument label (derived from selected account). User enters positive values; sign is derived from type at conversion time (same convention as the existing `TransactionDraft.amountText`). Apply `.monospacedDigit()` to the amount text field and instrument label, per the style guide.
- **Category** — Autocomplete field (same component as simple view). Each leg maintains its own category focus/selection tracking state (equivalent to the existing `categoryJustSelected` flag) to prevent blur handlers from clobbering just-selected values across legs.
- **Earmark** — Picker

All sections are always expanded (flat layout, no disclosure/collapse).

### Add Sub-transaction

`Button` in its own `Section` below the last sub-transaction. Uses the default tinted button style inside a Form row (which renders in accent colour automatically on both platforms — no explicit `.foregroundStyle` override needed). The button is the sole element in the row so the full row area is tappable, meeting the 44pt minimum touch target on iOS.

**Defaults for new leg:**
- Account: `sortedAccounts.first` (first account in the sidebar ordering)
- Type: `.expense`
- Amount: zero (empty text field)
- Category: nil
- CategoryText: `""`
- Earmark: nil

### Delete Sub-transaction

A destructive `Button` shown per sub-transaction section. **Only visible when there are 2+ sub-transactions.** Hidden entirely when only one remains (a transaction must have at least one leg).

Deletion requires a `.confirmationDialog` since auto-save persists the change immediately with no undo path. The confirmation dialog is owned at the `TransactionDetailView` level (not per-section) using a `@State var legPendingDeletion: Int?` binding, to avoid iOS presentation issues with dialogs attached inside Form sections.

## Switching Between Simple and Complex

### Simple → Custom

When the user selects "Custom" in the type picker:
- The existing draft's single-leg data (type, account, amount, category, earmark) becomes the first entry in the leg drafts array.
- For transfers: both legs (from and to) become separate entries.
- The form transitions to show sub-transaction sections.

### Cross-Currency Transfers

When a transfer is between accounts with different currencies, the transaction automatically becomes a custom transaction (each leg has a different instrument, so the simple transfer form cannot represent it). The type picker switches to "Custom" and shows the two legs with their respective instruments. This happens automatically when the user selects a "To Account" with a different currency than the "From Account" while in Transfer mode.

### Complex → Simple

When the user selects Income/Expense/Transfer while in Custom mode:
- Only possible when the current legs satisfy `isSimple` (otherwise the picker is replaced with a read-only label and cannot be changed). Since the legs already fit the simple structure, no data is lost — no confirmation needed.
- The first leg draft populates the simple form fields. For two-leg simple transfers, the second leg maps to the transfer destination.

## TransactionDraft Extension

Extend the existing `TransactionDraft` struct (not a new type) with:

```swift
/// Per-leg form state for complex transactions.
struct LegDraft: Sendable, Equatable {
    var type: TransactionType
    var accountId: UUID?
    var amountText: String  // Positive values; sign derived from type at conversion time
    var categoryId: UUID?
    var categoryText: String
    var earmarkId: UUID?
}
```

New fields on `TransactionDraft`:

```swift
/// When true, the transaction uses per-leg editing (Complex mode).
var isCustom: Bool

/// Leg-level form state. Only used when `isCustom` is true.
var legDrafts: [LegDraft]
```

**Conversion to Transaction:**
- When `isCustom == false`: existing `toTransaction()` logic unchanged.
- When `isCustom == true`: build legs from `legDrafts` array. Each `LegDraft` produces a `TransactionLeg`. The instrument is resolved from the selected account. Sign is applied based on the leg's type (expense/transfer → negative, income → positive), matching the existing `toTransaction()` convention.

**Initialisation from existing transaction:**
- `init(from:viewingAccountId:)` sets `isCustom = !transaction.isSimple` and populates `legDrafts` from `transaction.legs` when complex.

**Validation (`isValid`):**
- When `isCustom`: **every** leg draft must have a parsed amount > 0 and a non-nil account. A partially-filled leg is invalid — all legs must be complete before saving.

**Note:** The existing `toAmountText` field is ignored when `isCustom == true` — each leg has its own `amountText`.

## Payee Autofill

Move autofill mapping logic from the private `autofillFromPayee` view method to a testable method on `TransactionDraft`:

```swift
/// Returns a new draft with fields populated from a matched transaction (for autofill).
/// Only fills fields that are still at their default values — user-entered data is preserved.
/// Date is always preserved from the current draft.
mutating func applyAutofill(from match: Transaction, categories: Categories, supportsComplexTransactions: Bool)
```

The method is called on the current draft and checks each field before overwriting:
- Amount: only filled if the current amount is empty/zero.
- Category: only filled if the current category is nil.
- Type: only overridden if the current type is still the default (`.expense`).
- Notes: only filled if the current notes are empty.
- For complex matches with `supportsComplexTransactions`: sets `isCustom = true` and populates `legDrafts` from the matched transaction's legs (only if the current draft has no user edits to leg data).
- For complex matches without `supportsComplexTransactions`: copies only payee and notes.
- Date is always preserved.

The view's `autofillFromPayee` calls `draft.applyAutofill(from: match, ...)` — a one-liner that replaces the current multi-step private view method.

## Auto-Save

Same debounced save pattern as the simple view. Field changes in any sub-transaction trigger the 300ms debounce → `TransactionDraft.toTransaction()` → `onUpdate` callback.

## New Transaction Detection

The existing `isNewTransaction` heuristic checks `relevantLeg?.amount.isZero` and `payee.isEmpty`. In complex mode, `relevantLeg` may not be meaningful. Update the heuristic to also check `legDrafts` when `isCustom == true`: a new complex transaction has all leg drafts with zero amounts and an empty payee. This preserves the autofocus-to-payee behaviour for newly created transactions.

## Terminology

- **UI-facing:** "Sub-transactions" — used in section headers and add button text. "Custom" — used in the type picker label.
- **Code:** "legs" — model property names (`transaction.legs`, `LegDraft`, `legDrafts`).

Update `guides/STYLE_GUIDE.md` section 6 ("Components & Patterns") under the existing "Transaction Detail Form" subsection: add the custom mode form section order variant and the sub-transaction/custom terminology convention.

## Previews

Add a `#Preview` for complex mode showing a transaction with multiple legs and `isSimple == false`, alongside the existing simple mode preview. The preview must pass the new `supportsComplexTransactions` parameter.

## Accessibility

- The type picker gets `.accessibilityLabel("Transaction type")`.
- Each sub-transaction section gets `.accessibilityLabel("Sub-transaction N of M")` for VoiceOver navigation (no visible header — the label is accessibility-only).
- Delete sub-transaction button: `.accessibilityLabel("Delete sub-transaction")`.
- Add button: `.accessibilityLabel("Add sub-transaction")`.

## Files Changed

| File | Change |
|------|--------|
| `Domain/Models/Profile.swift` | Add `supportsComplexTransactions` computed property |
| `Shared/Models/TransactionDraft.swift` | Add `LegDraft` struct, `isCustom`, `legDrafts` fields, `applyAutofill(from:)`, extend `toTransaction()` and `init(from:)` |
| `Features/Transactions/Views/TransactionDetailView.swift` | `TransactionMode` enum, platform-adaptive type picker, conditional simple/complex form, sub-transaction sections, simplified autofill call, `supportsComplexTransactions` parameter |
| `Features/Transactions/Views/TransactionInspectorModifier.swift` | Thread `supportsComplexTransactions` parameter |
| `guides/STYLE_GUIDE.md` | Add sub-transaction/custom terminology, custom transaction form pattern. Update any existing "complex transaction" references to "custom transaction" |
| `MoolahTests/Shared/TransactionDraftTests.swift` | Tests for `LegDraft`, complex mode `toTransaction()`, `applyAutofill(from:)`, round-trip from complex transaction |
| `MoolahTests/Domain/ProfileTests.swift` | Test `supportsComplexTransactions` for each backend type |
| `Features/Transactions/Views/TransactionRowView.swift` | Rename "Complex transaction" VoiceOver label to "Custom transaction" |
| `guides/STYLE_GUIDE.md` icon/colour tables | Rename "Complex" to "Custom" in transaction type icon and colour tables |

**Note:** The implementation plan should enumerate all call sites of `TransactionDetailView` to ensure `supportsComplexTransactions` is threaded through each one.

## Out of Scope

- Collapsible sub-transaction cards (tracked in `plans/FEATURE_IDEAS.md`)
- Additional template types (Trade, Dividend) — future work
- Server-side support for complex transactions via remote backend
