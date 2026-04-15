# Remove Transaction.primaryAmount Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove the `Transaction.primaryAmount` convenience accessor and replace all call sites with proper multi-leg transaction handling, fixing the transfer balance bug (#10).

**Architecture:** Introduce `ConvertedTransactionLeg` wrapper for converted leg amounts. Extend `TransactionWithBalance` with `convertedLegs` and `displayAmount`. Thread `accountId` and `InstrumentConversionService` through `TransactionStore` so running balances and display amounts are computed from the correct legs.

**Tech Stack:** Swift, SwiftUI, SwiftData

**Design spec:** `plans/2026-04-15-remove-primary-amount-design.md`

---

### Task 1: Add ConvertedTransactionLeg and Transaction.isSimple

**Files:**
- Create: `Domain/Models/ConvertedTransactionLeg.swift`
- Modify: `Domain/Models/Transaction.swift`
- Create: `MoolahTests/Domain/TransactionIsSimpleTests.swift`

- [ ] **Step 1: Write tests for Transaction.isSimple**

Create `MoolahTests/Domain/TransactionIsSimpleTests.swift`:

```swift
import Testing

@testable import Moolah

struct TransactionIsSimpleTests {
  @Test func singleLegIsSimple() {
    let tx = Transaction(
      date: Date(),
      legs: [
        TransactionLeg(
          accountId: UUID(), instrument: .defaultTestInstrument, quantity: -50,
          type: .expense, categoryId: UUID(), earmarkId: UUID())
      ])
    #expect(tx.isSimple)
  }

  @Test func twoLegTransferWithNegatedAmountsAndMatchingFieldsIsSimple() {
    let catId = UUID()
    let earId = UUID()
    let tx = Transaction(
      date: Date(),
      legs: [
        TransactionLeg(
          accountId: UUID(), instrument: .defaultTestInstrument, quantity: -100,
          type: .transfer, categoryId: catId, earmarkId: earId),
        TransactionLeg(
          accountId: UUID(), instrument: .defaultTestInstrument, quantity: 100,
          type: .transfer, categoryId: catId, earmarkId: earId),
      ])
    #expect(tx.isSimple)
  }

  @Test func twoLegTransferWithDifferentAmountsIsNotSimple() {
    let tx = Transaction(
      date: Date(),
      legs: [
        TransactionLeg(
          accountId: UUID(), instrument: .defaultTestInstrument, quantity: -100,
          type: .transfer),
        TransactionLeg(
          accountId: UUID(), instrument: .defaultTestInstrument, quantity: 80,
          type: .transfer),
      ])
    #expect(!tx.isSimple)
  }

  @Test func twoLegTransferWithDifferentCategoriesIsNotSimple() {
    let tx = Transaction(
      date: Date(),
      legs: [
        TransactionLeg(
          accountId: UUID(), instrument: .defaultTestInstrument, quantity: -100,
          type: .transfer, categoryId: UUID()),
        TransactionLeg(
          accountId: UUID(), instrument: .defaultTestInstrument, quantity: 100,
          type: .transfer, categoryId: UUID()),
      ])
    #expect(!tx.isSimple)
  }

  @Test func twoLegTransferWithDifferentEarmarksIsNotSimple() {
    let tx = Transaction(
      date: Date(),
      legs: [
        TransactionLeg(
          accountId: UUID(), instrument: .defaultTestInstrument, quantity: -100,
          type: .transfer, earmarkId: UUID()),
        TransactionLeg(
          accountId: UUID(), instrument: .defaultTestInstrument, quantity: 100,
          type: .transfer, earmarkId: UUID()),
      ])
    #expect(!tx.isSimple)
  }

  @Test func twoLegTransferWithDifferentTypesIsNotSimple() {
    let tx = Transaction(
      date: Date(),
      legs: [
        TransactionLeg(
          accountId: UUID(), instrument: .defaultTestInstrument, quantity: -100,
          type: .transfer),
        TransactionLeg(
          accountId: UUID(), instrument: .defaultTestInstrument, quantity: 100,
          type: .expense),
      ])
    #expect(!tx.isSimple)
  }

  @Test func threeLegTransactionIsNotSimple() {
    let tx = Transaction(
      date: Date(),
      legs: [
        TransactionLeg(
          accountId: UUID(), instrument: .defaultTestInstrument, quantity: -100,
          type: .transfer),
        TransactionLeg(
          accountId: UUID(), instrument: .defaultTestInstrument, quantity: 50,
          type: .transfer),
        TransactionLeg(
          accountId: UUID(), instrument: .defaultTestInstrument, quantity: 50,
          type: .transfer),
      ])
    #expect(!tx.isSimple)
  }

  @Test func emptyLegsIsSimple() {
    // Edge case: no legs. Technically meets "count <= 1" rule.
    let tx = Transaction(date: Date(), legs: [])
    #expect(tx.isSimple)
  }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `just test 2>&1 | tee .agent-tmp/test-task1.txt`
Expected: compilation errors — `isSimple` and `defaultTestInstrument` need to exist. Check if `defaultTestInstrument` already exists on `Instrument`.

Check: `grep -r 'defaultTestInstrument\|defaultTestCurrency' MoolahTests/Support/`

If `defaultTestInstrument` doesn't exist, check what test helpers are available for instruments (there is `Currency.defaultTestCurrency` — the tests may need to use the instrument from that or define a similar constant for `Instrument`).

- [ ] **Step 3: Create ConvertedTransactionLeg**

Create `Domain/Models/ConvertedTransactionLeg.swift`:

```swift
import Foundation

/// A transaction leg paired with its amount converted to a target instrument.
/// `convertedAmount` is always populated — when the leg's instrument matches
/// the target, it equals `leg.amount`.
struct ConvertedTransactionLeg: Sendable {
  let leg: TransactionLeg
  let convertedAmount: InstrumentAmount
}
```

- [ ] **Step 4: Add Transaction.isSimple**

In `Domain/Models/Transaction.swift`, add after the existing convenience accessors section:

```swift
// MARK: - Structure Queries

/// Whether this transaction has simple structure: a single leg, or exactly
/// two legs forming a basic transfer (amounts negate, all other fields match).
var isSimple: Bool {
  if legs.count <= 1 { return true }
  guard legs.count == 2 else { return false }
  let a = legs[0], b = legs[1]
  return a.quantity == -b.quantity
    && a.type == b.type
    && a.categoryId == b.categoryId
    && a.earmarkId == b.earmarkId
}
```

- [ ] **Step 5: Add the new files to project.yml if needed**

Check whether `project.yml` auto-discovers source files or lists them explicitly. If it uses a glob/directory pattern (e.g. `sources: Domain/`), no change needed. If files are listed explicitly, add the new files.

Run: `grep -A5 'sources:' project.yml | head -20`

- [ ] **Step 6: Run tests to verify they pass**

Run: `just test 2>&1 | tee .agent-tmp/test-task1.txt`
Expected: all `TransactionIsSimpleTests` pass.

- [ ] **Step 7: Check for warnings**

Use `mcp__xcode__XcodeListNavigatorIssues` with `severity: "warning"` or check the test output for warnings.

- [ ] **Step 8: Commit**

```bash
git add Domain/Models/ConvertedTransactionLeg.swift Domain/Models/Transaction.swift MoolahTests/Domain/TransactionIsSimpleTests.swift
git commit -m "feat: add ConvertedTransactionLeg and Transaction.isSimple

Introduce ConvertedTransactionLeg wrapper that pairs a leg with its
converted amount. Add Transaction.isSimple to check whether a transaction
has simple structure (single leg or basic two-leg transfer).

Part of #10

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: Extend TransactionWithBalance with convertedLegs and displayAmount

**Files:**
- Modify: `Domain/Models/Transaction.swift` (TransactionWithBalance struct, lines 182-187)

- [ ] **Step 1: Update TransactionWithBalance**

In `Domain/Models/Transaction.swift`, replace the existing `TransactionWithBalance` struct:

```swift
/// A transaction paired with converted leg amounts and the account balance after it was applied.
struct TransactionWithBalance: Sendable, Identifiable {
  let transaction: Transaction
  let convertedLegs: [ConvertedTransactionLeg]
  let displayAmount: InstrumentAmount
  let balance: InstrumentAmount

  var id: UUID { transaction.id }

  /// Returns converted legs belonging to the given account.
  func legs(forAccount accountId: UUID) -> [ConvertedTransactionLeg] {
    convertedLegs.filter { $0.leg.accountId == accountId }
  }
}
```

- [ ] **Step 2: Fix compilation errors in withRunningBalances**

The `withRunningBalances` method needs to produce the new fields. For now, create a transitional version that still uses `primaryAmount` but populates the new fields. This keeps the codebase compiling while we migrate call sites in later tasks.

Replace the existing `withRunningBalances` method:

```swift
/// Computes the running balance after each transaction.
/// Transactions must be ordered newest-first (as returned by the repository).
/// `priorBalance` is the account balance before the oldest transaction in the list.
/// `accountId` identifies which account's legs to sum for the display amount.
/// `targetInstrument` is the instrument to use for converted amounts.
/// `conversionService` converts leg amounts to the target instrument.
static func withRunningBalances(
  transactions: [Transaction],
  priorBalance: InstrumentAmount,
  accountId: UUID?,
  targetInstrument: Instrument,
  conversionService: InstrumentConversionService
) async throws -> [TransactionWithBalance] {
  var balance = priorBalance
  var result: [TransactionWithBalance] = []
  result.reserveCapacity(transactions.count)

  for transaction in transactions.reversed() {
    let convertedLegs = try await transaction.legs.asyncMap { leg in
      let converted = try await conversionService.convertAmount(
        leg.amount, to: targetInstrument, on: transaction.date)
      return ConvertedTransactionLeg(leg: leg, convertedAmount: converted)
    }

    let displayAmount: InstrumentAmount
    if let accountId {
      displayAmount = convertedLegs
        .filter { $0.leg.accountId == accountId }
        .reduce(InstrumentAmount.zero(instrument: targetInstrument)) { $0 + $1.convertedAmount }
    } else {
      // No account context (scheduled view): use negative-quantity leg for transfers,
      // otherwise sum all legs
      let isTransfer = transaction.legs.contains { $0.type == .transfer }
      if isTransfer {
        let negativeLeg = convertedLegs.first { $0.leg.quantity < 0 }
        displayAmount = negativeLeg?.convertedAmount ?? .zero(instrument: targetInstrument)
      } else {
        displayAmount = convertedLegs
          .reduce(InstrumentAmount.zero(instrument: targetInstrument)) { $0 + $1.convertedAmount }
      }
    }

    balance += displayAmount
    result.append(TransactionWithBalance(
      transaction: transaction,
      convertedLegs: convertedLegs,
      displayAmount: displayAmount,
      balance: balance
    ))
  }

  result.reverse()
  return result
}
```

- [ ] **Step 3: Add asyncMap helper if it doesn't exist**

Check if there's an existing `asyncMap` extension on `Sequence`:

Run: `grep -r 'asyncMap' --include='*.swift' .`

If not found, add it to `Domain/Models/ConvertedTransactionLeg.swift` (or a shared extensions file):

```swift
extension Sequence {
  func asyncMap<T>(_ transform: (Element) async throws -> T) async rethrows -> [T] {
    var results: [T] = []
    for element in self {
      try await results.append(transform(element))
    }
    return results
  }
}
```

- [ ] **Step 4: Fix all compilation errors from callers of withRunningBalances**

The only caller is `TransactionStore.recomputeBalances()` at line 277. This method is synchronous but `withRunningBalances` is now async. Update `recomputeBalances` to be async and update its callers.

In `Features/Transactions/TransactionStore.swift`, change `recomputeBalances`:

```swift
private func recomputeBalances() async {
  rawTransactions.sort { a, b in
    if a.date != b.date { return a.date > b.date }
    return a.id.uuidString < b.id.uuidString
  }
  do {
    transactions = try await TransactionPage.withRunningBalances(
      transactions: rawTransactions,
      priorBalance: priorBalance,
      accountId: currentFilter.accountId,
      targetInstrument: targetInstrument,
      conversionService: conversionService
    )
  } catch {
    logger.error("Failed to compute balances: \(error.localizedDescription)")
  }
}
```

Update all callers of `recomputeBalances()` to `await recomputeBalances()`. These are in the same file:
- `create` method (lines 71, 79, 85)
- `update` method (lines 97, 105, 110)
- `delete` method (lines 162, 170)
- `fetchPage` method (line 193)

- [ ] **Step 5: Add conversionService and targetInstrument to TransactionStore**

Update the `TransactionStore` initializer and stored properties:

```swift
private let conversionService: InstrumentConversionService
private(set) var targetInstrument: Instrument

init(
  repository: TransactionRepository,
  conversionService: InstrumentConversionService,
  targetInstrument: Instrument,
  pageSize: Int = 50
) {
  self.repository = repository
  self.conversionService = conversionService
  self.targetInstrument = targetInstrument
  self.pageSize = pageSize
}
```

Also update the `priorBalance` default:

```swift
private var priorBalance: InstrumentAmount = .zero(instrument: .AUD)
```

Change this to initialize from `targetInstrument` instead. Since it's set before use in `load()` and `fetchPage()`, change `load` to reset it:

```swift
priorBalance = .zero(instrument: targetInstrument)
```

- [ ] **Step 6: Update ProfileSession to pass conversionService to TransactionStore**

In `App/ProfileSession.swift`, line 109, update:

```swift
self.transactionStore = TransactionStore(
  repository: backend.transactions,
  conversionService: backend.conversionService,
  targetInstrument: profile.currency.instrument
)
```

Check what `profile.currency.instrument` looks like — find the `Profile` type and how currency/instrument is accessed. If the profile stores a `Currency`, check if `Currency` has an `.instrument` property. If not, create the `Instrument` from the currency code.

- [ ] **Step 7: Fix compilation errors in test files**

Update all test files that create `TransactionStore` to pass `conversionService` and `targetInstrument`.

In `MoolahTests/Features/TransactionStoreTests.swift`, find `TransactionStore(repository:` and update each to:

```swift
TransactionStore(
  repository: backend.transactions,
  conversionService: FixedConversionService(),
  targetInstrument: .defaultTestInstrument
)
```

Do the same in any preview code that creates `TransactionStore` (search for `TransactionStore(repository:` across the codebase).

- [ ] **Step 8: Fix compilation errors in TransactionRepositoryContractTests**

The contract test at line 220 uses `TransactionPage.withRunningBalances` directly. Update it to use the new signature. Since the test doesn't need conversion, use `FixedConversionService()`:

```swift
let entries = try await TransactionPage.withRunningBalances(
  transactions: page1.transactions,
  priorBalance: page1.priorBalance,
  accountId: accountId,
  targetInstrument: .defaultTestInstrument,
  conversionService: FixedConversionService()
)
```

- [ ] **Step 9: Run tests to verify everything compiles and passes**

Run: `just test 2>&1 | tee .agent-tmp/test-task2.txt`
Expected: all tests pass. Check for warnings.

- [ ] **Step 10: Commit**

```bash
git add -A
git commit -m "feat: extend TransactionWithBalance with convertedLegs and displayAmount

TransactionStore now converts each leg to a target instrument and
computes displayAmount by summing legs for the filtered account.
withRunningBalances is now async and account-aware.

Part of #10

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: Update TransactionRowView to use displayAmount

**Files:**
- Modify: `Features/Transactions/Views/TransactionRowView.swift`

- [ ] **Step 1: Update TransactionRowView to accept displayAmount**

The view currently receives `balance: InstrumentAmount` from the parent. Add `displayAmount: InstrumentAmount` the same way. In `TransactionRowView.swift`:

Change the stored properties to add `displayAmount`:

```swift
struct TransactionRowView: View {
  let transaction: Transaction
  let accounts: Accounts
  let categories: Categories
  let earmarks: Earmarks
  let displayAmount: InstrumentAmount
  let balance: InstrumentAmount
  var hideEarmark: Bool = false
```

- [ ] **Step 2: Replace primaryAmount usages**

Line 55 — change:
```swift
InstrumentAmountView(amount: transaction.primaryAmount, font: .body)
```
to:
```swift
InstrumentAmountView(amount: displayAmount, font: .body)
```

Line 67 — change:
```swift
let amountStr = transaction.primaryAmount.formatted
```
to:
```swift
let amountStr = displayAmount.formatted
```

- [ ] **Step 3: Update all callers of TransactionRowView**

Search for `TransactionRowView(` across the codebase and add the `displayAmount` parameter. The caller should pass `entry.displayAmount` (from `TransactionWithBalance`).

Run: `grep -rn 'TransactionRowView(' --include='*.swift' .`

For each call site, add `displayAmount: entry.displayAmount` (or the equivalent from the `TransactionWithBalance` being iterated). Update the `#Preview` block at the bottom of `TransactionRowView.swift` too — pass a literal `InstrumentAmount`.

- [ ] **Step 4: Run tests and check for warnings**

Run: `just test 2>&1 | tee .agent-tmp/test-task3.txt`
Expected: all tests pass, no warnings in user code.

- [ ] **Step 5: Commit**

```bash
git add Features/Transactions/Views/TransactionRowView.swift
# Add any other files that call TransactionRowView
git commit -m "refactor: TransactionRowView uses displayAmount instead of primaryAmount

The row now receives a pre-computed displayAmount from TransactionWithBalance
rather than reading transaction.primaryAmount (which assumed first-leg semantics).

Part of #10

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: Update UpcomingTransactionsCard and UpcomingView

**Files:**
- Modify: `Features/Analysis/Views/UpcomingTransactionsCard.swift`
- Modify: `Features/Transactions/Views/UpcomingView.swift`

- [ ] **Step 1: Update UpcomingTransactionsCard**

The `SimpleTransactionRow` inside `UpcomingTransactionsCard.swift` uses `transaction.primaryAmount` at line 142. This view iterates `transactionStore.transactions` which are `TransactionWithBalance` entries. The `displayAmount` is already computed with scheduled-view semantics (negative-quantity leg for transfers).

At line 142, change:
```swift
Text(
  transaction.primaryAmount.quantity,
  format: .currency(code: transaction.primaryAmount.instrument.id)
)
.font(.body)
.monospacedDigit()
.foregroundStyle(transaction.primaryAmount.quantity >= 0 ? .green : .red)
```

The `SimpleTransactionRow` receives `transaction: txn.transaction` (a raw `Transaction`). It needs access to `displayAmount` instead. Either pass the `TransactionWithBalance` entry or pass `displayAmount` as a separate parameter.

Find the `SimpleTransactionRow` struct definition and update it to accept `displayAmount: InstrumentAmount`. Then update the amount display to use `displayAmount` instead of `transaction.primaryAmount`.

- [ ] **Step 2: Update UpcomingView**

In `UpcomingView.swift`, `UpcomingTransactionRow` at line 236 uses `transaction.primaryAmount`. Same pattern — the row receives `transaction: entry.transaction` but iterates `TransactionWithBalance` entries.

Update `UpcomingTransactionRow` to accept `displayAmount: InstrumentAmount` and pass `entry.displayAmount` from the caller.

At line 236, change:
```swift
InstrumentAmountView(amount: transaction.primaryAmount, font: .body)
```
to:
```swift
InstrumentAmountView(amount: displayAmount, font: .body)
```

- [ ] **Step 3: Update transfer display label**

In `UpcomingTransactionsCard.swift` and `UpcomingView.swift`, find the `displayPayee` computed properties. For transfers, change from "Transfer to X" to "Transfer from A to B". The transaction has `legs` with `accountId` on each leg — look up both account names from the `accounts` collection.

For `UpcomingTransactionsCard`, the `SimpleTransactionRow` needs access to `accounts` if it doesn't already have it. Check and add if needed.

For `UpcomingView`, `UpcomingTransactionRow` already has `accounts: Accounts`.

The transfer label logic:
```swift
if transaction.isTransfer {
  let accountNames = transaction.legs
    .compactMap { $0.accountId }
    .compactMap { accounts.by(id: $0)?.name }
  if accountNames.count == 2 {
    return "Transfer from \(accountNames[0]) to \(accountNames[1])"
  }
  // Fallback if accounts can't be resolved
  return "Transfer"
}
```

Note: for transfers, identify "from" as the leg with negative quantity and "to" as the leg with positive quantity. Don't assume leg ordering:

```swift
if transaction.isTransfer {
  let fromAccount = transaction.legs.first(where: { $0.quantity < 0 })?.accountId
  let toAccount = transaction.legs.first(where: { $0.quantity >= 0 })?.accountId
  let fromName = fromAccount.flatMap { accounts.by(id: $0)?.name } ?? "Unknown"
  let toName = toAccount.flatMap { accounts.by(id: $0)?.name } ?? "Unknown"
  return "Transfer from \(fromName) to \(toName)"
}
```

- [ ] **Step 4: Run tests and check for warnings**

Run: `just test 2>&1 | tee .agent-tmp/test-task4.txt`
Expected: all tests pass, no warnings.

- [ ] **Step 5: Commit**

```bash
git add Features/Analysis/Views/UpcomingTransactionsCard.swift Features/Transactions/Views/UpcomingView.swift
git commit -m "refactor: upcoming views use displayAmount, show 'Transfer from A to B'

Upcoming transaction rows now use displayAmount from TransactionWithBalance
instead of transaction.primaryAmount. Transfer labels updated to show
both source and destination accounts.

Part of #10

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: Update TransactionDetailView

**Files:**
- Modify: `Features/Transactions/Views/TransactionDetailView.swift`

- [ ] **Step 1: Add a helper to find the relevant leg**

The detail view needs to pick the right leg in several places. Add a private helper. The logic:
- If there's an account context (non-nil `accountId` from the viewing context), find a leg matching that account
- Otherwise (scheduled), for transfers find the leg with negative quantity; for income/expense use the first (only) leg

The `TransactionDetailView` currently doesn't receive an `accountId`. It needs one. Add an optional `viewingAccountId: UUID?` parameter to the initializer.

```swift
let viewingAccountId: UUID?

/// The leg relevant for display/editing in the current context.
private var relevantLeg: TransactionLeg? {
  if let viewingAccountId {
    return transaction.legs.first { $0.accountId == viewingAccountId }
  }
  if transaction.isTransfer {
    return transaction.legs.first { $0.quantity < 0 }
  }
  return transaction.legs.first
}
```

- [ ] **Step 2: Replace primaryAmount usages**

Line 55 (`isNewTransaction`) — change:
```swift
transaction.primaryAmount.isZero && (transaction.payee?.isEmpty ?? true)
```
to:
```swift
(relevantLeg?.amount.isZero ?? true) && (transaction.payee?.isEmpty ?? true)
```

Line 189 (instrument label) — change:
```swift
Text(transaction.primaryAmount.instrument.id).foregroundStyle(.secondary)
```
to:
```swift
Text(relevantLeg?.instrument.id ?? "").foregroundStyle(.secondary)
```

Line 489 (`saveIfValid`, `fromInstrument`) — change:
```swift
let fromInstrument = transaction.primaryAmount.instrument
```
to:
```swift
let fromInstrument = relevantLeg?.instrument ?? transaction.legs.first?.instrument ?? .AUD
```

Note: Check that `.AUD` is available as a static on `Instrument`. If not, use whatever the default instrument constant is.

- [ ] **Step 3: Update autofill to use draft.accountId for leg matching**

Line 407-409 — change:
```swift
if draft.parsedQuantity == nil || draft.parsedQuantity == 0 {
  draft.amountText = abs(match.primaryAmount.quantity).formatted(
    .number.precision(.fractionLength(2)))
}
```
to:
```swift
if draft.parsedQuantity == nil || draft.parsedQuantity == 0 {
  let matchLeg = draft.accountId.flatMap { acctId in
    match.legs.first { $0.accountId == acctId }
  } ?? match.legs.first
  if let matchLeg {
    draft.amountText = abs(matchLeg.quantity).formatted(
      .number.precision(.fractionLength(matchLeg.instrument.decimals)))
  }
}
```

- [ ] **Step 4: Add read-only guard for complex transactions**

When `!transaction.isSimple`, the form fields should be disabled. Add a computed property:

```swift
private var isEditable: Bool {
  transaction.isSimple
}
```

Apply `.disabled(!isEditable)` to the form sections that modify transaction data (type picker, amount field, account pickers, category, earmark). Keep the delete button enabled regardless.

- [ ] **Step 5: Update all callers of TransactionDetailView**

Search for `TransactionDetailView(` across the codebase and add the `viewingAccountId` parameter. Callers that show transactions in an account context should pass the account ID. Callers showing scheduled transactions should pass `nil`.

Run: `grep -rn 'TransactionDetailView(' --include='*.swift' .`

- [ ] **Step 6: Run tests and check for warnings**

Run: `just test 2>&1 | tee .agent-tmp/test-task5.txt`
Expected: all tests pass, no warnings.

- [ ] **Step 7: Commit**

```bash
git add Features/Transactions/Views/TransactionDetailView.swift
# Add any other files that call TransactionDetailView
git commit -m "refactor: TransactionDetailView uses relevant leg instead of primaryAmount

Detail view now picks the correct leg based on viewing account context.
Complex transactions (non-simple) are shown read-only. Autofill matches
the leg for the draft's account.

Part of #10

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

### Task 6: Update test assertions to use legs directly

**Files:**
- Modify: `MoolahTests/Shared/TransactionDraftTests.swift`
- Modify: `MoolahTests/Features/TransactionStoreTests.swift`
- Modify: `MoolahTests/Domain/TransactionRepositoryContractTests.swift`
- Modify: `MoolahTests/Backends/RemoteTransactionRepositoryTests.swift`
- Modify: `MoolahTests/Domain/ScheduledTransactionTests.swift`

- [ ] **Step 1: Update TransactionDraftTests.swift**

Line 189 — change:
```swift
#expect(roundTripped!.primaryAmount.quantity == original.primaryAmount.quantity)
```
to:
```swift
#expect(roundTripped!.legs.first?.quantity == original.legs.first?.quantity)
```

- [ ] **Step 2: Update TransactionStoreTests.swift**

Line 344 — change:
```swift
#expect(store.transactions[0].transaction.primaryAmount.quantity == Decimal(-7500) / 100)
```
to:
```swift
#expect(store.transactions[0].displayAmount.quantity == Decimal(-7500) / 100)
```

Line 408 — change similarly to use `displayAmount` or `legs.first?.quantity` as appropriate.

Line 646 — change:
```swift
#expect(receivedOld?.primaryAmount.quantity == Decimal(-10000) / 100)
```
to:
```swift
#expect(receivedOld?.legs.first(where: { $0.quantity < 0 })?.quantity == Decimal(-10000) / 100)
```

And similarly for `receivedNew`.

Review each `primaryAmount` usage in this file — some test the raw `Transaction` (use `legs`), some test `TransactionWithBalance` entries (can use `displayAmount`).

- [ ] **Step 3: Update TransactionRepositoryContractTests.swift**

Line 220 — the test accumulates `primaryAmount` for balance verification. This code was already updated in Task 2 Step 8 to use the new `withRunningBalances`. Verify it no longer references `primaryAmount`. If it still does, update to sum legs for the account:

```swift
let page1Sum = page1.transactions.reduce(
  InstrumentAmount.zero(instrument: .defaultTestInstrument)
) { sum, tx in
  let accountLegs = tx.legs.filter { $0.accountId == accountId }
  let legSum = accountLegs.reduce(InstrumentAmount.zero(instrument: .defaultTestInstrument)) {
    $0 + $1.amount
  }
  return sum + legSum
}
```

- [ ] **Step 4: Update RemoteTransactionRepositoryTests.swift**

Lines 49, 56, 62 — change:
```swift
#expect(transactions[0].primaryAmount.quantity == Decimal(string: "-50.23")!)
```
to:
```swift
#expect(transactions[0].legs.first?.quantity == Decimal(string: "-50.23")!)
```

Apply the same pattern to lines 56 and 62.

- [ ] **Step 5: Update ScheduledTransactionTests.swift**

Line 76 — change:
```swift
#expect(paid.primaryAmount == scheduled.primaryAmount)
```
to:
```swift
#expect(paid.legs.first?.amount == scheduled.legs.first?.amount)
```

- [ ] **Step 6: Run tests**

Run: `just test 2>&1 | tee .agent-tmp/test-task6.txt`
Expected: all tests pass.

- [ ] **Step 7: Commit**

```bash
git add MoolahTests/
git commit -m "test: replace primaryAmount assertions with direct leg access

Test assertions now check legs directly or use displayAmount from
TransactionWithBalance, removing the last references to primaryAmount
in test code.

Part of #10

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

### Task 7: Delete Transaction.primaryAmount

**Files:**
- Modify: `Domain/Models/Transaction.swift`

- [ ] **Step 1: Verify no remaining references**

Run: `grep -rn 'primaryAmount' --include='*.swift' .`

This should return zero results in production and test code (only in plan/doc files). If any remain, fix them first.

- [ ] **Step 2: Delete the accessor**

In `Domain/Models/Transaction.swift`, remove:

```swift
var primaryAmount: InstrumentAmount { legs.first?.amount ?? .zero(instrument: .AUD) }
```

- [ ] **Step 3: Run tests**

Run: `just test 2>&1 | tee .agent-tmp/test-task7.txt`
Expected: all tests pass, no compilation errors.

- [ ] **Step 4: Commit**

```bash
git add Domain/Models/Transaction.swift
git commit -m "refactor: delete Transaction.primaryAmount accessor

All call sites have been migrated to use proper multi-leg semantics.
Closes #10

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

### Task 8: Update TransactionDraft.init(from:) to not assume leg ordering

**Files:**
- Modify: `Shared/Models/TransactionDraft.swift`
- Modify: `MoolahTests/Shared/TransactionDraftTests.swift`

This is not strictly about `primaryAmount` but was identified during the audit — `TransactionDraft.init(from:)` uses `transaction.legs.first` as the "primary" leg and finds the transfer leg by excluding it. This should use the same `relevantLeg` logic.

- [ ] **Step 1: Write a test for round-tripping a transfer viewed from the destination account**

Add to `TransactionDraftTests.swift`:

```swift
@Test func roundTripTransferFromDestinationPerspective() {
  let sourceId = UUID()
  let destId = UUID()
  let instrument = Instrument.defaultTestInstrument  // or whatever the test constant is
  let original = Transaction(
    id: UUID(),
    date: Date(),
    payee: "Transfer",
    legs: [
      TransactionLeg(accountId: sourceId, instrument: instrument, quantity: -100, type: .transfer),
      TransactionLeg(accountId: destId, instrument: instrument, quantity: 100, type: .transfer),
    ]
  )

  // When viewing from the destination account, the draft should show the dest leg's perspective
  let draft = TransactionDraft(from: original, viewingAccountId: destId)
  #expect(draft.accountId == destId)
  #expect(draft.toAccountId == sourceId)
  #expect(draft.amountText == "100")  // positive quantity, displayed as absolute value
}
```

- [ ] **Step 2: Update TransactionDraft.init(from:) to accept viewingAccountId**

Add an optional `viewingAccountId` parameter. When provided, use the leg matching that account as the "primary" leg:

```swift
init(from transaction: Transaction, viewingAccountId: UUID? = nil) {
  let primaryLeg: TransactionLeg?
  if let viewingAccountId {
    primaryLeg = transaction.legs.first { $0.accountId == viewingAccountId }
  } else if transaction.isTransfer {
    primaryLeg = transaction.legs.first { $0.quantity < 0 }
  } else {
    primaryLeg = transaction.legs.first
  }
  let transferLeg = transaction.legs.first { $0.accountId != primaryLeg?.accountId }
  // ... rest of init unchanged, using primaryLeg and transferLeg
```

- [ ] **Step 3: Run tests**

Run: `just test 2>&1 | tee .agent-tmp/test-task8.txt`
Expected: all tests pass.

- [ ] **Step 4: Commit**

```bash
git add Shared/Models/TransactionDraft.swift MoolahTests/Shared/TransactionDraftTests.swift
git commit -m "refactor: TransactionDraft.init accepts viewingAccountId for leg selection

The draft initializer no longer assumes legs.first is the primary leg.
When a viewingAccountId is provided, it uses the matching leg. For
scheduled transfers without context, it picks the negative-quantity leg.

Part of #10

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

### Task 9: Update BUGS.md

**Files:**
- Modify: `BUGS.md`

- [ ] **Step 1: Remove the fixed bug**

Remove this entry from `BUGS.md`:
- "iCloud profile: transfers show incorrect balance in transaction list" — fixed by the correct leg selection in `withRunningBalances`

The "Transaction convenience accessors assume single-leg semantics" entry stays — the other four accessors (`primaryAccountId`, `type`, `categoryId`, `earmarkId`) are tracked in separate issues (#11-#14) and not yet removed.

- [ ] **Step 2: Commit**

```bash
git add BUGS.md
git commit -m "docs: remove fixed transfer balance bugs from BUGS.md

The primaryAmount accessor has been removed and running balances now
correctly use per-account leg amounts. Closes the transfer balance bug.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```
