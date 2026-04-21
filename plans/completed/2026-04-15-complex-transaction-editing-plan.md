# Complex Transaction Editing — Implementation Plan

**Date:** 2026-04-15
**Design spec:** `plans/2026-04-15-complex-transaction-editing-design.md`

## Overview

Implement custom (multi-leg) transaction editing in `TransactionDetailView`. The work is broken into sequential steps with dependencies noted. Each step should be independently testable and committable.

---

## Step 1: Profile capability + terminology renames

**Files:**
- `Domain/Models/Profile.swift`
- `MoolahTests/Domain/ProfileTests.swift`
- `Features/Transactions/Views/TransactionRowView.swift`
- `guides/UI_GUIDE.md`

**Tasks:**
1. Add `supportsComplexTransactions` computed property to `Profile`:
   ```swift
   var supportsComplexTransactions: Bool {
       backendType == .cloudKit
   }
   ```
2. Add tests in `ProfileTests.swift` for each `BackendType` value.
3. Rename "Complex transaction" to "Custom transaction" in `TransactionRowView.swift` (line 77, VoiceOver label).
4. Rename "Complex" to "Custom" in `guides/UI_GUIDE.md` icon table (line 546) and colour table (line 565). Only change the label — keep the symbol name (`arrow.trianglehead.branch`) and colour (`.purple`) unchanged.
5. Add custom transaction form pattern and sub-transaction terminology to style guide section 6, under the existing "Transaction Detail Form" subsection. Include the custom mode form section order (Type → Details → Sub-transactions → Recurrence → Notes → Pay → Delete) and the terminology convention ("Sub-transactions" for section headers/buttons, "Custom" for the type picker label, "legs" in code).

**Dependencies:** None. This step is self-contained.

---

## Step 2: Extend TransactionDraft with LegDraft and custom mode

**Files:**
- `Shared/Models/TransactionDraft.swift`
- `MoolahTests/Shared/TransactionDraftTests.swift`

**Tasks:**
1. Add `LegDraft` struct inside `TransactionDraft`:
   ```swift
   struct LegDraft: Sendable, Equatable {
       var type: TransactionType
       var accountId: UUID?
       var amountText: String
       var isOutflow: Bool  // For transfer legs: true = money leaving, false = money arriving
       var categoryId: UUID?
       var categoryText: String
       var earmarkId: UUID?
   }
   ```
2. Add new fields to `TransactionDraft`:
   - `var isCustom: Bool` (default `false`)
   - `var legDrafts: [LegDraft]` (default `[]`)
3. Update `init(accountId:)` (blank draft) to include `isCustom: false, legDrafts: []`.
4. Update `init(from:viewingAccountId:)` to set `isCustom = !transaction.isSimple` and populate `legDrafts` from `transaction.legs` when custom.
5. Extend `isValid`:
   - When `isCustom`: every leg draft must have a parsed amount > 0 and a non-nil account.
6. Add `toTransaction(id:accounts:)` overload for custom mode:
   - When `isCustom`: iterate `legDrafts`, look up each `accountId` in `accounts` to get the instrument, build `TransactionLeg` with the quantity from `amountText` and sign from type:
     - Income legs: positive quantity (user enters positive value).
     - Expense legs: negative quantity (user enters positive value, sign applied).
     - Transfer legs: sign depends on direction. Add `var isOutflow: Bool` to `LegDraft` (default `true`). When `true`, quantity is negative (money leaving); when `false`, quantity is positive (money arriving). The `isOutflow` field is set automatically when legs are created from a transfer or cross-currency promotion, and can be toggled by the user via a direction picker ("Outflow"/"Inflow") shown only for transfer-type legs.
   - When `!isCustom`: delegate to existing `toTransaction(id:fromInstrument:toInstrument:)`.
   - `toAmountText` is ignored when `isCustom == true`.
7. Add `applyAutofill(from:categories:supportsComplexTransactions:)`:
   - Only fills fields at default values. Specifically:
     - Amount: only filled if current amount is empty/zero.
     - Category: only filled if current category is nil.
     - Type: only overridden if current type is still `.expense`.
     - Notes: only filled if current notes are empty.
   - For simple matches: fills type, amount, account, category, earmark, notes, transfer target.
   - For custom matches with `supportsComplexTransactions`: sets `isCustom = true`, populates `legDrafts` (only if draft has no user edits to leg data).
   - For custom matches without support: copies only payee and notes.
   - Always preserves date.
8. Write tests:
   - `LegDraft` construction and equality
   - `isCustom` round-trip: init from a non-simple `Transaction`, verify `isCustom == true` and `legDrafts` populated
   - `toTransaction(id:accounts:)` in custom mode: verify legs built correctly with correct signs
   - `isValid` in custom mode: all legs must be valid, partial legs are invalid
   - `applyAutofill` with simple match (only fills defaults, preserves user-entered values)
   - `applyAutofill` with complex match + supports = true
   - `applyAutofill` with complex match + supports = false
   - `applyAutofill` preserves notes when already filled

**Dependencies:** None (Step 1 is independent).

---

## Step 3: Thread `supportsComplexTransactions` through view hierarchy

**Files:**
- `Features/Transactions/Views/TransactionDetailView.swift`
- `Features/Transactions/Views/TransactionInspectorModifier.swift`

**Tasks:**
1. Add `supportsComplexTransactions: Bool` parameter to `TransactionDetailView.init`.
2. Add `var supportsComplexTransactions: Bool = false` to `TransactionInspectorModifier`, `OptionalTransactionInspector`, and the `View.transactionInspector(...)` extension. All three must accept and forward the parameter.
3. In `TransactionInspectorModifier.body`, pass `supportsComplexTransactions` to both macOS and iOS `TransactionDetailView` constructors.
4. Update all `transactionInspector(...)` call sites to pass `supportsComplexTransactions`:
   - `Features/Investments/Views/InvestmentAccountView.swift` (line 87)
   - `Features/Transactions/Views/UpcomingView.swift` (line 14)
   - `Features/Analysis/Views/AnalysisView.swift` (line 33)
   - `Features/Earmarks/Views/EarmarkDetailView.swift` (line 54)

   Each of these views needs access to `ProfileSession` from the environment to read `session.profile.supportsComplexTransactions`. Add `@Environment(ProfileSession.self) private var session` where not already present.
5. Update `TransactionDetailView`'s `#Preview` to pass `supportsComplexTransactions: true`.

**Dependencies:** Step 2 (TransactionDraft needs `isCustom` and `legDrafts` fields for the draft init to compile).

---

## Step 4: Type picker and `isEditable` update

**Files:**
- `Features/Transactions/Views/TransactionDetailView.swift`

**Tasks:**
1. Add private `TransactionMode` enum:
   ```swift
   private enum TransactionMode: Hashable {
       case income, expense, transfer, custom

       var displayName: String { ... }
   }
   ```
   Do not conform to `CaseIterable` — the available modes are computed from `supportsComplexTransactions`.
2. Add a computed property for available modes:
   ```swift
   private var availableModes: [TransactionMode] {
       supportsComplexTransactions
           ? [.income, .expense, .transfer, .custom]
           : [.income, .expense, .transfer]
   }
   ```
3. Add a computed binding that maps between `TransactionMode` and `draft.type`/`draft.isCustom`.
4. Replace the existing `typeSection` with:
   - Opening balance: read-only `LabeledContent` (unchanged).
   - Already-complex (`!transaction.isSimple`): read-only `LabeledContent("Type") { Text("Custom") }` with `.accessibilityHint("This transaction has custom sub-transactions and cannot be changed to a simpler type.")`.
   - Otherwise: `Picker` bound to `TransactionMode` using `availableModes`.
   - iOS: `.pickerStyle(.segmented)`.
   - macOS: default picker style.
   - Add `.accessibilityLabel("Transaction type")` to the picker.
5. **Update `isEditable`** to return `true` for custom transactions:
   ```swift
   private var isEditable: Bool {
       transaction.isSimple || draft.isCustom
   }
   ```
   This is critical — without this, the `.disabled(!isEditable)` on form sections would make complex transactions permanently read-only.
6. Wire `onChange(of: draft.isCustom)` to handle simple↔custom transitions:
   - Simple → Custom: populate `legDrafts` from current draft fields (single leg for income/expense, two legs for transfer).
   - Custom → Simple: populate draft fields from first `legDraft`. For two-leg simple transfers, map the second leg to the transfer destination.

**Dependencies:** Steps 2 and 3.

---

## Step 5: Sub-transaction sections UI

**Files:**
- `Features/Transactions/Views/TransactionDetailView.swift`

**Tasks:**
1. Add `@State var legPendingDeletion: Int?` for the delete confirmation dialog.
2. Extend the `Field` enum for focus management across dynamic leg fields:
   ```swift
   private enum Field: Hashable {
       case payee
       case amount
       case legAmount(Int)  // per-leg amount fields
   }
   ```
   This enables keyboard Tab navigation across sub-transaction amount fields on macOS.
3. Create a `subTransactionSection(index:)` method that renders a `Section` (no visible header) containing:
   - Type picker (income/expense/transfer per leg)
   - Account picker from `sortedAccounts`
   - Amount `TextField` + instrument label with `.monospacedDigit()`, focused via `.focused($focusedField, equals: .legAmount(index))`
   - `CategoryAutocompleteField` with per-leg focus tracking
   - Earmark picker
   - Delete button (only when `legDrafts.count > 1`) with `.accessibilityLabel("Delete sub-transaction")`
   - `.accessibilityLabel("Sub-transaction \(index + 1) of \(draft.legDrafts.count)")` on the section
4. Create an `addSubTransactionSection` with a `Button("Add Sub-transaction")`:
   - Defaults: `sortedAccounts.first`, `.expense`, empty amount, `categoryText: ""`, nil category/earmark.
   - `.accessibilityLabel("Add sub-transaction")`
   - Button is the sole element in the row (meets 44pt touch target on iOS).
5. Update `formContent` to conditionally show:
   - When `!draft.isCustom`: existing simple sections (unchanged).
   - When `draft.isCustom`: `typeSection` → payee field → date picker → sub-transaction sections → add button → recurrence (if applicable) → notes → pay → delete.
6. Add `.confirmationDialog` at the outermost `TransactionDetailView` body level (not on the `Form` or inside sections) for `legPendingDeletion`, to avoid iOS presentation issues.
7. Handle per-leg category autocomplete state. Use a dictionary `[Int: Bool]` for `categoryJustSelected` per leg index.
8. Update `saveIfValid()` for custom mode:
   - When `draft.isCustom`: call `draft.toTransaction(id:accounts:)` (the accounts-aware overload from Step 2). Skip the `fromInstrument`/`toInstrument`/`relevantLeg` computation entirely — that logic only applies to simple mode.
   - When `!draft.isCustom`: existing logic unchanged.

**Dependencies:** Step 4.

---

## Step 6: Cross-currency transfer auto-promotion

**Files:**
- `Features/Transactions/Views/TransactionDetailView.swift`

**Tasks:**
1. In the `onChange(of: draft.toAccountId)` handler (or create one if needed): when `draft.type == .transfer` and the from/to accounts have different instruments, automatically set `draft.isCustom = true` and populate `legDrafts` with two entries (from leg with negative amount, to leg with positive amount using the to-account's instrument).
2. Resolve instruments from `accounts` collection using `accounts.by(id:)?.positions.first?.instrument` or `accounts.by(id:)?.balance.instrument`.

**Dependencies:** Steps 4 and 5.

---

## Step 7: Update autofill to use `applyAutofill`

**Files:**
- `Features/Transactions/Views/TransactionDetailView.swift`

**Tasks:**
1. Replace the private `autofillFromPayee` method body with a call to `draft.applyAutofill(from:categories:supportsComplexTransactions:)`.
2. The `Task` wrapper and `fetchTransactionForAutofill` call remain in the view — only the field-mapping logic moves to the draft method.

**Dependencies:** Steps 2 and 5.

---

## Step 8: Update `isNewTransaction` heuristic

**Files:**
- `Features/Transactions/Views/TransactionDetailView.swift`

**Tasks:**
1. Update `isNewTransaction` to handle custom mode: when `draft.isCustom`, check that all `legDrafts` have empty/zero amounts and payee is empty.

**Dependencies:** Step 5.

---

## Step 9: Add #Preview for custom mode

**Files:**
- `Features/Transactions/Views/TransactionDetailView.swift`

**Tasks:**
1. Add a second `#Preview` block showing a non-simple transaction (e.g., two legs with different categories and accounts) with `supportsComplexTransactions: true`.

**Dependencies:** Steps 5 and 3.

---

## Parallelisation

Steps that can run concurrently:
- **Step 1** and **Step 2** are fully independent.
- **Step 3** depends on Step 2.
- **Steps 4–9** are sequential (each builds on the previous view changes in `TransactionDetailView.swift`).

Recommended execution order:
1. **Wave 1:** Steps 1 + 2 (parallel)
2. **Wave 2:** Step 3
3. **Wave 3:** Steps 4 → 5 → 6 → 7 → 8 → 9 (sequential)

Note: Step 9 (the `toTransaction(id:accounts:)` overload) was merged into Step 2 since it's draft logic. The `saveIfValid()` update that calls it was merged into Step 5 since it touches the same view code as the sub-transaction UI.
