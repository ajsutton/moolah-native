# Deduplicate TransactionDetailView Init with TransactionDraft

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Eliminate duplicated Transaction→form-fields unpacking logic between `TransactionDetailView.init` and `TransactionDraft.init(from:)` by making the view init from a `TransactionDraft` directly.

**Architecture:** Replace TransactionDetailView's 15 individual `@State` properties (type, payee, amountText, etc.) with a single `@State private var draft: TransactionDraft`. The view's form fields bind to `$draft.type`, `$draft.payee`, etc. The `categoryText` field (which depends on `Categories` and has no equivalent in `TransactionDraft`) gets added to `TransactionDraft`. The view's `init` becomes a one-liner: `_draft = State(initialValue: TransactionDraft(from: transaction))`.

**Tech Stack:** Swift, SwiftUI

---

## File Structure

- **Modify:** `Shared/Models/TransactionDraft.swift` — Add `categoryText` field; fix hardcoded decimal precision in `init(from:)`.
- **Modify:** `Features/Transactions/Views/TransactionDetailView.swift` — Replace 15 `@State` fields with single `@State var draft: TransactionDraft`; update all bindings.
- **Modify:** `MoolahTests/Shared/TransactionDraftTests.swift` — Add test for `categoryText` population; update `makeDraft` helper.

---

### Task 1: Add `categoryText` to TransactionDraft

`TransactionDetailView` has a `@State private var categoryText: String` that tracks the display text for the selected category. This is initialized from `Categories` in the view's init and isn't in `TransactionDraft`. We need to add it so the view can init entirely from a draft.

Note: `categoryText` is a UI display string, not used by `toTransaction()`. It's purely form state.

**Files:**
- Modify: `Shared/Models/TransactionDraft.swift`
- Modify: `MoolahTests/Shared/TransactionDraftTests.swift`

- [ ] **Step 1: Add `categoryText` field to TransactionDraft**

In `Shared/Models/TransactionDraft.swift`, add `categoryText` after the existing `notes` field:

```swift
var notes: String
var categoryText: String  // Display text for category (e.g. "Groceries:Food"), not used by toTransaction
var toAmountText: String
```

- [ ] **Step 2: Update the memberwise init call sites**

The `init(from transaction:)` needs to pass `categoryText: ""` (it doesn't have access to `Categories` to resolve the path — the view will set it after init):

```swift
self.init(
  type: primaryLeg?.type == .transfer ? .transfer : (primaryLeg?.type ?? .expense),
  payee: transaction.payee ?? "",
  amountText: primaryLeg.map {
    abs($0.quantity).formatted(.number.precision(.fractionLength(2)))
  } ?? "",
  date: transaction.date,
  accountId: primaryLeg?.accountId,
  toAccountId: transferLeg?.accountId,
  categoryId: primaryLeg?.categoryId,
  earmarkId: primaryLeg?.earmarkId,
  notes: transaction.notes ?? "",
  categoryText: "",
  toAmountText: toAmountText,
  isRepeating: transaction.recurPeriod != nil && transaction.recurPeriod != .once,
  recurPeriod: transaction.recurPeriod,
  recurEvery: transaction.recurEvery ?? 1
)
```

The `init(accountId:)` blank draft also needs `categoryText: ""`.

- [ ] **Step 3: Update test helper**

In `MoolahTests/Shared/TransactionDraftTests.swift`, update `makeDraft` to pass `categoryText: ""`:

```swift
private func makeDraft(
  type: TransactionType = .expense,
  amountText: String = "10.00",
  accountId: UUID? = nil,
  toAccountId: UUID? = nil,
  toAmountText: String = "",
  isRepeating: Bool = false,
  recurPeriod: RecurPeriod? = nil,
  recurEvery: Int = 1
) -> TransactionDraft {
  TransactionDraft(
    type: type,
    payee: "Test Payee",
    amountText: amountText,
    date: Date(),
    accountId: accountId,
    toAccountId: toAccountId,
    categoryId: nil,
    earmarkId: nil,
    notes: "",
    categoryText: "",
    toAmountText: toAmountText,
    isRepeating: isRepeating,
    recurPeriod: recurPeriod,
    recurEvery: recurEvery
  )
}
```

Also update the explicit `TransactionDraft(...)` call in `testToTransactionClearsRecurrenceWhenNotRepeating` to include `categoryText: ""`.

- [ ] **Step 4: Run tests**

```bash
just test 2>&1 | tee .agent-tmp/test-task1.txt
grep -i 'failed\|error:' .agent-tmp/test-task1.txt
```

Expected: All tests pass.

- [ ] **Step 5: Commit**

```bash
git add Shared/Models/TransactionDraft.swift MoolahTests/Shared/TransactionDraftTests.swift
git commit -m "feat: add categoryText field to TransactionDraft"
```

---

### Task 2: Replace @State fields in TransactionDetailView with @State TransactionDraft

This is the core change. Replace the 13 individual `@State` properties that mirror `TransactionDraft` fields with a single `@State private var draft: TransactionDraft`. Keep the remaining `@State` properties that are purely UI concerns (showDeleteConfirmation, showPayeeSuggestions, etc.).

**Files:**
- Modify: `Features/Transactions/Views/TransactionDetailView.swift`

- [ ] **Step 1: Replace @State declarations**

Remove these `@State` lines (13-25):

```swift
@State private var type: TransactionType
@State private var payee: String
@State private var amountText: String
@State private var date: Date
@State private var accountId: UUID?
@State private var toAccountId: UUID?
@State private var categoryId: UUID?
@State private var earmarkId: UUID?
@State private var notes: String
@State private var recurPeriod: RecurPeriod?
@State private var recurEvery: Int
@State private var isRepeating: Bool
@State private var toAmountText: String = ""
```

And the `categoryText` state (line 29):

```swift
@State private var categoryText: String = ""
```

Replace all of them with:

```swift
@State private var draft: TransactionDraft
```

- [ ] **Step 2: Simplify the init**

Replace the entire state initialization block (lines 59-89) with:

```swift
var initialDraft = TransactionDraft(from: transaction)
if let catId = transaction.categoryId, let cat = categories.by(id: catId) {
  initialDraft.categoryText = categories.path(for: cat)
}
_draft = State(initialValue: initialDraft)
```

- [ ] **Step 3: Remove the computed `draft` property**

Delete the `draft` computed property (lines 97-104) and the `parsedQuantity`/`isValid` forwarding properties (lines 106-108) since they can now be accessed directly as `draft.parsedQuantity` and `draft.isValid`.

- [ ] **Step 4: Update all bindings in form sections**

Every `$type` becomes `$draft.type`, every `$payee` becomes `$draft.payee`, etc. Every read of `type` becomes `draft.type`, etc. Here is the complete mapping:

| Old | New (binding) | New (read) |
|-----|--------------|------------|
| `$type` | `$draft.type` | `draft.type` |
| `$payee` | `$draft.payee` | `draft.payee` |
| `$amountText` | `$draft.amountText` | `draft.amountText` |
| `$date` | `$draft.date` | `draft.date` |
| `$accountId` | `$draft.accountId` | `draft.accountId` |
| `$toAccountId` | `$draft.toAccountId` | `draft.toAccountId` |
| `$categoryId` | `$draft.categoryId` | `draft.categoryId` |
| `$earmarkId` | `$draft.earmarkId` | `draft.earmarkId` |
| `$notes` | `$draft.notes` | `draft.notes` |
| `$isRepeating` | `$draft.isRepeating` | `draft.isRepeating` |
| `$recurPeriod` | `$draft.recurPeriod` | `draft.recurPeriod` |
| `$recurEvery` | `$draft.recurEvery` | `draft.recurEvery` |
| `$categoryText` | `$draft.categoryText` | `draft.categoryText` |
| `$toAmountText` | `$draft.toAmountText` | `draft.toAmountText` |
| `parsedQuantity` | `draft.parsedQuantity` | — |
| `isValid` | `draft.isValid` | — |

- [ ] **Step 5: Simplify onChange handlers**

The 12 individual `.onChange` handlers for each draft field (lines 138-149) can be replaced with a single handler on the draft itself:

```swift
.onChange(of: draft) { _, _ in debouncedSave() }
```

This requires `TransactionDraft` to conform to `Equatable`. Add the conformance in `TransactionDraft.swift`:

```swift
struct TransactionDraft: Sendable, Equatable {
```

All fields are already `Equatable`-conforming value types, so the synthesized conformance works.

- [ ] **Step 6: Update saveIfValid to use draft directly**

The `saveIfValid` method currently reconstructs a draft from individual state vars. Simplify to use `self.draft` directly:

```swift
private func saveIfValid() {
  let fromInstrument = transaction.primaryAmount.instrument
  let toInstrument: Instrument?
  if draft.type == .transfer, let toAcctId = draft.toAccountId {
    let toAccountInstrument =
      accounts.by(id: toAcctId)?.positions.first?.instrument
      ?? accounts.by(id: toAcctId)?.balance.instrument
    toInstrument = toAccountInstrument
  } else {
    toInstrument = nil
  }
  guard
    let updated = draft.toTransaction(
      id: transaction.id,
      fromInstrument: fromInstrument,
      toInstrument: toInstrument)
  else { return }
  onUpdate(updated)
}
```

- [ ] **Step 7: Update autofillFromPayee**

Update the autofill method to write to `draft.*` instead of bare field names:

```swift
private func autofillFromPayee(_ selectedPayee: String) {
  Task {
    guard let match = await transactionStore.fetchTransactionForAutofill(payee: selectedPayee)
    else { return }
    if draft.parsedQuantity == nil || draft.parsedQuantity == 0 {
      draft.amountText = abs(match.primaryAmount.quantity).formatted(
        .number.precision(.fractionLength(2)))
    }
    if draft.categoryId == nil, let matchCategoryId = match.categoryId {
      draft.categoryId = matchCategoryId
      if let cat = categories.by(id: matchCategoryId) {
        categoryJustSelected = true
        draft.categoryText = categories.path(for: cat)
      }
    }
    if draft.type == .expense && match.type != .expense {
      draft.type = match.type
    }
    if draft.type == .transfer, draft.toAccountId == nil {
      let matchTransferLeg =
        match.legs.count > 1
        ? match.legs.first(where: { $0.accountId != match.primaryAccountId }) : nil
      draft.toAccountId = matchTransferLeg?.accountId
    }
  }
}
```

- [ ] **Step 8: Update payee/category suggestion methods**

These read `payee`, `categoryText`, `categoryId` — update to read from `draft`:

For payee suggestions: `payee` → `draft.payee` everywhere in `payeeVisibleSuggestions`, `acceptHighlightedPayee`.

For category suggestions: `categoryText` → `draft.categoryText`, `categoryId` → `draft.categoryId` everywhere in `categoryVisibleSuggestions`, `acceptHighlightedCategory`, `categoryOverlay`, and `categorySection`'s `.onChange(of: categoryFieldFocused)`.

- [ ] **Step 9: Update type section onChange**

The `.onChange(of: type)` inside `typeSection` that auto-sets a default toAccount needs updating:

```swift
.onChange(of: draft.type) { oldValue, newValue in
  if newValue == .transfer && draft.toAccountId == nil {
    draft.toAccountId = sortedAccounts.first { $0.id != draft.accountId }?.id
  }
}
```

- [ ] **Step 10: Update isNewTransaction**

This reads `transaction` directly, no change needed — it compares against the original transaction, not the draft.

- [ ] **Step 11: Build and run tests**

```bash
just test 2>&1 | tee .agent-tmp/test-task2.txt
grep -i 'failed\|error:' .agent-tmp/test-task2.txt
```

Expected: All tests pass.

- [ ] **Step 12: Commit**

```bash
git add Shared/Models/TransactionDraft.swift Features/Transactions/Views/TransactionDetailView.swift
git commit -m "refactor: use single @State TransactionDraft in TransactionDetailView

Replace 14 individual @State properties with a single @State draft,
eliminating duplicated Transaction-to-form-fields unpacking logic.
The view now initializes from TransactionDraft.init(from:) and binds
form fields to draft properties directly."
```

---

### Task 3: Fix hardcoded decimal precision in TransactionDraft.init(from:)

`TransactionDraft.init(from:)` uses `.fractionLength(2)` for `amountText`, but `TransactionDetailView` previously used `transaction.primaryAmount.formatNoSymbol` which respects the instrument's `decimals` property. For currencies this is always 2, but for crypto/stocks it could differ. Fix the draft init to match.

**Files:**
- Modify: `Shared/Models/TransactionDraft.swift`
- Modify: `MoolahTests/Shared/TransactionDraftTests.swift`

- [ ] **Step 1: Write a failing test**

```swift
@Test func initFromTransactionPreservesInstrumentPrecision() {
  let btc = Instrument(id: "BTC", type: .crypto, decimals: 8)
  let original = Transaction(
    date: Date(),
    legs: [
      TransactionLeg(
        accountId: accountA, instrument: btc,
        quantity: Decimal(string: "-0.00123456")!, type: .expense
      )
    ]
  )
  let draft = TransactionDraft(from: original)
  #expect(draft.amountText.contains("0.00123456"))
}
```

- [ ] **Step 2: Run to verify it fails**

```bash
just test 2>&1 | tee .agent-tmp/test-task3-fail.txt
grep 'initFromTransactionPreservesInstrumentPrecision' .agent-tmp/test-task3-fail.txt
```

Expected: FAIL — the current code formats with `.fractionLength(2)` so it would produce "0.00" or similar truncation.

- [ ] **Step 3: Fix the formatting in init(from:)**

In `TransactionDraft.init(from:)`, change the `amountText` initialization to use the instrument's decimals:

```swift
amountText: primaryLeg.map {
  abs($0.quantity).formatted(
    .number.precision(.fractionLength($0.instrument.decimals)))
} ?? "",
```

Also fix the `toAmountText` for cross-currency transfers:

```swift
if let transferLeg, primaryLeg?.instrument != transferLeg.instrument {
  toAmountText = abs(transferLeg.quantity).formatted(
    .number.precision(.fractionLength(transferLeg.instrument.decimals)))
} else {
  toAmountText = ""
}
```

- [ ] **Step 4: Run tests**

```bash
just test 2>&1 | tee .agent-tmp/test-task3.txt
grep -i 'failed\|error:' .agent-tmp/test-task3.txt
```

Expected: All tests pass including the new one.

- [ ] **Step 5: Commit**

```bash
git add Shared/Models/TransactionDraft.swift MoolahTests/Shared/TransactionDraftTests.swift
git commit -m "fix: use instrument decimal precision in TransactionDraft.init(from:)

Previously hardcoded .fractionLength(2) which truncates crypto/stock
quantities. Now uses the instrument's decimals property."
```

- [ ] **Step 6: Clean up temp files**

```bash
rm .agent-tmp/test-task*.txt
```
