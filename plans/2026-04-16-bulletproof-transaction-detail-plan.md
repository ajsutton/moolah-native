# Bulletproof Transaction Detail View — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rewrite `TransactionDraft` to use a unified legs model (always stores `legDrafts`), move all business logic out of `TransactionDetailView`, and cover every state transition with exhaustive unit tests.

**Architecture:** `TransactionDraft` becomes the single source of truth — it always stores data in `legDrafts`, with computed accessors for the simple UI. All editing operations (type changes, amount mirroring, mode switching) are methods on the draft. The view becomes a thin binding layer. `InstrumentAmount.parseQuantity` is updated to handle negative values and zero.

**Tech Stack:** Swift, SwiftUI, Swift Testing framework

**Design Spec:** `plans/2026-04-16-bulletproof-transaction-detail-design.md`

---

## File Structure

| File | Action | Responsibility |
|------|--------|---------------|
| `Domain/Models/InstrumentAmount.swift` | Modify | Fix `parseQuantity` to handle negative values and zero |
| `Domain/Models/Transaction.swift` | Modify | Relax `isSimple` definition |
| `Shared/Models/TransactionDraft.swift` | Rewrite | Unified legs model, editing methods, validation |
| `Shared/Models/TransactionDraftHelpers.swift` | Create | Static `eligibleToAccounts` helper |
| `Features/Transactions/Views/TransactionDetailView.swift` | Rewrite | Thin binding layer, all logic delegated to draft |
| `MoolahTests/Shared/TransactionDraftTests.swift` | Rewrite | Exhaustive tests for new draft model |
| `MoolahTests/Domain/InstrumentAmountTests.swift` | Modify | Tests for negative/zero parsing |
| `MoolahTests/Domain/TransactionTests.swift` | Modify | Tests for relaxed `isSimple` |

---

### Task 1: Fix `InstrumentAmount.parseQuantity` to Handle Negative Values and Zero

The current implementation strips all non-numeric characters (including minus signs) via regex `[^0-9.]` and doesn't support negative or zero values. The new draft needs to parse negative display values (refunds) and zero amounts.

**Files:**
- Modify: `Domain/Models/InstrumentAmount.swift:90-97`
- Test: `MoolahTests/Domain/InstrumentAmountTests.swift`

- [ ] **Step 1: Write failing tests for negative and zero parsing**

Add to `MoolahTests/Domain/InstrumentAmountTests.swift`:

```swift
@Test func parseQuantityHandlesNegativeValues() {
  let result = InstrumentAmount.parseQuantity(from: "-25.50", decimals: 2)
  #expect(result == Decimal(string: "-25.50"))
}

@Test func parseQuantityHandlesZero() {
  let result = InstrumentAmount.parseQuantity(from: "0", decimals: 2)
  #expect(result == Decimal.zero)
}

@Test func parseQuantityHandlesNegativeZero() {
  let result = InstrumentAmount.parseQuantity(from: "-0", decimals: 2)
  #expect(result == Decimal.zero)
}

@Test func parseQuantityHandlesNegativeWithoutLeadingDigit() {
  let result = InstrumentAmount.parseQuantity(from: "-.50", decimals: 2)
  #expect(result == Decimal(string: "-0.5"))
}

@Test func parseQuantityStillRejectsNonNumeric() {
  let result = InstrumentAmount.parseQuantity(from: "abc", decimals: 2)
  #expect(result == nil)
}

@Test func parseQuantityStillRejectsEmpty() {
  let result = InstrumentAmount.parseQuantity(from: "", decimals: 2)
  #expect(result == nil)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `just test 2>&1 | tee .agent-tmp/test-parse.txt`
Expected: New negative/zero tests FAIL, existing tests still PASS

- [ ] **Step 3: Update `parseQuantity` to allow negatives and zero**

In `Domain/Models/InstrumentAmount.swift`, replace the `parseQuantity` method:

```swift
static func parseQuantity(from text: String, decimals: Int) -> Decimal? {
  let cleaned = text.replacingOccurrences(of: "[^0-9.\\-]", with: "", options: .regularExpression)
  guard !cleaned.isEmpty,
    cleaned.filter({ $0 == "." }).count <= 1,
    // Allow at most one minus sign, and only at the start
    cleaned.filter({ $0 == "-" }).count <= 1,
    !cleaned.dropFirst().contains("-"),
    let decimal = Decimal(string: cleaned)
  else { return nil }
  return decimal
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `just test 2>&1 | tee .agent-tmp/test-parse.txt`
Expected: ALL tests PASS (both new and existing)

- [ ] **Step 5: Check for compiler warnings**

Run: `mcp__xcode__XcodeListNavigatorIssues` with severity "warning"

- [ ] **Step 6: Commit**

```bash
git add Domain/Models/InstrumentAmount.swift MoolahTests/Domain/InstrumentAmountTests.swift
git commit -m "fix: allow negative values and zero in InstrumentAmount.parseQuantity"
```

---

### Task 2: Relax `Transaction.isSimple` Definition

Update `isSimple` to allow category/earmark differences between transfer legs: the second leg must have nil `categoryId` and nil `earmarkId`, but the first leg can have any values. Also reject same-account transfers.

**Files:**
- Modify: `Domain/Models/Transaction.swift:117-126`
- Test: `MoolahTests/Domain/TransactionTests.swift`

- [ ] **Step 1: Write failing tests for the relaxed definition**

Add to `MoolahTests/Domain/TransactionTests.swift`:

```swift
@Test func isSimpleAllowsCategoryOnFirstLegOnly() {
  let tx = Transaction(
    date: Date(),
    legs: [
      TransactionLeg(accountId: UUID(), instrument: .AUD, quantity: -100, type: .transfer, categoryId: UUID()),
      TransactionLeg(accountId: UUID(), instrument: .AUD, quantity: 100, type: .transfer)
    ]
  )
  #expect(tx.isSimple == true)
}

@Test func isSimpleAllowsEarmarkOnFirstLegOnly() {
  let tx = Transaction(
    date: Date(),
    legs: [
      TransactionLeg(accountId: UUID(), instrument: .AUD, quantity: -100, type: .transfer, earmarkId: UUID()),
      TransactionLeg(accountId: UUID(), instrument: .AUD, quantity: 100, type: .transfer)
    ]
  )
  #expect(tx.isSimple == true)
}

@Test func isSimpleRejectsCategoryOnSecondLeg() {
  let tx = Transaction(
    date: Date(),
    legs: [
      TransactionLeg(accountId: UUID(), instrument: .AUD, quantity: -100, type: .transfer),
      TransactionLeg(accountId: UUID(), instrument: .AUD, quantity: 100, type: .transfer, categoryId: UUID())
    ]
  )
  #expect(tx.isSimple == false)
}

@Test func isSimpleRejectsEarmarkOnSecondLeg() {
  let tx = Transaction(
    date: Date(),
    legs: [
      TransactionLeg(accountId: UUID(), instrument: .AUD, quantity: -100, type: .transfer),
      TransactionLeg(accountId: UUID(), instrument: .AUD, quantity: 100, type: .transfer, earmarkId: UUID())
    ]
  )
  #expect(tx.isSimple == false)
}

@Test func isSimpleRejectsSameAccountTransfer() {
  let acctId = UUID()
  let tx = Transaction(
    date: Date(),
    legs: [
      TransactionLeg(accountId: acctId, instrument: .AUD, quantity: -100, type: .transfer),
      TransactionLeg(accountId: acctId, instrument: .AUD, quantity: 100, type: .transfer)
    ]
  )
  #expect(tx.isSimple == false)
}

@Test func isSimpleRejectsNonNegatedAmounts() {
  let tx = Transaction(
    date: Date(),
    legs: [
      TransactionLeg(accountId: UUID(), instrument: .AUD, quantity: -100, type: .transfer),
      TransactionLeg(accountId: UUID(), instrument: .AUD, quantity: 50, type: .transfer)
    ]
  )
  #expect(tx.isSimple == false)
}

@Test func isSimpleRejectsMixedTypes() {
  let tx = Transaction(
    date: Date(),
    legs: [
      TransactionLeg(accountId: UUID(), instrument: .AUD, quantity: -100, type: .expense),
      TransactionLeg(accountId: UUID(), instrument: .AUD, quantity: 100, type: .income)
    ]
  )
  #expect(tx.isSimple == false)
}

@Test func isSimpleAcceptsSingleLeg() {
  let tx = Transaction(
    date: Date(),
    legs: [
      TransactionLeg(accountId: UUID(), instrument: .AUD, quantity: -50, type: .expense)
    ]
  )
  #expect(tx.isSimple == true)
}

@Test func isSimpleRejectsThreeLegs() {
  let tx = Transaction(
    date: Date(),
    legs: [
      TransactionLeg(accountId: UUID(), instrument: .AUD, quantity: -50, type: .expense),
      TransactionLeg(accountId: UUID(), instrument: .AUD, quantity: -30, type: .expense),
      TransactionLeg(accountId: UUID(), instrument: .AUD, quantity: 80, type: .income)
    ]
  )
  #expect(tx.isSimple == false)
}
```

- [ ] **Step 2: Run tests to verify new tests fail (the category/earmark/same-account ones)**

Run: `just test 2>&1 | tee .agent-tmp/test-simple.txt`
Expected: `isSimpleAllowsCategoryOnFirstLegOnly`, `isSimpleAllowsEarmarkOnFirstLegOnly`, `isSimpleRejectsSameAccountTransfer` FAIL; others PASS

- [ ] **Step 3: Update `isSimple`**

In `Domain/Models/Transaction.swift`, replace the `isSimple` computed property:

```swift
/// Whether this transaction has simple structure: a single leg, or exactly
/// two legs forming a basic transfer (amounts negate, same type, second leg
/// has no category/earmark, and legs reference different accounts).
var isSimple: Bool {
  if legs.count <= 1 { return true }
  guard legs.count == 2 else { return false }
  let a = legs[0]
  let b = legs[1]
  return a.quantity == -b.quantity
    && a.type == b.type
    && b.categoryId == nil
    && b.earmarkId == nil
    && a.accountId != b.accountId
}
```

- [ ] **Step 4: Run tests to verify they all pass**

Run: `just test 2>&1 | tee .agent-tmp/test-simple.txt`
Expected: ALL tests PASS

Check whether existing `TransactionDraftTests` still pass — some tests that relied on the old `isSimple` definition may need updating. If `initFromSimpleTransactionIsNotCustom` or similar tests used transfers with matching category/earmark on both legs, they'll still pass since the relaxation only affects the second leg.

- [ ] **Step 5: Check for compiler warnings**

Run: `mcp__xcode__XcodeListNavigatorIssues` with severity "warning"

- [ ] **Step 6: Commit**

```bash
git add Domain/Models/Transaction.swift MoolahTests/Domain/TransactionTests.swift
git commit -m "fix: relax isSimple to allow category/earmark on first leg only, reject same-account transfers"
```

---

### Task 3: Rewrite `TransactionDraft` Data Model — Stored Properties and Init

Replace the dual simple/custom field representation with unified legs. This task covers only the struct definition and initialisers — editing methods and conversion come in later tasks.

**Files:**
- Rewrite: `Shared/Models/TransactionDraft.swift`
- Test: `MoolahTests/Shared/TransactionDraftTests.swift`

- [ ] **Step 1: Write tests for the new init from Transaction**

Replace the contents of `MoolahTests/Shared/TransactionDraftTests.swift` with the new test structure. Start with init tests:

```swift
import Foundation
import Testing

@testable import Moolah

struct TransactionDraftTests {
  private let instrument = Instrument.defaultTestInstrument
  private let accountA = UUID()
  private let accountB = UUID()

  // MARK: - Helpers

  /// Build a simple one-leg draft for testing.
  private func makeExpenseDraft(
    amountText: String = "10.00",
    accountId: UUID? = nil
  ) -> TransactionDraft {
    TransactionDraft(
      payee: "Test",
      date: Date(),
      notes: "",
      isRepeating: false,
      recurPeriod: nil,
      recurEvery: 1,
      isCustom: false,
      legDrafts: [
        TransactionDraft.LegDraft(
          type: .expense, accountId: accountId ?? accountA,
          amountText: amountText, categoryId: nil, categoryText: "", earmarkId: nil)
      ],
      relevantLegIndex: 0,
      viewingAccountId: nil
    )
  }

  /// Build Accounts collection from a list of accounts.
  private func makeAccounts(_ accounts: [Account]) -> Accounts {
    Accounts(from: accounts)
  }

  /// Build a simple Account with given id and instrument.
  private func makeAccount(id: UUID, instrument: Instrument = .defaultTestInstrument) -> Account {
    Account(id: id, name: "Test Account", type: .bank, balance: .zero(instrument: instrument))
  }

  // MARK: - Init from Transaction: Simple Expense

  @Test func initFromSimpleExpense() {
    let categoryId = UUID()
    let earmarkId = UUID()
    let tx = Transaction(
      date: Date(timeIntervalSince1970: 1_700_000_000),
      payee: "Coffee",
      notes: "Latte",
      recurPeriod: .week,
      recurEvery: 2,
      legs: [
        TransactionLeg(
          accountId: accountA, instrument: instrument,
          quantity: Decimal(string: "-42.50")!, type: .expense,
          categoryId: categoryId, earmarkId: earmarkId)
      ]
    )

    let draft = TransactionDraft(from: tx)

    #expect(draft.isCustom == false)
    #expect(draft.legDrafts.count == 1)
    #expect(draft.relevantLegIndex == 0)
    #expect(draft.payee == "Coffee")
    #expect(draft.notes == "Latte")
    #expect(draft.date == tx.date)
    #expect(draft.isRepeating == true)
    #expect(draft.recurPeriod == .week)
    #expect(draft.recurEvery == 2)

    // Leg data: amount is negated for display (expense -42.50 → display "42.50")
    #expect(draft.legDrafts[0].type == .expense)
    #expect(draft.legDrafts[0].accountId == accountA)
    #expect(draft.legDrafts[0].amountText == "42.50")
    #expect(draft.legDrafts[0].categoryId == categoryId)
    #expect(draft.legDrafts[0].earmarkId == earmarkId)
  }

  @Test func initFromSimpleIncome() {
    let tx = Transaction(
      date: Date(),
      payee: "Salary",
      legs: [
        TransactionLeg(
          accountId: accountA, instrument: instrument,
          quantity: Decimal(string: "3000.00")!, type: .income)
      ]
    )

    let draft = TransactionDraft(from: tx)

    // Income: display = quantity as-is (positive stays positive)
    #expect(draft.legDrafts[0].type == .income)
    #expect(draft.legDrafts[0].amountText == "3000.00")
  }

  @Test func initFromRefundExpense() {
    // Refund: expense with positive quantity
    let tx = Transaction(
      date: Date(),
      legs: [
        TransactionLeg(
          accountId: accountA, instrument: instrument,
          quantity: Decimal(string: "10.00")!, type: .expense)
      ]
    )

    let draft = TransactionDraft(from: tx)

    // Expense display is negated: -(+10) = -10
    #expect(draft.legDrafts[0].amountText == "-10.00")
  }

  @Test func initFromZeroAmount() {
    let tx = Transaction(
      date: Date(),
      legs: [
        TransactionLeg(
          accountId: accountA, instrument: instrument,
          quantity: Decimal.zero, type: .expense)
      ]
    )

    let draft = TransactionDraft(from: tx)
    #expect(draft.legDrafts[0].amountText == "0")
  }

  // MARK: - Init from Transaction: Simple Transfer

  @Test func initFromSimpleTransferNoContext() {
    let tx = Transaction(
      date: Date(),
      payee: "Transfer",
      legs: [
        TransactionLeg(accountId: accountA, instrument: instrument, quantity: -100, type: .transfer),
        TransactionLeg(accountId: accountB, instrument: instrument, quantity: 100, type: .transfer),
      ]
    )

    let draft = TransactionDraft(from: tx)

    #expect(draft.isCustom == false)
    #expect(draft.legDrafts.count == 2)
    // No context: relevant leg is index 0 (the primary leg)
    #expect(draft.relevantLegIndex == 0)
    // Both legs populated
    #expect(draft.legDrafts[0].accountId == accountA)
    #expect(draft.legDrafts[0].amountText == "100.00")  // -(-100) = 100
    #expect(draft.legDrafts[1].accountId == accountB)
    #expect(draft.legDrafts[1].amountText == "-100.00")  // -(+100) = -100
  }

  @Test func initFromSimpleTransferViewingFromSource() {
    let tx = Transaction(
      date: Date(),
      legs: [
        TransactionLeg(accountId: accountA, instrument: instrument, quantity: -100, type: .transfer),
        TransactionLeg(accountId: accountB, instrument: instrument, quantity: 100, type: .transfer),
      ]
    )

    let draft = TransactionDraft(from: tx, viewingAccountId: accountA)

    // Source account is at index 0, so relevant leg = 0
    #expect(draft.relevantLegIndex == 0)
    #expect(draft.legDrafts[0].amountText == "100.00")
  }

  @Test func initFromSimpleTransferViewingFromDestination() {
    let tx = Transaction(
      date: Date(),
      legs: [
        TransactionLeg(accountId: accountA, instrument: instrument, quantity: -100, type: .transfer),
        TransactionLeg(accountId: accountB, instrument: instrument, quantity: 100, type: .transfer),
      ]
    )

    let draft = TransactionDraft(from: tx, viewingAccountId: accountB)

    // Destination account is at index 1, so relevant leg = 1
    #expect(draft.relevantLegIndex == 1)
    // Display: -(+100) = -100
    #expect(draft.legDrafts[draft.relevantLegIndex].amountText == "-100.00")
  }

  @Test func initFromSimpleTransferWithCategoryOnFirstLeg() {
    let categoryId = UUID()
    let earmarkId = UUID()
    let tx = Transaction(
      date: Date(),
      legs: [
        TransactionLeg(
          accountId: accountA, instrument: instrument, quantity: -100, type: .transfer,
          categoryId: categoryId, earmarkId: earmarkId),
        TransactionLeg(accountId: accountB, instrument: instrument, quantity: 100, type: .transfer),
      ]
    )

    #expect(tx.isSimple == true)
    let draft = TransactionDraft(from: tx)
    #expect(draft.isCustom == false)
    // Category/earmark on primary leg (index 0)
    #expect(draft.legDrafts[0].categoryId == categoryId)
    #expect(draft.legDrafts[0].earmarkId == earmarkId)
    // Counterpart has nil
    #expect(draft.legDrafts[1].categoryId == nil)
    #expect(draft.legDrafts[1].earmarkId == nil)
  }

  // MARK: - Init from Transaction: Complex

  @Test func initFromComplexTransaction() {
    let catId = UUID()
    let tx = Transaction(
      date: Date(),
      payee: "Split",
      legs: [
        TransactionLeg(
          accountId: accountA, instrument: instrument, quantity: -100, type: .expense,
          categoryId: catId),
        TransactionLeg(accountId: accountB, instrument: instrument, quantity: -50, type: .expense),
        TransactionLeg(accountId: UUID(), instrument: instrument, quantity: 150, type: .income),
      ]
    )
    #expect(!tx.isSimple)

    let draft = TransactionDraft(from: tx)
    #expect(draft.isCustom == true)
    #expect(draft.legDrafts.count == 3)
    // Expense legs: display is negated
    #expect(draft.legDrafts[0].amountText == "100.00")
    #expect(draft.legDrafts[0].categoryId == catId)
    #expect(draft.legDrafts[1].amountText == "50.00")
    // Income leg: display is as-is
    #expect(draft.legDrafts[2].amountText == "150.00")
  }

  // MARK: - Init Blank

  @Test func initBlankTransaction() {
    let draft = TransactionDraft(accountId: accountA)

    #expect(draft.isCustom == false)
    #expect(draft.legDrafts.count == 1)
    #expect(draft.relevantLegIndex == 0)
    #expect(draft.legDrafts[0].type == .expense)
    #expect(draft.legDrafts[0].accountId == accountA)
    #expect(draft.legDrafts[0].amountText == "0")
    #expect(draft.payee == "")
    #expect(draft.notes == "")
    #expect(draft.isRepeating == false)
  }

  // MARK: - Init with Instrument Precision

  @Test func initPreservesCryptoPrecision() {
    let btc = Instrument.crypto(
      chainId: 0, contractAddress: nil, symbol: "BTC", name: "Bitcoin", decimals: 8)
    let tx = Transaction(
      date: Date(),
      legs: [
        TransactionLeg(
          accountId: accountA, instrument: btc,
          quantity: Decimal(string: "-0.00123456")!, type: .expense)
      ]
    )
    let draft = TransactionDraft(from: tx)
    #expect(draft.legDrafts[0].amountText.contains("0.00123456"))
  }
}
```

- [ ] **Step 2: Rewrite `TransactionDraft` struct with new stored properties**

Replace the contents of `Shared/Models/TransactionDraft.swift`:

```swift
import Foundation

/// A value type that captures transaction form state and encapsulates
/// validation, editing, and conversion logic. The view binds to this;
/// all business logic lives here so it can be unit-tested without a UI host.
///
/// Data is always stored in `legDrafts` — even simple transactions.
/// `isCustom` controls which UI renders, not which data is active.
struct TransactionDraft: Sendable, Equatable {
  // MARK: - Shared Fields

  var payee: String
  var date: Date
  var notes: String
  var isRepeating: Bool
  var recurPeriod: RecurPeriod?
  var recurEvery: Int

  /// Presentation mode: controls whether the UI shows simple or custom editor.
  var isCustom: Bool

  /// Always populated — even simple 1-leg transactions store their data here.
  var legDrafts: [LegDraft]

  /// Index of the leg the simple UI edits. Only meaningful when `isCustom == false`.
  /// Pinned at init or when switching from custom to simple mode.
  var relevantLegIndex: Int

  /// The account perspective for this editing session. Set at init, does not change.
  let viewingAccountId: UUID?

  // MARK: - LegDraft

  /// A draft for a single leg in a transaction.
  struct LegDraft: Sendable, Equatable {
    var type: TransactionType
    var accountId: UUID?
    /// The display value — negated for expense/transfer types.
    /// This is exactly what the user sees in the text field.
    var amountText: String
    var categoryId: UUID?
    var categoryText: String
    var earmarkId: UUID?
  }

  // MARK: - Negation Helpers

  /// Whether a leg type uses negated display (expense, transfer → negate; income, openingBalance → as-is).
  static func displaysNegated(_ type: TransactionType) -> Bool {
    switch type {
    case .expense, .transfer: return true
    case .income, .openingBalance: return false
    }
  }

  /// Convert a leg quantity to display text using the negation rule.
  static func displayText(quantity: Decimal, type: TransactionType, decimals: Int) -> String {
    let displayValue = displaysNegated(type) ? -quantity : quantity
    return displayValue.formatted(.number.precision(.fractionLength(decimals)))
  }

  /// Parse display text back to a signed quantity using the negation rule.
  /// Returns nil if the text can't be parsed.
  static func parseDisplayText(_ text: String, type: TransactionType, decimals: Int) -> Decimal? {
    guard let parsed = InstrumentAmount.parseQuantity(from: text, decimals: decimals) else {
      return nil
    }
    return displaysNegated(type) ? -parsed : parsed
  }
}

// MARK: - Computed Accessors (Simple Mode)

extension TransactionDraft {
  /// The leg the simple UI binds to for amount display/editing.
  var relevantLeg: LegDraft {
    get { legDrafts[relevantLegIndex] }
    set { legDrafts[relevantLegIndex] = newValue }
  }

  /// The counterpart leg in a simple transfer (the leg that isn't the relevant one).
  /// Nil for non-transfer simple transactions.
  var counterpartLeg: LegDraft? {
    guard legDrafts.count == 2 else { return nil }
    let otherIndex = relevantLegIndex == 0 ? 1 : 0
    return legDrafts[otherIndex]
  }

  private var counterpartLegIndex: Int? {
    guard legDrafts.count == 2 else { return nil }
    return relevantLegIndex == 0 ? 1 : 0
  }

  /// The transaction type, read from the relevant leg.
  var type: TransactionType {
    relevantLeg.type
  }

  /// The account on the relevant leg.
  var accountId: UUID? {
    get { relevantLeg.accountId }
    set { legDrafts[relevantLegIndex].accountId = newValue }
  }

  /// The display amount text from the relevant leg.
  var amountText: String {
    relevantLeg.amountText
  }

  /// The counterpart account (for simple transfers).
  var toAccountId: UUID? {
    get { counterpartLeg?.accountId }
    set {
      if let idx = counterpartLegIndex {
        legDrafts[idx].accountId = newValue
      }
    }
  }

  /// Category on the primary leg (index 0).
  var categoryId: UUID? {
    get { legDrafts[0].categoryId }
    set { legDrafts[0].categoryId = newValue }
  }

  /// Category text on the primary leg (index 0).
  var categoryText: String {
    get { legDrafts[0].categoryText }
    set { legDrafts[0].categoryText = newValue }
  }

  /// Earmark on the primary leg (index 0).
  var earmarkId: UUID? {
    get { legDrafts[0].earmarkId }
    set { legDrafts[0].earmarkId = newValue }
  }

  /// Whether the "other account" label should read "From Account" instead of "To Account".
  /// True when viewing from the counterpart's perspective (the relevant leg is not the primary leg).
  var showFromAccount: Bool {
    relevantLegIndex != 0
  }
}

// MARK: - Convenience Initialisers

extension TransactionDraft {
  /// Create a draft pre-populated from an existing transaction (for editing).
  init(from transaction: Transaction, viewingAccountId: UUID? = nil) {
    // Build legDrafts from all legs, applying the negation rule for display
    let drafts = transaction.legs.map { leg in
      LegDraft(
        type: leg.type,
        accountId: leg.accountId,
        amountText: Self.displayText(
          quantity: leg.quantity, type: leg.type, decimals: leg.instrument.decimals),
        categoryId: leg.categoryId,
        categoryText: "",
        earmarkId: leg.earmarkId
      )
    }

    let isCustom = !transaction.isSimple

    // Pin relevantLegIndex for simple transactions
    let relevantIndex: Int
    if isCustom {
      relevantIndex = 0  // Unused in custom mode
    } else {
      relevantIndex = Self.pinRelevantLeg(
        legs: transaction.legs, viewingAccountId: viewingAccountId)
    }

    self.init(
      payee: transaction.payee ?? "",
      date: transaction.date,
      notes: transaction.notes ?? "",
      isRepeating: transaction.recurPeriod != nil && transaction.recurPeriod != .once,
      recurPeriod: transaction.recurPeriod,
      recurEvery: transaction.recurEvery ?? 1,
      isCustom: isCustom,
      legDrafts: drafts,
      relevantLegIndex: relevantIndex,
      viewingAccountId: viewingAccountId
    )
  }

  /// Create a blank draft for a new transaction.
  init(accountId: UUID? = nil, viewingAccountId: UUID? = nil) {
    self.init(
      payee: "",
      date: Date(),
      notes: "",
      isRepeating: false,
      recurPeriod: nil,
      recurEvery: 1,
      isCustom: false,
      legDrafts: [
        LegDraft(
          type: .expense, accountId: accountId, amountText: "0",
          categoryId: nil, categoryText: "", earmarkId: nil)
      ],
      relevantLegIndex: 0,
      viewingAccountId: viewingAccountId
    )
  }

  /// Determine the relevant leg index for a simple transaction.
  static func pinRelevantLeg(legs: [TransactionLeg], viewingAccountId: UUID?) -> Int {
    if let viewingAccountId {
      if let index = legs.firstIndex(where: { $0.accountId == viewingAccountId }) {
        return index
      }
    }
    // No context or no match: always index 0
    return 0
  }

  /// Re-pin the relevant leg from current legDrafts (used when switching to simple mode).
  mutating func repinRelevantLeg() {
    if let viewingAccountId {
      if let index = legDrafts.firstIndex(where: { $0.accountId == viewingAccountId }) {
        relevantLegIndex = index
        return
      }
    }
    relevantLegIndex = 0
  }
}
```

- [ ] **Step 3: Run tests to verify init tests pass**

Run: `just test 2>&1 | tee .agent-tmp/test-draft-init.txt`
Expected: All init tests PASS. Other draft tests may fail since we haven't added editing methods and conversion yet — that's expected.

Note: The project will have compilation errors since `TransactionDetailView` still references removed properties. That's expected and will be fixed in Task 7. For now, focus on the test target compiling and running.

If tests can't compile due to the view, temporarily comment out the view body or add stub properties. The goal is to get the test target running.

- [ ] **Step 4: Commit**

```bash
git add Shared/Models/TransactionDraft.swift MoolahTests/Shared/TransactionDraftTests.swift
git commit -m "refactor: rewrite TransactionDraft with unified legs model and init"
```

---

### Task 4: Add Editing Methods to TransactionDraft

Add the mutation methods the view will call: `setType`, `setAmount`, `setToAccount`, and mode switching.

**Files:**
- Modify: `Shared/Models/TransactionDraft.swift`
- Test: `MoolahTests/Shared/TransactionDraftTests.swift`

- [ ] **Step 1: Write tests for `setType`**

Add to `TransactionDraftTests`:

```swift
// MARK: - setType

@Test func setTypeExpenseToIncome() {
  var draft = makeExpenseDraft(amountText: "50.00")
  draft.setType(.income, accounts: makeAccounts([makeAccount(id: accountA)]))

  #expect(draft.legDrafts.count == 1)
  #expect(draft.legDrafts[0].type == .income)
  // Display text stays the same
  #expect(draft.legDrafts[0].amountText == "50.00")
}

@Test func setTypeExpenseToTransfer() {
  let accounts = makeAccounts([
    makeAccount(id: accountA),
    makeAccount(id: accountB),
  ])
  var draft = makeExpenseDraft(amountText: "50.00", accountId: accountA)
  draft.setType(.transfer, accounts: accounts)

  #expect(draft.legDrafts.count == 2)
  #expect(draft.legDrafts[0].type == .transfer)
  #expect(draft.legDrafts[0].amountText == "50.00")
  // Counterpart added with negated display amount and default account
  #expect(draft.legDrafts[1].type == .transfer)
  #expect(draft.legDrafts[1].amountText == "-50.00")
  #expect(draft.legDrafts[1].accountId == accountB)
}

@Test func setTypeTransferToExpense() {
  let accounts = makeAccounts([
    makeAccount(id: accountA),
    makeAccount(id: accountB),
  ])
  var draft = makeExpenseDraft(amountText: "50.00", accountId: accountA)
  draft.setType(.transfer, accounts: accounts)
  // Now switch back to expense
  draft.setType(.expense, accounts: accounts)

  #expect(draft.legDrafts.count == 1)
  #expect(draft.legDrafts[0].type == .expense)
  #expect(draft.legDrafts[0].amountText == "50.00")
}

@Test func setTypeIncomeToTransfer() {
  let accounts = makeAccounts([
    makeAccount(id: accountA),
    makeAccount(id: accountB),
  ])
  var draft = TransactionDraft(
    payee: "Test", date: Date(), notes: "",
    isRepeating: false, recurPeriod: nil, recurEvery: 1,
    isCustom: false,
    legDrafts: [
      TransactionDraft.LegDraft(
        type: .income, accountId: accountA, amountText: "50.00",
        categoryId: nil, categoryText: "", earmarkId: nil)
    ],
    relevantLegIndex: 0, viewingAccountId: nil
  )
  draft.setType(.transfer, accounts: accounts)

  #expect(draft.legDrafts.count == 2)
  #expect(draft.legDrafts[0].type == .transfer)
  #expect(draft.legDrafts[0].amountText == "50.00")
  #expect(draft.legDrafts[1].amountText == "-50.00")
}

@Test func setTypeTransferDefaultAccountExcludesCurrentAccount() {
  let accountC = UUID()
  let accounts = makeAccounts([
    makeAccount(id: accountA),
    makeAccount(id: accountB),
    makeAccount(id: accountC),
  ])
  var draft = makeExpenseDraft(amountText: "50.00", accountId: accountA)
  draft.setType(.transfer, accounts: accounts)

  // Counterpart should not be accountA
  #expect(draft.legDrafts[1].accountId != accountA)
}

@Test func setTypeClearsCounterpartCategoryAndEarmark() {
  let categoryId = UUID()
  let earmarkId = UUID()
  let accounts = makeAccounts([
    makeAccount(id: accountA),
    makeAccount(id: accountB),
  ])
  var draft = TransactionDraft(
    payee: "Test", date: Date(), notes: "",
    isRepeating: false, recurPeriod: nil, recurEvery: 1,
    isCustom: false,
    legDrafts: [
      TransactionDraft.LegDraft(
        type: .expense, accountId: accountA, amountText: "50.00",
        categoryId: categoryId, categoryText: "Food", earmarkId: earmarkId)
    ],
    relevantLegIndex: 0, viewingAccountId: nil
  )
  draft.setType(.transfer, accounts: accounts)

  // Primary leg (0) keeps category/earmark
  #expect(draft.legDrafts[0].categoryId == categoryId)
  #expect(draft.legDrafts[0].earmarkId == earmarkId)
  // Counterpart has nil
  #expect(draft.legDrafts[1].categoryId == nil)
  #expect(draft.legDrafts[1].earmarkId == nil)
}
```

- [ ] **Step 2: Write tests for `setAmount`**

```swift
// MARK: - setAmount

@Test func setAmountSimpleExpense() {
  var draft = makeExpenseDraft(amountText: "10.00")
  draft.setAmount("75.00")
  #expect(draft.legDrafts[0].amountText == "75.00")
}

@Test func setAmountSimpleTransferMirrorsToCounterpart() {
  let accounts = makeAccounts([
    makeAccount(id: accountA),
    makeAccount(id: accountB),
  ])
  var draft = makeExpenseDraft(amountText: "50.00", accountId: accountA)
  draft.setType(.transfer, accounts: accounts)

  draft.setAmount("75.00")
  #expect(draft.legDrafts[draft.relevantLegIndex].amountText == "75.00")
  // Counterpart gets parse-negate-format
  let counterIdx = draft.relevantLegIndex == 0 ? 1 : 0
  #expect(draft.legDrafts[counterIdx].amountText == "-75.00")
}

@Test func setAmountNegativeDisplayMirrorsPositiveToCounterpart() {
  let accounts = makeAccounts([
    makeAccount(id: accountA),
    makeAccount(id: accountB),
  ])
  var draft = makeExpenseDraft(amountText: "50.00", accountId: accountA)
  draft.setType(.transfer, accounts: accounts)

  // Negative display value (reversed transfer)
  draft.setAmount("-10.00")
  #expect(draft.legDrafts[draft.relevantLegIndex].amountText == "-10.00")
  let counterIdx = draft.relevantLegIndex == 0 ? 1 : 0
  #expect(draft.legDrafts[counterIdx].amountText == "10.00")
}

@Test func setAmountUnparseableCascadesToInvalidCounterpart() {
  let accounts = makeAccounts([
    makeAccount(id: accountA),
    makeAccount(id: accountB),
  ])
  var draft = makeExpenseDraft(amountText: "50.00", accountId: accountA)
  draft.setType(.transfer, accounts: accounts)

  draft.setAmount("abc")
  #expect(draft.legDrafts[draft.relevantLegIndex].amountText == "abc")
  let counterIdx = draft.relevantLegIndex == 0 ? 1 : 0
  #expect(draft.legDrafts[counterIdx].amountText == "")
}

@Test func setAmountZeroIsValid() {
  var draft = makeExpenseDraft(amountText: "10.00")
  draft.setAmount("0")
  #expect(draft.legDrafts[0].amountText == "0")
}
```

- [ ] **Step 3: Write tests for `setAmount` with relevant leg not at index 0**

```swift
@Test func setAmountFromDestinationPerspectiveMirrorsCorrectly() {
  // Transfer where relevant leg is index 1 (viewing from destination)
  let tx = Transaction(
    date: Date(),
    legs: [
      TransactionLeg(accountId: accountA, instrument: instrument, quantity: -100, type: .transfer),
      TransactionLeg(accountId: accountB, instrument: instrument, quantity: 100, type: .transfer),
    ]
  )
  var draft = TransactionDraft(from: tx, viewingAccountId: accountB)
  #expect(draft.relevantLegIndex == 1)

  // User changes amount to 200 (from their perspective)
  draft.setAmount("200.00")
  #expect(draft.legDrafts[1].amountText == "200.00")
  // Primary leg (index 0) gets negated
  #expect(draft.legDrafts[0].amountText == "-200.00")
}
```

- [ ] **Step 4: Write tests for relevant leg stability**

```swift
// MARK: - Relevant Leg Stability

@Test func relevantLegStableWhenAmountSignChanges() {
  let tx = Transaction(
    date: Date(),
    legs: [
      TransactionLeg(accountId: accountA, instrument: instrument, quantity: -100, type: .transfer),
      TransactionLeg(accountId: accountB, instrument: instrument, quantity: 100, type: .transfer),
    ]
  )
  var draft = TransactionDraft(from: tx, viewingAccountId: accountA)
  let originalIndex = draft.relevantLegIndex

  // Change amount to negative (would flip which leg is "outflow")
  draft.setAmount("-50.00")

  // Relevant leg index must NOT change
  #expect(draft.relevantLegIndex == originalIndex)
  #expect(draft.legDrafts[originalIndex].accountId == accountA)
}
```

- [ ] **Step 5: Implement editing methods**

Add to `Shared/Models/TransactionDraft.swift`:

```swift
// MARK: - Editing Methods (Simple Mode)

extension TransactionDraft {
  /// Change the transaction type, adding/removing counterpart legs as needed.
  mutating func setType(_ newType: TransactionType, accounts: Accounts) {
    let wasTransfer = type == .transfer
    let isTransfer = newType == .transfer

    if !wasTransfer && isTransfer {
      // Adding a counterpart leg for transfer
      let currentAccountId = relevantLeg.accountId
      let defaultAccount = accounts.ordered.first { $0.id != currentAccountId }

      // Parse-negate-format the counterpart amount
      let counterpartAmount = negatedAmountText(relevantLeg.amountText)

      let counterpartLeg = LegDraft(
        type: .transfer,
        accountId: defaultAccount?.id,
        amountText: counterpartAmount,
        categoryId: nil,
        categoryText: "",
        earmarkId: nil
      )

      legDrafts[relevantLegIndex].type = .transfer
      // Insert counterpart at the other position
      if relevantLegIndex == 0 {
        legDrafts.append(counterpartLeg)
      } else {
        legDrafts.insert(counterpartLeg, at: 0)
      }
    } else if wasTransfer && !isTransfer {
      // Removing counterpart leg
      if let idx = counterpartLegIndex {
        legDrafts.remove(at: idx)
        // Adjust relevantLegIndex if needed
        if relevantLegIndex > idx {
          relevantLegIndex -= 1
        }
      }
      legDrafts[relevantLegIndex].type = newType
    } else {
      // Just changing type on existing legs (expense ↔ income)
      for i in legDrafts.indices {
        legDrafts[i].type = newType
      }
    }
  }

  /// Change the display amount on the relevant leg, mirroring to counterpart for transfers.
  mutating func setAmount(_ text: String) {
    legDrafts[relevantLegIndex].amountText = text

    // Mirror to counterpart for simple transfers
    if let idx = counterpartLegIndex {
      legDrafts[idx].amountText = negatedAmountText(text)
    }
  }

  /// Parse display text, negate, and format. Returns "" if unparseable.
  private func negatedAmountText(_ text: String) -> String {
    // Use a dummy decimals value — we just need to parse and negate
    guard let value = InstrumentAmount.parseQuantity(from: text, decimals: 10) else {
      return ""
    }
    let negated = -value
    // Format with enough precision to preserve the original
    return negated.formatted(.number.precision(.fractionLength(0...10)))
  }
}
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `just test 2>&1 | tee .agent-tmp/test-draft-edit.txt`
Expected: All new editing method tests PASS

- [ ] **Step 7: Write tests for mode switching**

```swift
// MARK: - Mode Switching

@Test func switchToCustomPreservesLegs() {
  var draft = makeExpenseDraft(amountText: "50.00", accountId: accountA)
  draft.isCustom = true
  #expect(draft.legDrafts.count == 1)
  #expect(draft.legDrafts[0].amountText == "50.00")
}

@Test func switchToSimpleRepinsRelevantLeg() {
  let tx = Transaction(
    date: Date(),
    legs: [
      TransactionLeg(accountId: accountA, instrument: instrument, quantity: -100, type: .transfer),
      TransactionLeg(accountId: accountB, instrument: instrument, quantity: 100, type: .transfer),
    ]
  )
  var draft = TransactionDraft(from: tx, viewingAccountId: accountB)
  draft.isCustom = true
  // Switch back to simple
  draft.switchToSimple()
  #expect(draft.isCustom == false)
  #expect(draft.relevantLegIndex == 1)  // re-pinned to accountB
}

@Test func switchToSimpleNoContextPinsToZero() {
  let tx = Transaction(
    date: Date(),
    legs: [
      TransactionLeg(accountId: accountA, instrument: instrument, quantity: -100, type: .transfer),
      TransactionLeg(accountId: accountB, instrument: instrument, quantity: 100, type: .transfer),
    ]
  )
  var draft = TransactionDraft(from: tx)
  draft.isCustom = true
  draft.switchToSimple()
  #expect(draft.relevantLegIndex == 0)
}

@Test func canSwitchToSimpleWhenLegsAreSimple() {
  var draft = makeExpenseDraft()
  draft.isCustom = true
  #expect(draft.canSwitchToSimple == true)
}

@Test func cannotSwitchToSimpleWithThreeLegs() {
  var draft = makeExpenseDraft()
  draft.isCustom = true
  draft.legDrafts.append(
    TransactionDraft.LegDraft(
      type: .expense, accountId: accountB, amountText: "5.00",
      categoryId: nil, categoryText: "", earmarkId: nil))
  draft.legDrafts.append(
    TransactionDraft.LegDraft(
      type: .income, accountId: UUID(), amountText: "15.00",
      categoryId: nil, categoryText: "", earmarkId: nil))
  #expect(draft.canSwitchToSimple == false)
}
```

- [ ] **Step 8: Implement mode switching methods**

Add to `TransactionDraft`:

```swift
// MARK: - Mode Switching

extension TransactionDraft {
  /// Whether the current legs satisfy `isSimple` rules, allowing a switch to simple mode.
  var canSwitchToSimple: Bool {
    if legDrafts.count <= 1 { return true }
    guard legDrafts.count == 2 else { return false }
    let a = legDrafts[0]
    let b = legDrafts[1]
    guard a.type == b.type && a.type == .transfer else { return false }
    guard b.categoryId == nil && b.earmarkId == nil else { return false }
    guard a.accountId != b.accountId else { return false }
    // Check amounts negate: parse both and compare
    guard let aVal = InstrumentAmount.parseQuantity(from: a.amountText, decimals: 10),
          let bVal = InstrumentAmount.parseQuantity(from: b.amountText, decimals: 10),
          aVal == -bVal
    else { return false }
    return true
  }

  /// Switch from custom to simple mode. Only call when `canSwitchToSimple` is true.
  mutating func switchToSimple() {
    isCustom = false
    repinRelevantLeg()
  }
}
```

- [ ] **Step 9: Run tests to verify they pass**

Run: `just test 2>&1 | tee .agent-tmp/test-draft-switch.txt`
Expected: ALL mode switching tests PASS

- [ ] **Step 10: Commit**

```bash
git add Shared/Models/TransactionDraft.swift MoolahTests/Shared/TransactionDraftTests.swift
git commit -m "feat: add editing methods and mode switching to unified TransactionDraft"
```

---

### Task 5: Add Validation and Conversion to TransactionDraft

Replace the three `toTransaction` overloads with one method that always reads from `legDrafts`. Replace boolean `isValid` with validation that returns errors.

**Files:**
- Modify: `Shared/Models/TransactionDraft.swift`
- Test: `MoolahTests/Shared/TransactionDraftTests.swift`

- [ ] **Step 1: Write tests for validation**

Add to `TransactionDraftTests`:

```swift
// MARK: - Validation

@Test func validSimpleExpense() {
  let draft = makeExpenseDraft(amountText: "10.00", accountId: accountA)
  #expect(draft.isValid == true)
}

@Test func invalidEmptyAmount() {
  let draft = makeExpenseDraft(amountText: "")
  #expect(draft.isValid == false)
}

@Test func validZeroAmount() {
  let draft = makeExpenseDraft(amountText: "0")
  #expect(draft.isValid == true)
}

@Test func validNegativeDisplayAmount() {
  // Refund: user types -10 for an expense
  let draft = makeExpenseDraft(amountText: "-10.00")
  #expect(draft.isValid == true)
}

@Test func invalidMissingAccount() {
  let draft = TransactionDraft(
    payee: "Test", date: Date(), notes: "",
    isRepeating: false, recurPeriod: nil, recurEvery: 1,
    isCustom: false,
    legDrafts: [
      TransactionDraft.LegDraft(
        type: .expense, accountId: nil, amountText: "10.00",
        categoryId: nil, categoryText: "", earmarkId: nil)
    ],
    relevantLegIndex: 0, viewingAccountId: nil
  )
  #expect(draft.isValid == false)
}

@Test func invalidRecurrenceWithoutPeriod() {
  var draft = makeExpenseDraft(amountText: "10.00")
  draft.isRepeating = true
  draft.recurPeriod = nil
  #expect(draft.isValid == false)
}

@Test func validRecurrence() {
  var draft = makeExpenseDraft(amountText: "10.00")
  draft.isRepeating = true
  draft.recurPeriod = .month
  draft.recurEvery = 1
  #expect(draft.isValid == true)
}

@Test func invalidCustomEmptyLegs() {
  var draft = makeExpenseDraft()
  draft.isCustom = true
  draft.legDrafts = []
  #expect(draft.isValid == false)
}

@Test func invalidCustomLegMissingAccount() {
  var draft = makeExpenseDraft()
  draft.isCustom = true
  draft.legDrafts = [
    TransactionDraft.LegDraft(
      type: .expense, accountId: nil, amountText: "10.00",
      categoryId: nil, categoryText: "", earmarkId: nil)
  ]
  #expect(draft.isValid == false)
}

@Test func invalidCustomLegEmptyAmount() {
  var draft = makeExpenseDraft()
  draft.isCustom = true
  draft.legDrafts = [
    TransactionDraft.LegDraft(
      type: .expense, accountId: accountA, amountText: "",
      categoryId: nil, categoryText: "", earmarkId: nil)
  ]
  #expect(draft.isValid == false)
}

@Test func validCustomLegs() {
  var draft = makeExpenseDraft()
  draft.isCustom = true
  draft.legDrafts = [
    TransactionDraft.LegDraft(
      type: .expense, accountId: accountA, amountText: "10.00",
      categoryId: nil, categoryText: "", earmarkId: nil),
    TransactionDraft.LegDraft(
      type: .income, accountId: accountB, amountText: "5.00",
      categoryId: nil, categoryText: "", earmarkId: nil),
  ]
  #expect(draft.isValid == true)
}
```

- [ ] **Step 2: Write tests for `toTransaction`**

```swift
// MARK: - Conversion: toTransaction

@Test func toTransactionSimpleExpense() {
  let draft = makeExpenseDraft(amountText: "25.00", accountId: accountA)
  let accounts = makeAccounts([makeAccount(id: accountA)])
  let tx = draft.toTransaction(id: UUID(), accounts: accounts)

  #expect(tx != nil)
  #expect(tx!.legs.count == 1)
  #expect(tx!.legs[0].quantity == Decimal(string: "-25.00"))  // expense: negated back
  #expect(tx!.legs[0].type == .expense)
  #expect(tx!.legs[0].accountId == accountA)
}

@Test func toTransactionSimpleIncome() {
  let draft = TransactionDraft(
    payee: "Salary", date: Date(), notes: "",
    isRepeating: false, recurPeriod: nil, recurEvery: 1,
    isCustom: false,
    legDrafts: [
      TransactionDraft.LegDraft(
        type: .income, accountId: accountA, amountText: "3000.00",
        categoryId: nil, categoryText: "", earmarkId: nil)
    ],
    relevantLegIndex: 0, viewingAccountId: nil
  )
  let accounts = makeAccounts([makeAccount(id: accountA)])
  let tx = draft.toTransaction(id: UUID(), accounts: accounts)

  #expect(tx != nil)
  #expect(tx!.legs[0].quantity == Decimal(string: "3000.00"))  // income: as-is
}

@Test func toTransactionRefundExpense() {
  // Display value "-10" for expense → quantity = -(-10) = +10
  let draft = makeExpenseDraft(amountText: "-10.00", accountId: accountA)
  let accounts = makeAccounts([makeAccount(id: accountA)])
  let tx = draft.toTransaction(id: UUID(), accounts: accounts)

  #expect(tx != nil)
  #expect(tx!.legs[0].quantity == Decimal(string: "10.00"))
}

@Test func toTransactionSimpleTransfer() {
  let accounts = makeAccounts([
    makeAccount(id: accountA),
    makeAccount(id: accountB),
  ])
  var draft = makeExpenseDraft(amountText: "100.00", accountId: accountA)
  draft.setType(.transfer, accounts: accounts)

  let tx = draft.toTransaction(id: UUID(), accounts: accounts)
  #expect(tx != nil)
  #expect(tx!.legs.count == 2)
  #expect(tx!.legs[0].quantity == Decimal(string: "-100.00"))
  #expect(tx!.legs[1].quantity == Decimal(string: "100.00"))
}

@Test func toTransactionRoundTripsExpense() {
  let id = UUID()
  let categoryId = UUID()
  let earmarkId = UUID()
  let original = Transaction(
    id: id,
    date: Date(timeIntervalSince1970: 1_700_000_000),
    payee: "Coffee",
    notes: "Latte",
    recurPeriod: .week,
    recurEvery: 2,
    legs: [
      TransactionLeg(
        accountId: accountA, instrument: instrument,
        quantity: Decimal(string: "-42.50")!, type: .expense,
        categoryId: categoryId, earmarkId: earmarkId)
    ]
  )

  let draft = TransactionDraft(from: original)
  let accounts = makeAccounts([makeAccount(id: accountA)])
  let roundTripped = draft.toTransaction(id: id, accounts: accounts)

  #expect(roundTripped != nil)
  #expect(roundTripped!.id == original.id)
  #expect(roundTripped!.date == original.date)
  #expect(roundTripped!.payee == original.payee)
  #expect(roundTripped!.notes == original.notes)
  #expect(roundTripped!.recurPeriod == original.recurPeriod)
  #expect(roundTripped!.recurEvery == original.recurEvery)
  #expect(roundTripped!.legs.count == original.legs.count)
  #expect(roundTripped!.legs[0].quantity == original.legs[0].quantity)
  #expect(roundTripped!.legs[0].type == original.legs[0].type)
  #expect(roundTripped!.legs[0].categoryId == original.legs[0].categoryId)
  #expect(roundTripped!.legs[0].earmarkId == original.legs[0].earmarkId)
}

@Test func toTransactionRoundTripsTransfer() {
  let id = UUID()
  let categoryId = UUID()
  let original = Transaction(
    id: id,
    date: Date(),
    payee: "Transfer",
    legs: [
      TransactionLeg(
        accountId: accountA, instrument: instrument, quantity: -100, type: .transfer,
        categoryId: categoryId),
      TransactionLeg(accountId: accountB, instrument: instrument, quantity: 100, type: .transfer),
    ]
  )

  let draft = TransactionDraft(from: original)
  let accounts = makeAccounts([
    makeAccount(id: accountA),
    makeAccount(id: accountB),
  ])
  let roundTripped = draft.toTransaction(id: id, accounts: accounts)

  #expect(roundTripped != nil)
  #expect(roundTripped!.legs.count == 2)
  #expect(roundTripped!.legs[0].quantity == original.legs[0].quantity)
  #expect(roundTripped!.legs[1].quantity == original.legs[1].quantity)
  #expect(roundTripped!.legs[0].categoryId == categoryId)
  #expect(roundTripped!.legs[1].categoryId == nil)
}

@Test func toTransactionRoundTripsTransferFromDestination() {
  let id = UUID()
  let original = Transaction(
    id: id,
    date: Date(),
    legs: [
      TransactionLeg(accountId: accountA, instrument: instrument, quantity: -100, type: .transfer),
      TransactionLeg(accountId: accountB, instrument: instrument, quantity: 100, type: .transfer),
    ]
  )

  // Edit from destination perspective
  let draft = TransactionDraft(from: original, viewingAccountId: accountB)
  let accounts = makeAccounts([
    makeAccount(id: accountA),
    makeAccount(id: accountB),
  ])
  let roundTripped = draft.toTransaction(id: id, accounts: accounts)

  #expect(roundTripped != nil)
  // Quantities must be preserved regardless of which leg is "relevant"
  #expect(roundTripped!.legs[0].quantity == Decimal(string: "-100"))
  #expect(roundTripped!.legs[1].quantity == Decimal(string: "100"))
}

@Test func toTransactionCustomModeMultiLeg() {
  let catId = UUID()
  let earmarkId = UUID()
  let accounts = makeAccounts([
    makeAccount(id: accountA),
    makeAccount(id: accountB),
  ])
  let draft = TransactionDraft(
    payee: "Split", date: Date(), notes: "",
    isRepeating: false, recurPeriod: nil, recurEvery: 1,
    isCustom: true,
    legDrafts: [
      TransactionDraft.LegDraft(
        type: .expense, accountId: accountA, amountText: "100.00",
        categoryId: catId, categoryText: "", earmarkId: nil),
      TransactionDraft.LegDraft(
        type: .income, accountId: accountB, amountText: "50.00",
        categoryId: nil, categoryText: "", earmarkId: earmarkId),
    ],
    relevantLegIndex: 0, viewingAccountId: nil
  )

  let tx = draft.toTransaction(id: UUID(), accounts: accounts)
  #expect(tx != nil)
  #expect(tx!.legs.count == 2)
  #expect(tx!.legs[0].quantity == Decimal(string: "-100.00"))  // expense negated
  #expect(tx!.legs[0].categoryId == catId)
  #expect(tx!.legs[1].quantity == Decimal(string: "50.00"))  // income as-is
  #expect(tx!.legs[1].earmarkId == earmarkId)
}

@Test func toTransactionReturnsNilWhenInvalid() {
  let draft = makeExpenseDraft(amountText: "")
  let accounts = makeAccounts([makeAccount(id: accountA)])
  #expect(draft.toTransaction(id: UUID(), accounts: accounts) == nil)
}

@Test func toTransactionClearsRecurrenceWhenNotRepeating() {
  var draft = makeExpenseDraft(amountText: "10.00", accountId: accountA)
  draft.recurPeriod = .month
  draft.recurEvery = 2
  draft.isRepeating = false

  let accounts = makeAccounts([makeAccount(id: accountA)])
  let tx = draft.toTransaction(id: UUID(), accounts: accounts)
  #expect(tx != nil)
  #expect(tx!.recurPeriod == nil)
  #expect(tx!.recurEvery == nil)
}
```

- [ ] **Step 3: Implement validation and conversion**

Add to `Shared/Models/TransactionDraft.swift`:

```swift
// MARK: - Validation

extension TransactionDraft {
  /// Whether the draft represents a valid, saveable transaction.
  var isValid: Bool {
    guard !legDrafts.isEmpty else { return false }
    for leg in legDrafts {
      guard leg.accountId != nil else { return false }
      guard !leg.amountText.isEmpty,
            InstrumentAmount.parseQuantity(from: leg.amountText, decimals: 10) != nil
      else { return false }
    }
    if isRepeating {
      guard recurPeriod != nil, recurEvery >= 1 else { return false }
    }
    return true
  }
}

// MARK: - Conversion

extension TransactionDraft {
  /// Build a `Transaction` from the draft, looking up instruments from `accounts`.
  /// Returns nil when the draft is not valid.
  func toTransaction(id: UUID, accounts: Accounts) -> Transaction? {
    guard isValid else { return nil }

    var legs: [TransactionLeg] = []
    for legDraft in legDrafts {
      guard let acctId = legDraft.accountId,
            let account = accounts.by(id: acctId)
      else { return nil }

      let instrument = account.balance.instrument
      guard let quantity = Self.parseDisplayText(
        legDraft.amountText, type: legDraft.type, decimals: instrument.decimals)
      else { return nil }

      legs.append(TransactionLeg(
        accountId: acctId,
        instrument: instrument,
        quantity: quantity,
        type: legDraft.type,
        categoryId: legDraft.categoryId,
        earmarkId: legDraft.earmarkId
      ))
    }

    return Transaction(
      id: id,
      date: date,
      payee: payee.isEmpty ? nil : payee,
      notes: notes.isEmpty ? nil : notes,
      recurPeriod: isRepeating ? recurPeriod : nil,
      recurEvery: isRepeating ? recurEvery : nil,
      legs: legs
    )
  }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `just test 2>&1 | tee .agent-tmp/test-draft-convert.txt`
Expected: ALL validation and conversion tests PASS

- [ ] **Step 5: Commit**

```bash
git add Shared/Models/TransactionDraft.swift MoolahTests/Shared/TransactionDraftTests.swift
git commit -m "feat: add validation and single toTransaction entry point to TransactionDraft"
```

---

### Task 6: Add Autofill and Computed Properties

Implement the simplified autofill (copy everything, override date) and the `showFromAccount` computed property, plus the static to-account filtering helper.

**Files:**
- Modify: `Shared/Models/TransactionDraft.swift`
- Create: `Shared/Models/TransactionDraftHelpers.swift`
- Test: `MoolahTests/Shared/TransactionDraftTests.swift`

- [ ] **Step 1: Write tests for autofill**

Add to `TransactionDraftTests`:

```swift
// MARK: - Autofill

@Test func autofillCopiesEverythingExceptDate() {
  let categoryId = UUID()
  let earmarkId = UUID()
  let matchDate = Date(timeIntervalSince1970: 999_999)
  let matchTx = Transaction(
    date: matchDate,
    payee: "Coffee",
    notes: "Morning",
    legs: [
      TransactionLeg(
        accountId: accountA, instrument: instrument,
        quantity: Decimal(string: "-5.50")!, type: .expense,
        categoryId: categoryId, earmarkId: earmarkId)
    ]
  )

  let originalDate = Date()
  var draft = TransactionDraft(accountId: accountA, viewingAccountId: accountA)
  draft.date = originalDate

  draft.applyAutofill(from: matchTx, categories: Categories(from: []))

  #expect(draft.payee == "Coffee")
  #expect(draft.notes == "Morning")
  #expect(draft.legDrafts[0].type == .expense)
  #expect(draft.legDrafts[0].amountText == "5.50")
  #expect(draft.legDrafts[0].accountId == accountA)
  #expect(draft.legDrafts[0].categoryId == categoryId)
  #expect(draft.legDrafts[0].earmarkId == earmarkId)
  // Date preserved from original draft
  #expect(draft.date == originalDate)
  #expect(draft.date != matchDate)
}

@Test func autofillFromComplexTransactionSetsCustomMode() {
  let matchTx = Transaction(
    date: Date(),
    payee: "Split",
    legs: [
      TransactionLeg(accountId: accountA, instrument: instrument, quantity: -100, type: .expense),
      TransactionLeg(accountId: accountB, instrument: instrument, quantity: -50, type: .expense),
      TransactionLeg(accountId: UUID(), instrument: instrument, quantity: 150, type: .income),
    ]
  )

  var draft = TransactionDraft(accountId: accountA, viewingAccountId: accountA)
  draft.applyAutofill(from: matchTx, categories: Categories(from: []))

  #expect(draft.isCustom == true)
  #expect(draft.legDrafts.count == 3)
  #expect(draft.payee == "Split")
}

@Test func autofillPopulatesCategoryText() {
  let categoryId = UUID()
  let matchTx = Transaction(
    date: Date(),
    payee: "Shop",
    legs: [
      TransactionLeg(
        accountId: accountA, instrument: instrument,
        quantity: -10, type: .expense, categoryId: categoryId)
    ]
  )
  let categories = Categories(from: [Category(id: categoryId, name: "Groceries")])

  var draft = TransactionDraft(accountId: accountA, viewingAccountId: accountA)
  draft.applyAutofill(from: matchTx, categories: categories)

  #expect(draft.legDrafts[0].categoryId == categoryId)
  #expect(draft.legDrafts[0].categoryText == "Groceries")
}
```

- [ ] **Step 2: Write tests for `showFromAccount`**

```swift
// MARK: - showFromAccount

@Test func showFromAccountFalseWhenViewingPrimaryLeg() {
  let tx = Transaction(
    date: Date(),
    legs: [
      TransactionLeg(accountId: accountA, instrument: instrument, quantity: -100, type: .transfer),
      TransactionLeg(accountId: accountB, instrument: instrument, quantity: 100, type: .transfer),
    ]
  )
  let draft = TransactionDraft(from: tx, viewingAccountId: accountA)
  // accountA is at index 0 (primary), so "To Account" label
  #expect(draft.showFromAccount == false)
}

@Test func showFromAccountTrueWhenViewingCounterpartLeg() {
  let tx = Transaction(
    date: Date(),
    legs: [
      TransactionLeg(accountId: accountA, instrument: instrument, quantity: -100, type: .transfer),
      TransactionLeg(accountId: accountB, instrument: instrument, quantity: 100, type: .transfer),
    ]
  )
  let draft = TransactionDraft(from: tx, viewingAccountId: accountB)
  // accountB is at index 1, so relevantLegIndex = 1, not primary → "From Account"
  #expect(draft.showFromAccount == true)
}

@Test func showFromAccountFalseWhenNoContext() {
  let tx = Transaction(
    date: Date(),
    legs: [
      TransactionLeg(accountId: accountA, instrument: instrument, quantity: -100, type: .transfer),
      TransactionLeg(accountId: accountB, instrument: instrument, quantity: 100, type: .transfer),
    ]
  )
  let draft = TransactionDraft(from: tx)
  // No context: relevantLegIndex = 0 → "To Account"
  #expect(draft.showFromAccount == false)
}
```

- [ ] **Step 3: Write tests for `eligibleToAccounts`**

```swift
// MARK: - eligibleToAccounts

@Test func eligibleToAccountsFiltersByCurrency() {
  let aud = Instrument.AUD
  let usd = Instrument.USD
  let audAccount1 = makeAccount(id: accountA, instrument: aud)
  let audAccount2 = makeAccount(id: accountB, instrument: aud)
  let usdAccount = makeAccount(id: UUID(), instrument: usd)
  let accounts = makeAccounts([audAccount1, audAccount2, usdAccount])

  let eligible = TransactionDraftHelpers.eligibleToAccounts(from: accounts, currency: aud)
  let eligibleIds = eligible.map(\.id)
  #expect(eligibleIds.contains(accountA))
  #expect(eligibleIds.contains(accountB))
  #expect(!eligibleIds.contains(usdAccount.id))
}
```

- [ ] **Step 4: Implement autofill**

Add to `Shared/Models/TransactionDraft.swift`:

```swift
// MARK: - Autofill

extension TransactionDraft {
  /// Replace this draft with data from a matching transaction, preserving the current date.
  /// Category text is populated from the categories collection.
  mutating func applyAutofill(from match: Transaction, categories: Categories) {
    let preservedDate = self.date
    let preservedViewingAccountId = self.viewingAccountId

    // Build a fresh draft from the match
    var newDraft = TransactionDraft(from: match, viewingAccountId: preservedViewingAccountId)
    newDraft.date = preservedDate

    // Populate category text for all legs
    for i in newDraft.legDrafts.indices {
      if let catId = newDraft.legDrafts[i].categoryId,
         let cat = categories.by(id: catId) {
        newDraft.legDrafts[i].categoryText = categories.path(for: cat)
      }
    }

    self = newDraft
  }
}
```

- [ ] **Step 5: Create `TransactionDraftHelpers.swift`**

Create `Shared/Models/TransactionDraftHelpers.swift`:

```swift
import Foundation

enum TransactionDraftHelpers {
  /// Filter accounts to those matching the given currency, for the "To Account" picker
  /// in simple transfer mode.
  static func eligibleToAccounts(from accounts: Accounts, currency: Instrument) -> [Account] {
    accounts.ordered.filter { $0.balance.instrument == currency }
  }
}
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `just test 2>&1 | tee .agent-tmp/test-draft-auto.txt`
Expected: ALL autofill and helper tests PASS

- [ ] **Step 7: Commit**

```bash
git add Shared/Models/TransactionDraft.swift Shared/Models/TransactionDraftHelpers.swift MoolahTests/Shared/TransactionDraftTests.swift
git commit -m "feat: add autofill, showFromAccount, and eligibleToAccounts helper"
```

---

### Task 7: Add Custom Mode Operations and Edge Case Tests

Add `addLeg`, `removeLeg` methods, and comprehensive edge case tests.

**Files:**
- Modify: `Shared/Models/TransactionDraft.swift`
- Test: `MoolahTests/Shared/TransactionDraftTests.swift`

- [ ] **Step 1: Write tests for custom mode operations**

```swift
// MARK: - Custom Mode Operations

@Test func addLegAppendsBlankLeg() {
  var draft = makeExpenseDraft()
  draft.isCustom = true
  let initialCount = draft.legDrafts.count
  draft.addLeg()
  #expect(draft.legDrafts.count == initialCount + 1)
  let newLeg = draft.legDrafts.last!
  #expect(newLeg.type == .expense)
  #expect(newLeg.accountId == nil)
  #expect(newLeg.amountText == "0")
  #expect(newLeg.categoryId == nil)
  #expect(newLeg.earmarkId == nil)
}

@Test func removeLegRemovesCorrectIndex() {
  var draft = makeExpenseDraft()
  draft.isCustom = true
  draft.legDrafts.append(
    TransactionDraft.LegDraft(
      type: .income, accountId: accountB, amountText: "20.00",
      categoryId: nil, categoryText: "", earmarkId: nil))
  #expect(draft.legDrafts.count == 2)

  draft.removeLeg(at: 0)
  #expect(draft.legDrafts.count == 1)
  #expect(draft.legDrafts[0].accountId == accountB)
}
```

- [ ] **Step 2: Write edge case tests**

```swift
// MARK: - Edge Cases

@Test func displayTextForZeroQuantity() {
  let text = TransactionDraft.displayText(quantity: .zero, type: .expense, decimals: 2)
  #expect(text == "0.00")
}

@Test func displayTextForNegativeExpense() {
  // Normal expense: quantity -50, display = -(-50) = 50
  let text = TransactionDraft.displayText(quantity: Decimal(string: "-50")!, type: .expense, decimals: 2)
  #expect(text == "50.00")
}

@Test func displayTextForRefundExpense() {
  // Refund: quantity +10, display = -(+10) = -10
  let text = TransactionDraft.displayText(quantity: Decimal(string: "10")!, type: .expense, decimals: 2)
  #expect(text == "-10.00")
}

@Test func displayTextForIncome() {
  let text = TransactionDraft.displayText(quantity: Decimal(string: "100")!, type: .income, decimals: 2)
  #expect(text == "100.00")
}

@Test func parseDisplayTextRoundTrips() {
  let original: Decimal = Decimal(string: "-42.50")!
  let display = TransactionDraft.displayText(quantity: original, type: .expense, decimals: 2)
  let parsed = TransactionDraft.parseDisplayText(display, type: .expense, decimals: 2)
  #expect(parsed == original)
}

@Test func parseDisplayTextRefundRoundTrips() {
  let original: Decimal = Decimal(string: "10.00")!  // refund expense
  let display = TransactionDraft.displayText(quantity: original, type: .expense, decimals: 2)
  #expect(display == "-10.00")
  let parsed = TransactionDraft.parseDisplayText(display, type: .expense, decimals: 2)
  #expect(parsed == original)
}

@Test func parseDisplayTextIncomeRoundTrips() {
  let original: Decimal = Decimal(string: "3000.00")!
  let display = TransactionDraft.displayText(quantity: original, type: .income, decimals: 2)
  let parsed = TransactionDraft.parseDisplayText(display, type: .income, decimals: 2)
  #expect(parsed == original)
}

@Test func customModeLegTypeChangePreservesDisplayAmount() {
  var draft = makeExpenseDraft()
  draft.isCustom = true
  draft.legDrafts[0].amountText = "50.00"
  draft.legDrafts[0].type = .income
  // Display text unchanged
  #expect(draft.legDrafts[0].amountText == "50.00")
  // But conversion would produce different quantity
  let accounts = makeAccounts([makeAccount(id: accountA)])
  let tx = draft.toTransaction(id: UUID(), accounts: accounts)
  #expect(tx!.legs[0].quantity == Decimal(string: "50.00"))  // income: as-is
}
```

- [ ] **Step 3: Implement custom mode operations**

Add to `Shared/Models/TransactionDraft.swift`:

```swift
// MARK: - Custom Mode Operations

extension TransactionDraft {
  /// Append a blank leg for custom mode editing.
  mutating func addLeg() {
    legDrafts.append(LegDraft(
      type: .expense, accountId: nil, amountText: "0",
      categoryId: nil, categoryText: "", earmarkId: nil
    ))
  }

  /// Remove a leg at the given index.
  mutating func removeLeg(at index: Int) {
    legDrafts.remove(at: index)
  }
}
```

- [ ] **Step 4: Run tests to verify they all pass**

Run: `just test 2>&1 | tee .agent-tmp/test-draft-edge.txt`
Expected: ALL tests PASS

- [ ] **Step 5: Commit**

```bash
git add Shared/Models/TransactionDraft.swift MoolahTests/Shared/TransactionDraftTests.swift
git commit -m "feat: add custom mode operations and edge case tests"
```

---

### Task 8: Update TransactionDetailView to Use New Draft API

Rewrite the view to be a thin binding layer over the new `TransactionDraft`. Remove all business logic from the view. Update the init, save logic, type section, account section, and autofill.

**Files:**
- Rewrite: `Features/Transactions/Views/TransactionDetailView.swift`

This is the largest task. The view goes from 957 lines of mixed logic/UI to a pure binding layer.

- [ ] **Step 1: Update the view's stored properties and init**

Remove `modeBinding` computed property. Replace init to use the new `TransactionDraft` init:

```swift
struct TransactionDetailView: View {
  let transaction: Transaction
  let accounts: Accounts
  let categories: Categories
  let earmarks: Earmarks
  let transactionStore: TransactionStore
  let showRecurrence: Bool
  let viewingAccountId: UUID?
  let supportsComplexTransactions: Bool
  let onUpdate: (Transaction) -> Void
  let onDelete: (UUID) -> Void

  @State private var draft: TransactionDraft
  @State private var showDeleteConfirmation = false
  @State private var showPayeeSuggestions = false
  @State private var payeeHighlightedIndex: Int?
  @State private var showCategorySuggestions = false
  @State private var categoryHighlightedIndex: Int?
  @State private var categoryJustSelected = false
  @State private var legPendingDeletion: Int?
  @State private var legCategoryJustSelected: [Int: Bool] = [:]
  @State private var showLegCategorySuggestions: [Int: Bool] = [:]
  @State private var legCategoryHighlightedIndex: [Int: Int?] = [:]
  @FocusState private var focusedField: Field?

  private enum Field: Hashable {
    case payee
    case amount
    case legAmount(Int)
  }

  private enum TransactionMode: Hashable {
    case income, expense, transfer, custom

    var displayName: String {
      switch self {
      case .income: return "Income"
      case .expense: return "Expense"
      case .transfer: return "Transfer"
      case .custom: return "Custom"
      }
    }
  }

  private var availableModes: [TransactionMode] {
    supportsComplexTransactions
      ? [.income, .expense, .transfer, .custom]
      : [.income, .expense, .transfer]
  }

  init(
    transaction: Transaction,
    accounts: Accounts,
    categories: Categories,
    earmarks: Earmarks,
    transactionStore: TransactionStore,
    showRecurrence: Bool = false,
    viewingAccountId: UUID? = nil,
    supportsComplexTransactions: Bool = false,
    onUpdate: @escaping (Transaction) -> Void,
    onDelete: @escaping (UUID) -> Void
  ) {
    self.transaction = transaction
    self.accounts = accounts
    self.categories = categories
    self.earmarks = earmarks
    self.transactionStore = transactionStore
    self.showRecurrence = showRecurrence
    self.viewingAccountId = viewingAccountId
    self.supportsComplexTransactions = supportsComplexTransactions
    self.onUpdate = onUpdate
    self.onDelete = onDelete

    var initialDraft = TransactionDraft(from: transaction, viewingAccountId: viewingAccountId)
    // Populate category text for all legs
    for i in initialDraft.legDrafts.indices {
      if let catId = initialDraft.legDrafts[i].categoryId,
         let cat = categories.by(id: catId) {
        initialDraft.legDrafts[i].categoryText = categories.path(for: cat)
      }
    }
    _draft = State(initialValue: initialDraft)
  }
```

- [ ] **Step 2: Replace `modeBinding` with a binding that delegates to draft methods**

```swift
  private var modeBinding: Binding<TransactionMode> {
    Binding(
      get: {
        if draft.isCustom { return .custom }
        switch draft.type {
        case .income: return .income
        case .expense: return .expense
        case .transfer: return .transfer
        case .openingBalance: return .expense
        }
      },
      set: { newMode in
        switch newMode {
        case .custom:
          draft.isCustom = true
        case .income:
          if draft.isCustom {
            draft.switchToSimple()
          }
          draft.setType(.income, accounts: accounts)
        case .expense:
          if draft.isCustom {
            draft.switchToSimple()
          }
          draft.setType(.expense, accounts: accounts)
        case .transfer:
          if draft.isCustom {
            draft.switchToSimple()
          }
          draft.setType(.transfer, accounts: accounts)
        }
      }
    )
  }
```

- [ ] **Step 3: Replace `saveIfValid` with the new single entry point**

```swift
  private func saveIfValid() {
    guard let updated = draft.toTransaction(id: transaction.id, accounts: accounts) else { return }
    onUpdate(updated)
  }
```

- [ ] **Step 4: Update `typeSection` — remove `onChange` handlers for draft.type, draft.toAccountId, draft.isCustom**

The `onChange` handlers that managed mode switching and auto-promotion are no longer needed — those side effects now live in the draft's `setType` method.

Replace the typeSection with:

```swift
  private var typeSection: some View {
    Section {
      if transaction.legs.contains(where: { $0.type == .openingBalance }) {
        LabeledContent("Type") {
          Text(TransactionType.openingBalance.displayName)
            .foregroundStyle(.secondary)
        }
      } else if !transaction.isSimple && !draft.isCustom {
        LabeledContent("Type") {
          Text("Custom")
            .foregroundStyle(.secondary)
        }
        .accessibilityHint(
          "This transaction has custom sub-transactions and cannot be changed to a simpler type.")
      } else {
        Picker("Type", selection: modeBinding) {
          ForEach(availableModes, id: \.self) { mode in
            Text(mode.displayName).tag(mode)
          }
        }
        .accessibilityLabel("Transaction type")
        #if os(iOS)
          .pickerStyle(.segmented)
        #endif
      }
    }
  }
```

- [ ] **Step 5: Update `accountSection` — filter to-accounts by currency**

```swift
  private var accountSection: some View {
    Section {
      Picker("Account", selection: $draft.legDrafts[draft.relevantLegIndex].accountId) {
        Text("None").tag(UUID?.none)
        ForEach(sortedAccounts) { account in
          Text(account.name).tag(UUID?.some(account.id))
        }
      }

      if draft.type == .transfer {
        let currency = draft.accountId.flatMap { accounts.by(id: $0) }?.balance.instrument
        let eligibleAccounts = currency.map {
          TransactionDraftHelpers.eligibleToAccounts(from: accounts, currency: $0)
            .filter { $0.id != draft.accountId && !$0.isHidden }
            .sorted { a, b in
              if a.type.isCurrent != b.type.isCurrent { return a.type.isCurrent }
              return a.position < b.position
            }
        } ?? []

        Picker(
          draft.showFromAccount ? "From Account" : "To Account",
          selection: $draft.legDrafts[draft.relevantLegIndex == 0 ? 1 : 0].accountId
        ) {
          Text("Select...").tag(UUID?.none)
          ForEach(eligibleAccounts) { account in
            Text(account.name).tag(UUID?.some(account.id))
          }
        }
      }
    }
  }
```

- [ ] **Step 6: Update `detailsSection` — bind amount through `setAmount`**

For the amount field, we need a binding that calls `draft.setAmount()` on set:

```swift
  private var amountBinding: Binding<String> {
    Binding(
      get: { draft.amountText },
      set: { draft.setAmount($0) }
    )
  }
```

Then in `detailsSection`, replace `$draft.amountText` with `amountBinding`.

Also update the currency label to read from the relevant leg:

```swift
      HStack {
        TextField("Amount", text: amountBinding)
          .multilineTextAlignment(.trailing)
          #if os(iOS)
            .keyboardType(.decimalPad)
          #endif
        Text(
          draft.legDrafts[draft.relevantLegIndex].accountId
            .flatMap { accounts.by(id: $0) }?
            .balance.instrument.id ?? ""
        )
        .foregroundStyle(.secondary)
      }
```

- [ ] **Step 7: Update `categorySection` — bind to primary leg (index 0)**

The category and earmark bindings already go through the computed accessors on the draft (`draft.categoryId`, `draft.categoryText`, `draft.earmarkId`), which read/write `legDrafts[0]`. So `$draft.categoryId`, `$draft.categoryText`, and `$draft.earmarkId` will work via the computed setters.

Verify that the category focus handler still works:

```swift
      .onChange(of: categoryFieldFocused) { _, focused in
        if !focused {
          categoryJustSelected = true
          showCategorySuggestions = false
          categoryHighlightedIndex = nil
          if let id = draft.categoryId, let cat = categories.by(id: id) {
            draft.categoryText = categories.path(for: cat)
          } else {
            draft.categoryText = ""
            draft.categoryId = nil
          }
        }
      }
```

This reads/writes `draft.categoryId` and `draft.categoryText`, which delegate to `legDrafts[0]`. No change needed.

- [ ] **Step 8: Update `addSubTransactionSection` to use `draft.addLeg()`**

```swift
  private var addSubTransactionSection: some View {
    Section {
      Button("Add Sub-transaction") {
        draft.addLeg()
      }
      .accessibilityLabel("Add sub-transaction")
    }
  }
```

- [ ] **Step 9: Update `autofillFromPayee` to use simplified autofill**

```swift
  private func autofillFromPayee(_ selectedPayee: String) {
    Task {
      guard let match = await transactionStore.fetchTransactionForAutofill(payee: selectedPayee)
      else { return }
      draft.applyAutofill(from: match, categories: categories)
    }
  }
```

- [ ] **Step 10: Remove `onChange` handlers that are no longer needed**

Remove from the body:
- `onChange(of: draft.type)` — handled by `setType`
- `onChange(of: draft.toAccountId)` — cross-currency auto-promotion removed (to-account picker filtered instead)
- `onChange(of: draft.isCustom)` — mode switching handled by `switchToSimple()` / setting `isCustom = true`

Keep:
- `onChange(of: draft)` for debounced save
- `onChange(of: legCategoryFieldFocused)` for category text cleanup (this is UI coordination, stays in view)
- `onChange(of: categoryFieldFocused)` for category text cleanup

- [ ] **Step 11: Update `isEditable` and `isNewTransaction`**

```swift
  private var isEditable: Bool {
    transaction.isSimple || draft.isCustom
  }

  private var isNewTransaction: Bool {
    if draft.isCustom {
      let allLegsEmpty = draft.legDrafts.allSatisfy { $0.amountText == "0" || $0.amountText.isEmpty }
      return allLegsEmpty && (transaction.payee?.isEmpty ?? true)
    }
    return (draft.amountText == "0" || draft.amountText.isEmpty) && (transaction.payee?.isEmpty ?? true)
  }
```

- [ ] **Step 12: Remove the `relevantLeg` computed property from the view**

It's no longer needed — the draft handles leg selection internally.

- [ ] **Step 13: Build and fix compilation errors**

Run: `just build-mac 2>&1 | tee .agent-tmp/build-view.txt`

Fix any remaining compilation errors. The main sources will be:
- References to removed properties (`draft.accountId` as a direct field → now a computed accessor, should still work)
- `$draft.amountText` in bindings → replace with `amountBinding`
- `$draft.type` in bindings → replaced by `modeBinding`
- Category bindings already delegate through computed accessors

- [ ] **Step 14: Run full test suite**

Run: `just test 2>&1 | tee .agent-tmp/test-full.txt`
Expected: ALL tests PASS

- [ ] **Step 15: Check for compiler warnings**

Run: `mcp__xcode__XcodeListNavigatorIssues` with severity "warning"
Fix any warnings.

- [ ] **Step 16: Commit**

```bash
git add Features/Transactions/Views/TransactionDetailView.swift
git commit -m "refactor: rewrite TransactionDetailView as thin binding layer over TransactionDraft"
```

---

### Task 9: Update TransactionInspectorModifier and Integration Points

Verify that the view's external API hasn't changed and all call sites still compile.

**Files:**
- Verify: `Features/Transactions/Views/TransactionInspectorModifier.swift`
- Verify: Any other files that reference `TransactionDraft` directly

- [ ] **Step 1: Search for all references to `TransactionDraft`**

```bash
grep -r "TransactionDraft" --include="*.swift" -l
```

- [ ] **Step 2: Verify each call site compiles with the new API**

The main concern: any code that creates a `TransactionDraft` directly (not through `init(from:)` or `init(accountId:)`) will need updating since the stored properties changed.

Search for direct member-wise init usage:

```bash
grep -r "TransactionDraft(" --include="*.swift" -A5
```

Update any direct initialisations to use the new property names. The `TransactionInspectorModifier` creates `TransactionDetailView` which takes `Transaction` objects — it shouldn't need changes since the view's external API is unchanged.

- [ ] **Step 3: Build both platforms**

Run: `just build-mac 2>&1 | tee .agent-tmp/build-mac.txt`
Run: `just build-ios 2>&1 | tee .agent-tmp/build-ios.txt`
Expected: Both build successfully

- [ ] **Step 4: Run full test suite**

Run: `just test 2>&1 | tee .agent-tmp/test-integration.txt`
Expected: ALL tests PASS (including TransactionStoreTests which may create drafts)

- [ ] **Step 5: Check for compiler warnings**

Run: `mcp__xcode__XcodeListNavigatorIssues` with severity "warning"

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "fix: update all TransactionDraft call sites for unified legs API"
```

---

### Task 10: Manual Testing and Cleanup

Run the app and verify the transaction detail view works correctly for all transaction types.

**Files:**
- Cleanup: `.agent-tmp/` temp files

- [ ] **Step 1: Run the macOS app**

Run: `just run-mac`

- [ ] **Step 2: Test simple expense**

Create a new expense, enter payee, amount, category, earmark. Verify it saves. Re-open and verify all fields round-trip.

- [ ] **Step 3: Test simple income**

Create a new income transaction. Verify amount is positive in the list view.

- [ ] **Step 4: Test simple transfer**

Create a transfer. Verify:
- "To Account" picker only shows same-currency accounts
- Amount mirrors correctly
- Label changes to "From Account" when viewing from destination

- [ ] **Step 5: Test custom mode**

Switch a simple expense to custom. Add legs. Switch back to simple (when applicable). Verify:
- Legs preserved when switching to custom
- Can add/remove legs
- Each leg has independent type, account, amount, category, earmark

- [ ] **Step 6: Test autofill**

Type a payee that matches an existing transaction. Verify all fields populate. Verify date is NOT overwritten.

- [ ] **Step 7: Test recurrence**

Enable recurrence, set period and interval. Save. Re-open and verify.

- [ ] **Step 8: Test opening balance (read-only)**

Open an opening balance transaction. Verify it shows as read-only.

- [ ] **Step 9: Clean up temp files**

```bash
rm -rf .agent-tmp/test-*.txt .agent-tmp/build-*.txt
```

- [ ] **Step 10: Final commit if any fixes were needed**

```bash
git add -A
git commit -m "fix: address issues found during manual testing"
```
