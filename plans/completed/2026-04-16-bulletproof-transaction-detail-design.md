# Bulletproof Transaction Detail View — Design Spec

## Problem

The transaction detail view is the most complex and most important part of the application. It has accumulated bugs, especially since multi-leg (custom) transaction support was added. The root cause is that business logic lives in the 957-line SwiftUI view where it can't be unit tested, and the draft model maintains two parallel data representations (simple fields vs `legDrafts`) with error-prone conversion between them.

## Approach

Unify the data model so `TransactionDraft` always stores legs internally, move all business logic out of the view and into the draft, and cover every state transition with exhaustive unit tests.

---

## Data Model

### TransactionDraft — Stored Properties

```swift
struct TransactionDraft: Sendable, Equatable {
    // Shared fields (both simple and custom modes)
    var payee: String
    var date: Date
    var notes: String
    var isRepeating: Bool
    var recurPeriod: RecurPeriod?
    var recurEvery: Int

    // Presentation mode flag — controls which UI renders, not which data is active
    var isCustom: Bool

    // Always populated — even simple transactions store their data here
    var legDrafts: [LegDraft]

    // Pinned at init or when switching to simple mode
    // Only meaningful when isCustom == false
    var relevantLegIndex: Int

    // Set at init, does not change
    let viewingAccountId: UUID?
}
```

**Removed properties:** `type`, `accountId`, `toAccountId`, `amountText`, `categoryId`, `earmarkId`, `categoryText`, `toAmountText`. These become computed accessors.

### LegDraft

Unchanged from today:

```swift
struct LegDraft: Sendable, Equatable {
    var type: TransactionType
    var accountId: UUID?
    var amountText: String       // Stores the display value (negated for expense/transfer)
    var categoryId: UUID?
    var categoryText: String
    var earmarkId: UUID?
}
```

### Two Leg Concepts (Simple Mode)

- **Primary leg:** Always `legDrafts[0]`. Owns category and earmark. The "canonical" leg for metadata.
- **Relevant leg:** `legDrafts[relevantLegIndex]`. Determines the amount the user sees. May or may not be the primary leg.

For income/expense (1 leg): primary and relevant are both index 0.

For simple transfers (2 legs): primary is always index 0. Relevant is determined by `viewingAccountId`.

### Computed Accessors (Simple Mode)

Convenience accessors that delegate to the appropriate leg:

- `type` → reads from `legDrafts[relevantLegIndex].type` (read-only; mutations go through `setType(_:accounts:)` which handles adding/removing counterpart legs)
- `accountId` → reads/writes `legDrafts[relevantLegIndex].accountId`
- `amountText` → reads from `legDrafts[relevantLegIndex].amountText` (mutations go through `setAmount(_:)` which handles counterpart mirroring for transfers)
- `categoryId`, `categoryText`, `earmarkId` → read/write `legDrafts[0]` (primary leg, always)
- `toAccountId` → reads/writes the leg that is NOT the primary (index 1)
- `showFromAccount: Bool` — computed property for whether the "other account" label should say "From Account" (true when viewing from the counterpart's perspective) vs "To Account"

---

## Amount Sign Convention

### The Negation Rule

The sign lives on `TransactionLeg.quantity`, not on the leg type. A leg's type doesn't determine its sign:
- Expense with `quantity: -50` = normal purchase
- Expense with `quantity: +10` = refund
- The type is the category of transaction; the sign is the direction of money flow

### Display Convention

For display purposes, amounts are negated based on leg type:
- **Expense/Transfer legs:** display = negated quantity (so `-50` shows as `50`, `+10` shows as `-10`)
- **Income/Opening Balance legs:** display = quantity as-is

This rule applies universally — both in simple mode (for the relevant leg) and in custom mode (for each leg individually).

### Storage in LegDraft

`amountText` stores the **display value** — exactly what the user sees and types. No transformation on read.

### Conversion Flow

**Init (Transaction → Draft):**
1. Read `leg.quantity` (signed)
2. Negate for expense/transfer types
3. Format as string → `amountText`

**Save (Draft → Transaction):**
1. Parse `amountText` as Decimal
2. Negate for expense/transfer types
3. Result is the signed `quantity` on the TransactionLeg

**Type change:** Display value stays fixed. Since the negation rule may change, the underlying quantity changes. The user typed "50" and still sees "50" — switching from expense to income means the money direction flips, not the number.

---

## `isSimple` Definition

```
legs.count == 1
    → simple

legs.count == 2
    && both legs have type .transfer
    && quantities negate each other (a.quantity == -b.quantity)
    && second leg has nil categoryId
    && second leg has nil earmarkId
    && legs have different accountIds
    → simple

otherwise → not simple
```

The first leg (primary) may have category and earmark. The second leg must not.

---

## Relevant Leg Pinning

### Rules

- With `viewingAccountId`: index of the leg whose `accountId` matches
- Without `viewingAccountId`: index 0

### When Pinned

- At `init(from: transaction, viewingAccountId:)` if the transaction is simple
- When switching from custom to simple mode (re-pinned using the same rules)
- NOT pinned for custom mode (the concept doesn't apply)

### Stability

Once pinned, `relevantLegIndex` does not change during editing in simple mode. Even if the user changes the amount sign, the relevant leg stays the same. This is critical — the relevant leg represents the user's viewing perspective, not a property of the data.

---

## Editing Operations (Simple Mode)

All methods live on `TransactionDraft`. The view calls them; it does not contain this logic.

### `setType(_ newType:, accounts:)`

- If changing **to** `.transfer` and only 1 leg: append a counterpart leg with a default account (first same-currency account that isn't the relevant leg's account), counterpart `amountText` = parse-negate-format of relevant leg's amount, type `.transfer`. Set existing leg's type to `.transfer`.
- If changing **from** `.transfer`: remove the counterpart leg. Update remaining leg's type.
- Between income/expense (or income/transfer): update type on all legs. Display text stays the same; the underlying quantity will differ at conversion time because the negation rule changed.

### `setAmount(_ text:)`

- Update `legDrafts[relevantLegIndex].amountText = text`
- If simple transfer: parse the text, negate, format → set on counterpart leg. If unparseable, set counterpart to `""` (invalid).

### `setAccount(_ accountId:)`

- Update `legDrafts[relevantLegIndex].accountId = accountId`

### `setToAccount(_ accountId:)`

- Update the counterpart leg's accountId

### `setCategory(_ categoryId:, categoryText:)`

- Update `legDrafts[0].categoryId` and `.categoryText` (always primary leg)

### `setEarmark(_ earmarkId:)`

- Update `legDrafts[0].earmarkId` (always primary leg)

---

## Custom Mode Operations

### Per-Leg Editing

Each leg has its own type, account, amount (with negation per leg type), category, earmark. No mirroring between legs. No "relevant" or "primary" leg concept.

### `addLeg()`

Append `LegDraft(type: .expense, accountId: nil, amountText: "0", categoryId: nil, categoryText: "", earmarkId: nil)`.

### `removeLeg(at index:)`

Remove the leg at that index.

### Per-Leg Type Change

Display amount stays the same. Underlying quantity will change at conversion due to negation rule.

---

## Mode Switching

### Simple → Custom

- Set `isCustom = true`
- `legDrafts` stay exactly as they are
- `relevantLegIndex` becomes irrelevant (ignored)

### Custom → Simple

- Only allowed when current legs satisfy `isSimple`
- Set `isCustom = false`
- Re-pin `relevantLegIndex` using standard rules
- No data transformation — legs already satisfy simple constraints

---

## Validation

No branching on `isCustom`. Uniform rules:

- `legDrafts` must not be empty
- Every leg must have a non-nil `accountId`
- Every leg must have a parseable, non-empty `amountText`
- If `isRepeating`: `recurPeriod` must be non-nil, `recurEvery >= 1`

Returns validation errors, not just a boolean.

Zero amounts are valid. Negative display values are valid (refunds). Empty string is invalid.

---

## Conversion: `toTransaction(id:, accounts:)`

Single entry point. No branching on `isCustom`. For each leg:

1. Look up account in `accounts` → get instrument
2. Parse `amountText` as Decimal
3. Negate for expense/transfer types → signed `quantity`
4. Build `TransactionLeg`

Category and earmark are taken directly from each `LegDraft`. For simple transfers, the primary leg has them and the counterpart has nil — this is already how the draft stores them.

Returns `nil` if validation fails.

---

## Autofill

When a payee match is found (searched within the current account):

1. Build a new `TransactionDraft` from the match via `init(from: match, viewingAccountId:)`
2. Override `date` with the current draft's date
3. Replace the current draft entirely

No field-by-field merging. The match came from this account so the account context is already correct.

---

## Init

### `init(from transaction:, viewingAccountId:)`

1. Always populate `legDrafts` from all `transaction.legs`, applying the negation rule for `amountText`
2. Set `isCustom = !transaction.isSimple`
3. Pin `relevantLegIndex` if simple (using pinning rules), otherwise 0
4. Populate `payee`, `date`, `notes`, recurrence fields

### `init(accountId:)` — blank new transaction

1. Single `LegDraft(type: .expense, accountId: accountId, amountText: "0", ...)`
2. `relevantLegIndex = 0`
3. `isCustom = false`

---

## To-Account Filtering

A standalone static method (not on the draft):

```swift
static func eligibleToAccounts(from accounts: Accounts, currency: Instrument) -> [Account]
```

Filters to accounts with the same currency. Used by the view to populate the "to account" picker. Testable independently.

---

## Simple Transfer — Account Display

**With account context:**
- One picker for the "other" account (the one not matching the viewing context)
- Label: "To Account" if viewing from primary leg (index 0), "From Account" if viewing from counterpart
- Exposed as `showFromAccount: Bool` computed property on the draft

**Without account context:**
- Two pickers: "From Account" = primary leg (index 0), "To Account" = counterpart (index 1)

---

## What Stays in the View

**View owns:**
- `@State draft: TransactionDraft`
- Autocomplete UI state (suggestion visibility, highlighted indices, per-leg category dictionaries)
- Delete confirmation state
- `@FocusState` — including selecting text on focus for amount fields
- Calling `transactionStore.debouncedSave` / `transactionStore.fetchPayeeSuggestions`
- Calling `onUpdate` with `draft.toTransaction(id:, accounts:)` result
- Layout, styling, and conditional rendering based on `draft.isCustom`
- Filtering to-account picker via the static method
- Disabling "simple" mode option when legs don't satisfy `isSimple`

**View does NOT own:**
- Amount parsing or negation
- Leg selection or mirroring
- Type-change side effects (adding/removing counterpart legs)
- Validation
- Transaction conversion
- Autofill
- "From Account" vs "To Account" label decision

---

## iOS Save Path

On macOS, `onUpdate` is called on every debounced change (autosave). On iOS, `onUpdate` is only called when the user taps "Done". Both paths should use `draft.toTransaction(id:, accounts:)`. Verify during implementation that the iOS save path is correctly wired.

---

## Testing Strategy

### 1. Init from Transaction — Round-Trip Fidelity

- Simple expense → draft → transaction: quantity, type, category, earmark preserved
- Simple income → same
- Simple transfer → both legs preserved, amounts negate correctly
- Simple transfer with category/earmark on primary leg only
- Simple transfer viewed from receiving account: relevant leg is counterpart
- Simple transfer viewed from sending account: relevant leg is primary
- Complex transaction → draft (`isCustom = true`, all legs populated)
- Refund expense (positive quantity) → draft shows negative display → transaction restores positive quantity
- Zero amount round-trips correctly
- Recurrence fields round-trip

### 2. Relevant Leg Pinning

- No account context: always index 0
- With account context on primary leg: index 0
- With account context on counterpart: index 1
- Relevant leg stable when amount changes sign
- Relevant leg re-pinned correctly when switching custom → simple

### 3. Display Convention (Negation)

- Expense leg: display = negated quantity
- Income leg: display = quantity as-is
- Transfer leg: display = negated quantity
- Opening balance: display = quantity as-is
- Applied consistently per-leg in custom mode

### 4. Simple Mode Editing

- `setType` expense → income: display stays same, conversion quantity flips
- `setType` expense → transfer: counterpart leg added, counterpart amount negated
- `setType` transfer → expense: counterpart leg removed
- `setType` income → transfer: counterpart added, handles negation rule change
- `setAmount`: counterpart mirrors with parse-negate-format for transfers
- `setAmount` with unparseable text: counterpart set to empty
- `setAmount` zero: valid
- `setAmount` negative display value (refund): counterpart gets positive
- `setCategory`, `setEarmark`: writes to primary leg (index 0)
- `setToAccount`: writes to counterpart leg

### 5. Custom Mode Operations

- `addLeg`: appends blank leg with `amountText: "0"`
- `removeLeg`: removes correct index
- Per-leg type change: display stays same
- Per-leg amount edit: no mirroring

### 6. Mode Switching

- Simple → custom: legs unchanged, `isCustom` flips
- Custom → simple: only allowed when `isSimple`, re-pins relevant leg
- Custom → simple rejected when legs don't satisfy `isSimple`

### 7. Validation

- Empty `amountText` → invalid
- Valid single leg expense
- Valid simple transfer
- Missing accountId → invalid
- Recurrence: `isRepeating` requires `recurPeriod` and `recurEvery >= 1`
- Zero amount → valid
- Negative display value → valid

### 8. Autofill

- Copies everything from match except date
- Date preserved from current draft
- Result is a valid draft

### 9. `isSimple` Edge Cases

- 1 leg → simple
- 2 transfer legs, negated amounts, no category/earmark on second, different accounts → simple
- 2 transfer legs, same accountId → not simple
- 2 transfer legs, category on second → not simple
- 2 transfer legs, earmark on second → not simple
- 2 transfer legs, non-negated amounts → not simple
- Mixed types → not simple
- 3+ legs → not simple

### 10. Computed Properties

- `showFromAccount` logic for both with/without account context
- `toAccountId` accessor reads correct leg
- `categoryId`/`earmarkId` always read from primary leg

### 11. To-Account Filtering

- Returns only accounts with matching currency
- Excludes the current account (the one on the relevant leg)

---

## Existing Bugs Fixed by This Design

- `abs()` discards sign in `toTransaction` — replaced by negation rule that preserves sign direction
- `parsedQuantity` rejects zero amounts — zero is now valid
- `parsedQuantity` rejects negative display values — negative display values (refunds) now valid
- Mode switching copies data between two representations with subtle loss — single representation eliminates this
- Business logic in view is untestable — all logic moves to draft with exhaustive tests
