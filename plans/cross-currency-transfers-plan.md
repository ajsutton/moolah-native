# Cross-Currency Transfers Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Support cross-currency transfers in the transaction detail panel — both a simple cross-currency transfer UI and a custom leg instrument picker.

**Architecture:** Two features built incrementally: (1) Model-layer changes to `Transaction` and `TransactionDraft` to detect and edit cross-currency transfers, with tests first. (2) View-layer changes to `TransactionDetailView` to show received amount, derived rate, unrestricted account picker, and custom leg instrument picker. All model logic is tested via `TransactionDraftTests`.

**Tech Stack:** Swift, SwiftUI, Swift Testing framework

---

### Task 1: Add `Transaction.isSimpleCrossCurrencyTransfer` Property

**Files:**
- Modify: `Domain/Models/Transaction.swift:118-128`
- Test: `MoolahTests/Domain/TransactionTests.swift` (create if needed, or add to existing)

- [ ] **Step 1: Write the failing tests**

Add tests to a new section in the Transaction tests. These tests need an `Accounts` parameter since the property requires account lookup.

Actually, looking at the spec more carefully: `isSimpleCrossCurrencyTransfer` checks structural properties of the legs (different instruments, both transfers, 2 legs, different accounts, no category/earmark on second leg). The "instrument matches account" check happens in the draft init, not in this property. So this property only needs leg data.

```swift
// In MoolahTests/Domain/TransactionTests.swift (or create a new section)

@Test func isSimpleCrossCurrencyTransferWithDifferentInstruments() {
  let tx = Transaction(
    date: Date(),
    legs: [
      TransactionLeg(accountId: UUID(), instrument: .AUD, quantity: -100, type: .transfer),
      TransactionLeg(accountId: UUID(), instrument: .USD, quantity: 65, type: .transfer),
    ]
  )
  #expect(tx.isSimpleCrossCurrencyTransfer == true)
}

@Test func isSimpleCrossCurrencyTransferFalseForSameCurrency() {
  let acctA = UUID()
  let acctB = UUID()
  let tx = Transaction(
    date: Date(),
    legs: [
      TransactionLeg(accountId: acctA, instrument: .AUD, quantity: -100, type: .transfer),
      TransactionLeg(accountId: acctB, instrument: .AUD, quantity: 100, type: .transfer),
    ]
  )
  #expect(tx.isSimpleCrossCurrencyTransfer == false)
}

@Test func isSimpleCrossCurrencyTransferFalseForSingleLeg() {
  let tx = Transaction(
    date: Date(),
    legs: [
      TransactionLeg(accountId: UUID(), instrument: .AUD, quantity: -100, type: .expense),
    ]
  )
  #expect(tx.isSimpleCrossCurrencyTransfer == false)
}

@Test func isSimpleCrossCurrencyTransferFalseWhenSecondLegHasCategory() {
  let tx = Transaction(
    date: Date(),
    legs: [
      TransactionLeg(accountId: UUID(), instrument: .AUD, quantity: -100, type: .transfer),
      TransactionLeg(accountId: UUID(), instrument: .USD, quantity: 65, type: .transfer, categoryId: UUID()),
    ]
  )
  #expect(tx.isSimpleCrossCurrencyTransfer == false)
}

@Test func isSimpleCrossCurrencyTransferFalseWhenSameAccount() {
  let acctA = UUID()
  let tx = Transaction(
    date: Date(),
    legs: [
      TransactionLeg(accountId: acctA, instrument: .AUD, quantity: -100, type: .transfer),
      TransactionLeg(accountId: acctA, instrument: .USD, quantity: 65, type: .transfer),
    ]
  )
  #expect(tx.isSimpleCrossCurrencyTransfer == false)
}

@Test func isSimpleCrossCurrencyTransferFalseWhenNilAccountId() {
  let tx = Transaction(
    date: Date(),
    legs: [
      TransactionLeg(accountId: UUID(), instrument: .AUD, quantity: -100, type: .transfer),
      TransactionLeg(accountId: nil, instrument: .USD, quantity: 65, type: .transfer),
    ]
  )
  #expect(tx.isSimpleCrossCurrencyTransfer == false)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `just test 2>&1 | tee .agent-tmp/test-task1.txt`
Expected: Compilation error — `isSimpleCrossCurrencyTransfer` doesn't exist yet.

- [ ] **Step 3: Implement `isSimpleCrossCurrencyTransfer`**

Add to `Domain/Models/Transaction.swift` after the `isSimple` property:

```swift
/// Whether this transaction is a simple cross-currency transfer: exactly 2 transfer legs
/// with different accounts and different instruments, second leg has no category/earmark.
/// Like `isSimple` but without the `a.quantity == -b.quantity` constraint, plus requiring
/// different instruments.
var isSimpleCrossCurrencyTransfer: Bool {
  guard legs.count == 2 else { return false }
  let a = legs[0]
  let b = legs[1]
  guard a.type == .transfer && b.type == .transfer else { return false }
  guard let aAcct = a.accountId, let bAcct = b.accountId, aAcct != bAcct else { return false }
  guard b.categoryId == nil && b.earmarkId == nil else { return false }
  return a.instrument != b.instrument
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `just test 2>&1 | tee .agent-tmp/test-task1.txt`
Expected: All new tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Domain/Models/Transaction.swift MoolahTests/Domain/TransactionTests.swift
git commit -m "feat: add Transaction.isSimpleCrossCurrencyTransfer property"
```

---

### Task 2: TransactionDraft — Cross-Currency Init and Amount Editing

**Files:**
- Modify: `Shared/Models/TransactionDraft.swift`
- Test: `MoolahTests/Shared/TransactionDraftTests.swift`

This task adds:
1. `accounts` parameter on `init(from:viewingAccountId:)` 
2. `isCrossCurrencyTransfer(accounts:)` computed property
3. `setCounterpartAmount(_:)` method
4. Conditional mirroring in `setAmount` (stop mirroring when cross-currency)

- [ ] **Step 1: Write failing tests for cross-currency draft init**

Add to `TransactionDraftTests.swift`:

```swift
// MARK: - Cross-Currency Transfers

@Test func initFromCrossCurrencyTransferUsesSimpleMode() {
  let acctA = UUID()
  let acctB = UUID()
  let tx = Transaction(
    date: Date(),
    payee: "FX",
    legs: [
      TransactionLeg(accountId: acctA, instrument: .AUD, quantity: -100, type: .transfer),
      TransactionLeg(accountId: acctB, instrument: .USD, quantity: 65, type: .transfer),
    ]
  )
  let accounts = makeAccounts([
    makeAccount(id: acctA, instrument: .AUD),
    makeAccount(id: acctB, instrument: .USD),
  ])

  let draft = TransactionDraft(from: tx, viewingAccountId: acctA, accounts: accounts)

  #expect(draft.isCustom == false)
  #expect(draft.relevantLegIndex == 0)
  #expect(draft.legDrafts.count == 2)
  #expect(draft.legDrafts[0].amountText == "100.00")  // negated for display
  #expect(draft.legDrafts[1].amountText == "-65.00")   // negated for display (transfer)
}

@Test func initFromCrossCurrencyTransferFallsToCustomWhenInstrumentMismatchesAccount() {
  let acctA = UUID()
  let acctB = UUID()
  let tx = Transaction(
    date: Date(),
    legs: [
      TransactionLeg(accountId: acctA, instrument: .USD, quantity: -100, type: .transfer),
      TransactionLeg(accountId: acctB, instrument: .AUD, quantity: 155, type: .transfer),
    ]
  )
  // Account A is AUD but leg has USD — mismatch
  let accounts = makeAccounts([
    makeAccount(id: acctA, instrument: .AUD),
    makeAccount(id: acctB, instrument: .AUD),
  ])

  let draft = TransactionDraft(from: tx, viewingAccountId: acctA, accounts: accounts)
  #expect(draft.isCustom == true)
}
```

- [ ] **Step 2: Write failing tests for `isCrossCurrencyTransfer(accounts:)`**

```swift
@Test func isCrossCurrencyTransferTrueWhenDifferentCurrencies() {
  let acctA = UUID()
  let acctB = UUID()
  let accounts = makeAccounts([
    makeAccount(id: acctA, instrument: .AUD),
    makeAccount(id: acctB, instrument: .USD),
  ])
  var draft = makeExpenseDraft(amountText: "100.00", accountId: acctA)
  draft.setType(.transfer, accounts: accounts)
  draft.toAccountId = acctB

  #expect(draft.isCrossCurrencyTransfer(accounts: accounts) == true)
}

@Test func isCrossCurrencyTransferFalseWhenSameCurrency() {
  let acctA = UUID()
  let acctB = UUID()
  let accounts = makeAccounts([
    makeAccount(id: acctA, instrument: .AUD),
    makeAccount(id: acctB, instrument: .AUD),
  ])
  var draft = makeExpenseDraft(amountText: "100.00", accountId: acctA)
  draft.setType(.transfer, accounts: accounts)
  draft.toAccountId = acctB

  #expect(draft.isCrossCurrencyTransfer(accounts: accounts) == false)
}

@Test func isCrossCurrencyTransferFalseWhenNotTransfer() {
  let acctA = UUID()
  let accounts = makeAccounts([makeAccount(id: acctA, instrument: .AUD)])
  let draft = makeExpenseDraft(amountText: "100.00", accountId: acctA)

  #expect(draft.isCrossCurrencyTransfer(accounts: accounts) == false)
}
```

- [ ] **Step 3: Write failing tests for `setCounterpartAmount` and conditional mirroring**

```swift
@Test func setCounterpartAmountSetsCounterpartLeg() {
  let acctA = UUID()
  let acctB = UUID()
  let accounts = makeAccounts([
    makeAccount(id: acctA, instrument: .AUD),
    makeAccount(id: acctB, instrument: .USD),
  ])
  var draft = makeExpenseDraft(amountText: "100.00", accountId: acctA)
  draft.setType(.transfer, accounts: accounts)
  draft.toAccountId = acctB

  draft.setCounterpartAmount("65.00")

  let counterIdx = draft.relevantLegIndex == 0 ? 1 : 0
  #expect(draft.legDrafts[counterIdx].amountText == "65.00")
}

@Test func setAmountDoesNotMirrorWhenCrossCurrency() {
  let acctA = UUID()
  let acctB = UUID()
  let accounts = makeAccounts([
    makeAccount(id: acctA, instrument: .AUD),
    makeAccount(id: acctB, instrument: .USD),
  ])
  var draft = makeExpenseDraft(amountText: "100.00", accountId: acctA)
  draft.setType(.transfer, accounts: accounts)
  draft.toAccountId = acctB
  draft.setCounterpartAmount("65.00")

  // Change primary amount — counterpart should NOT mirror
  draft.setAmount("200.00", accounts: accounts)

  let counterIdx = draft.relevantLegIndex == 0 ? 1 : 0
  #expect(draft.legDrafts[counterIdx].amountText == "65.00")  // unchanged
}

@Test func setAmountStillMirrorsWhenSameCurrency() {
  let acctA = UUID()
  let acctB = UUID()
  let accounts = makeAccounts([
    makeAccount(id: acctA, instrument: .AUD),
    makeAccount(id: acctB, instrument: .AUD),
  ])
  var draft = makeExpenseDraft(amountText: "100.00", accountId: acctA)
  draft.setType(.transfer, accounts: accounts)
  draft.toAccountId = acctB

  draft.setAmount("200.00", accounts: accounts)

  let counterIdx = draft.relevantLegIndex == 0 ? 1 : 0
  #expect(draft.legDrafts[counterIdx].amountText == "-200.00")  // mirrored
}
```

- [ ] **Step 4: Run tests to verify they fail**

Run: `just test 2>&1 | tee .agent-tmp/test-task2.txt`
Expected: Compilation errors — new methods/parameters don't exist yet.

- [ ] **Step 5: Implement the changes**

In `TransactionDraft.swift`:

**5a.** Add `isCrossCurrencyTransfer(accounts:)` to the computed accessors section:

```swift
/// Whether the current draft is a cross-currency transfer: both legs have accounts
/// with different instruments.
func isCrossCurrencyTransfer(accounts: Accounts) -> Bool {
  guard legDrafts.count == 2, type == .transfer else { return false }
  guard let acctIdA = legDrafts[0].accountId, let acctIdB = legDrafts[1].accountId,
        let accountA = accounts.by(id: acctIdA), let accountB = accounts.by(id: acctIdB)
  else { return false }
  return accountA.instrument != accountB.instrument
}
```

**5b.** Add `accounts` parameter to `init(from:viewingAccountId:)`:

```swift
init(from transaction: Transaction, viewingAccountId: UUID? = nil, accounts: Accounts = Accounts(from: [])) {
  // ... existing code for building drafts ...

  // Determine isCustom: simple same-currency OR simple cross-currency
  let isCrossCurrency = transaction.isSimpleCrossCurrencyTransfer
    && transaction.legs.allSatisfy { leg in
      guard let acctId = leg.accountId,
            let account = accounts.by(id: acctId)
      else { return false }
      return leg.instrument == account.instrument
    }

  let isCustom = !(transaction.isSimple || isCrossCurrency)

  // ... rest of init unchanged ...
}
```

**5c.** Add `setCounterpartAmount(_:)`:

```swift
/// Set the counterpart leg's display amount directly (for cross-currency transfers).
mutating func setCounterpartAmount(_ text: String) {
  if let idx = counterpartLegIndex {
    legDrafts[idx].amountText = text
  }
}
```

**5d.** Add `accounts` parameter to `setAmount` for conditional mirroring:

```swift
/// Change the display amount on the relevant leg, mirroring to counterpart for same-currency transfers.
mutating func setAmount(_ text: String, accounts: Accounts) {
  legDrafts[relevantLegIndex].amountText = text

  // Mirror to counterpart only for same-currency transfers
  if let idx = counterpartLegIndex, !isCrossCurrencyTransfer(accounts: accounts) {
    legDrafts[idx].amountText = negatedAmountText(text)
  }
}
```

Keep the existing `setAmount(_ text: String)` for backward compatibility (it always mirrors, used by code that doesn't have accounts context). Mark it with a comment noting the accounts-aware version is preferred for transfers.

Actually — looking at this more carefully, the view always has `accounts` available, and the old `setAmount` is used in `amountBinding`. Let's make it cleaner: change the existing `setAmount` to accept an optional `accounts` parameter defaulting to nil. When nil, it mirrors (backward compatible). When provided, it checks cross-currency.

```swift
/// Change the display amount on the relevant leg, mirroring to counterpart for same-currency transfers.
/// When `accounts` is provided, cross-currency transfers skip mirroring.
mutating func setAmount(_ text: String, accounts: Accounts? = nil) {
  legDrafts[relevantLegIndex].amountText = text

  if let idx = counterpartLegIndex {
    let isCrossCurrency = accounts.map { isCrossCurrencyTransfer(accounts: $0) } ?? false
    if !isCrossCurrency {
      legDrafts[idx].amountText = negatedAmountText(text)
    }
  }
}
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `just test 2>&1 | tee .agent-tmp/test-task2.txt`
Expected: All tests PASS (including existing tests which use `setAmount` without accounts parameter).

- [ ] **Step 7: Commit**

```bash
git add Shared/Models/TransactionDraft.swift MoolahTests/Shared/TransactionDraftTests.swift
git commit -m "feat: add cross-currency transfer support to TransactionDraft"
```

---

### Task 3: Relax `canSwitchToSimple` and Edge Case Handling

**Files:**
- Modify: `Shared/Models/TransactionDraft.swift`
- Test: `MoolahTests/Shared/TransactionDraftTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
@Test func canSwitchToSimpleAllowsCrossCurrencyAmounts() {
  // Two transfer legs with different amounts (cross-currency scenario)
  let draft = TransactionDraft(
    payee: "", date: Date(), notes: "",
    isRepeating: false, recurPeriod: nil, recurEvery: 1,
    isCustom: true,
    legDrafts: [
      TransactionDraft.LegDraft(
        type: .transfer, accountId: UUID(), amountText: "100.00",
        categoryId: nil, categoryText: "", earmarkId: nil),
      TransactionDraft.LegDraft(
        type: .transfer, accountId: UUID(), amountText: "-65.00",
        categoryId: nil, categoryText: "", earmarkId: nil),
    ],
    relevantLegIndex: 0, viewingAccountId: nil
  )
  #expect(draft.canSwitchToSimple == true)
}

@Test func switchToAccountFromCrossCurrencyToSameCurrencySnapsMirror() {
  let acctA = UUID()
  let acctB = UUID()  // USD
  let acctC = UUID()  // AUD (same as A)
  let accounts = makeAccounts([
    makeAccount(id: acctA, instrument: .AUD),
    makeAccount(id: acctB, instrument: .USD),
    makeAccount(id: acctC, instrument: .AUD),
  ])
  var draft = makeExpenseDraft(amountText: "100.00", accountId: acctA)
  draft.setType(.transfer, accounts: accounts)
  draft.toAccountId = acctB
  draft.setCounterpartAmount("65.00")

  // Switch to same-currency account
  draft.toAccountId = acctC
  draft.snapToSameCurrencyIfNeeded(accounts: accounts)

  // Counterpart should snap to negated primary
  let counterIdx = draft.relevantLegIndex == 0 ? 1 : 0
  #expect(draft.legDrafts[counterIdx].amountText == "-100.00")
}
```

- [ ] **Step 2: Run tests to verify they fail**

- [ ] **Step 3: Implement changes**

**3a.** Relax `canSwitchToSimple` — remove the amount-negation check:

```swift
var canSwitchToSimple: Bool {
  if legDrafts.count <= 1 { return true }
  guard legDrafts.count == 2 else { return false }
  let a = legDrafts[0]
  let b = legDrafts[1]
  guard a.type == b.type && a.type == .transfer else { return false }
  guard b.categoryId == nil && b.earmarkId == nil else { return false }
  guard a.accountId != nil && b.accountId != nil else { return false }
  guard a.accountId != b.accountId else { return false }
  return true
}
```

**3b.** Add `snapToSameCurrencyIfNeeded(accounts:)`:

```swift
/// When switching from cross-currency to same-currency, snap the counterpart amount
/// to the negated primary amount (resume standard mirroring).
mutating func snapToSameCurrencyIfNeeded(accounts: Accounts) {
  guard let idx = counterpartLegIndex, !isCrossCurrencyTransfer(accounts: accounts) else { return }
  legDrafts[idx].amountText = negatedAmountText(legDrafts[relevantLegIndex].amountText)
}
```

- [ ] **Step 4: Run tests to verify they pass**

- [ ] **Step 5: Commit**

```bash
git add Shared/Models/TransactionDraft.swift MoolahTests/Shared/TransactionDraftTests.swift
git commit -m "feat: relax canSwitchToSimple and add same-currency snap"
```

---

### Task 4: LegDraft `instrumentId` for Custom Mode

**Files:**
- Modify: `Shared/Models/TransactionDraft.swift`
- Test: `MoolahTests/Shared/TransactionDraftTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
@Test func legDraftInstrumentIdOverridesToTransaction() {
  let acctId = UUID()
  let accounts = makeAccounts([makeAccount(id: acctId, instrument: .AUD)])
  let availableInstruments = CurrencyPicker.commonCurrencyCodes.map { Instrument.fiat(code: $0) }
  let draft = TransactionDraft(
    payee: "", date: Date(), notes: "",
    isRepeating: false, recurPeriod: nil, recurEvery: 1,
    isCustom: true,
    legDrafts: [
      TransactionDraft.LegDraft(
        type: .expense, accountId: acctId, amountText: "100.00",
        categoryId: nil, categoryText: "", earmarkId: nil,
        instrumentId: "USD")
    ],
    relevantLegIndex: 0, viewingAccountId: nil
  )

  let tx = draft.toTransaction(id: UUID(), accounts: accounts, availableInstruments: availableInstruments)
  #expect(tx != nil)
  #expect(tx!.legs[0].instrument.id == "USD")
}

@Test func legDraftNilInstrumentIdDerivesFromAccount() {
  let acctId = UUID()
  let accounts = makeAccounts([makeAccount(id: acctId, instrument: .AUD)])
  let draft = TransactionDraft(
    payee: "", date: Date(), notes: "",
    isRepeating: false, recurPeriod: nil, recurEvery: 1,
    isCustom: true,
    legDrafts: [
      TransactionDraft.LegDraft(
        type: .expense, accountId: acctId, amountText: "100.00",
        categoryId: nil, categoryText: "", earmarkId: nil,
        instrumentId: nil)
    ],
    relevantLegIndex: 0, viewingAccountId: nil
  )

  let tx = draft.toTransaction(id: UUID(), accounts: accounts)
  #expect(tx != nil)
  #expect(tx!.legs[0].instrument.id == "AUD")
}

@Test func legDraftInvalidInstrumentIdReturnsNil() {
  let acctId = UUID()
  let accounts = makeAccounts([makeAccount(id: acctId, instrument: .AUD)])
  let draft = TransactionDraft(
    payee: "", date: Date(), notes: "",
    isRepeating: false, recurPeriod: nil, recurEvery: 1,
    isCustom: true,
    legDrafts: [
      TransactionDraft.LegDraft(
        type: .expense, accountId: acctId, amountText: "100.00",
        categoryId: nil, categoryText: "", earmarkId: nil,
        instrumentId: "FAKE_CURRENCY")
    ],
    relevantLegIndex: 0, viewingAccountId: nil
  )

  let tx = draft.toTransaction(id: UUID(), accounts: accounts, availableInstruments: [Instrument.fiat(code: "AUD")])
  #expect(tx == nil)
}
```

- [ ] **Step 2: Run tests to verify they fail**

- [ ] **Step 3: Implement changes**

**3a.** Add `instrumentId` to `LegDraft`:

```swift
struct LegDraft: Sendable, Equatable {
  var type: TransactionType
  var accountId: UUID?
  var amountText: String
  var categoryId: UUID?
  var categoryText: String
  var earmarkId: UUID?
  var instrumentId: String?  // nil = derive from account/earmark (current behavior)

  var isEarmarkOnly: Bool {
    accountId == nil && earmarkId != nil
  }
}
```

**3b.** Add `availableInstruments` parameter to `toTransaction`:

```swift
func toTransaction(
  id: UUID,
  accounts: Accounts,
  earmarks: Earmarks = Earmarks(from: []),
  availableInstruments: [Instrument] = []
) -> Transaction? {
  guard isValid else { return nil }

  var legs: [TransactionLeg] = []
  for legDraft in legDrafts {
    let instrument: Instrument
    if let overrideId = legDraft.instrumentId {
      // Resolve from available instruments
      guard let resolved = availableInstruments.first(where: { $0.id == overrideId }) else {
        return nil
      }
      instrument = resolved
    } else if let acctId = legDraft.accountId, let account = accounts.by(id: acctId) {
      instrument = account.instrument
    } else if let emId = legDraft.earmarkId, let earmark = earmarks.by(id: emId) {
      instrument = earmark.instrument
    } else {
      return nil
    }
    // ... rest unchanged
  }
  // ... rest unchanged
}
```

**3c.** Update all existing `LegDraft` initializer call sites to include `instrumentId: nil`. Since `LegDraft` is a struct and the field doesn't have a default value in the memberwise init, we need to add it. Actually, since Swift structs get automatic memberwise inits, and existing code doesn't pass `instrumentId`, we should give it a default value:

The simplest approach: add `instrumentId` with a default nil at the declaration site. But struct memberwise inits require all parameters in order. Since `LegDraft` is used with explicit `LegDraft(type:accountId:amountText:categoryId:categoryText:earmarkId:)` everywhere, we need to add `instrumentId` at the end with a default.

Actually, looking at existing code — `LegDraft` doesn't define a custom init; it uses the automatic memberwise initializer. We need to add a custom init that defaults `instrumentId: nil`:

```swift
struct LegDraft: Sendable, Equatable {
  var type: TransactionType
  var accountId: UUID?
  var amountText: String
  var categoryId: UUID?
  var categoryText: String
  var earmarkId: UUID?
  var instrumentId: String?

  init(
    type: TransactionType,
    accountId: UUID?,
    amountText: String,
    categoryId: UUID?,
    categoryText: String,
    earmarkId: UUID?,
    instrumentId: String? = nil
  ) {
    self.type = type
    self.accountId = accountId
    self.amountText = amountText
    self.categoryId = categoryId
    self.categoryText = categoryText
    self.earmarkId = earmarkId
    self.instrumentId = instrumentId
  }

  var isEarmarkOnly: Bool {
    accountId == nil && earmarkId != nil
  }
}
```

This keeps all existing call sites working without changes.

- [ ] **Step 4: Run tests to verify they pass**

- [ ] **Step 5: Commit**

```bash
git add Shared/Models/TransactionDraft.swift MoolahTests/Shared/TransactionDraftTests.swift
git commit -m "feat: add LegDraft.instrumentId and availableInstruments support"
```

---

### Task 5: Cross-Currency Transfer Round-Trip Tests

**Files:**
- Test: `MoolahTests/Shared/TransactionDraftTests.swift`

- [ ] **Step 1: Write tests for cross-currency round-trip and edge cases**

```swift
@Test func toTransactionRoundTripsCrossCurrencyTransfer() {
  let acctA = UUID()
  let acctB = UUID()
  let id = UUID()
  let original = Transaction(
    id: id,
    date: Date(),
    payee: "FX",
    legs: [
      TransactionLeg(accountId: acctA, instrument: .AUD, quantity: -100, type: .transfer),
      TransactionLeg(accountId: acctB, instrument: .USD, quantity: 65, type: .transfer),
    ]
  )
  let accounts = makeAccounts([
    makeAccount(id: acctA, instrument: .AUD),
    makeAccount(id: acctB, instrument: .USD),
  ])

  let draft = TransactionDraft(from: original, viewingAccountId: acctA, accounts: accounts)
  let roundTripped = draft.toTransaction(id: id, accounts: accounts)

  #expect(roundTripped != nil)
  #expect(roundTripped!.legs.count == 2)
  #expect(roundTripped!.legs[0].quantity == Decimal(string: "-100"))
  #expect(roundTripped!.legs[0].instrument == .AUD)
  #expect(roundTripped!.legs[1].quantity == Decimal(string: "65"))
  #expect(roundTripped!.legs[1].instrument == .USD)
}

@Test func crossCurrencyTransferFromDestinationPerspective() {
  let acctA = UUID()
  let acctB = UUID()
  let accounts = makeAccounts([
    makeAccount(id: acctA, instrument: .AUD),
    makeAccount(id: acctB, instrument: .USD),
  ])
  let tx = Transaction(
    date: Date(),
    legs: [
      TransactionLeg(accountId: acctA, instrument: .AUD, quantity: -100, type: .transfer),
      TransactionLeg(accountId: acctB, instrument: .USD, quantity: 65, type: .transfer),
    ]
  )

  let draft = TransactionDraft(from: tx, viewingAccountId: acctB, accounts: accounts)

  #expect(draft.relevantLegIndex == 1)
  #expect(draft.showFromAccount == true)
  // From destination perspective, relevant leg is the USD leg
  #expect(draft.legDrafts[1].amountText == "-65.00")  // transfer negate: -(65) = -65
}

@Test func counterpartAmountText() {
  let acctA = UUID()
  let acctB = UUID()
  let accounts = makeAccounts([
    makeAccount(id: acctA, instrument: .AUD),
    makeAccount(id: acctB, instrument: .USD),
  ])
  let tx = Transaction(
    date: Date(),
    legs: [
      TransactionLeg(accountId: acctA, instrument: .AUD, quantity: -100, type: .transfer),
      TransactionLeg(accountId: acctB, instrument: .USD, quantity: 65, type: .transfer),
    ]
  )

  let draft = TransactionDraft(from: tx, viewingAccountId: acctA, accounts: accounts)

  // Counterpart amount text for the USD leg (index 1)
  #expect(draft.counterpartLeg?.amountText == "-65.00")
}
```

- [ ] **Step 2: Run tests to verify they pass**

These should already pass with Task 2's implementation. If not, fix.

- [ ] **Step 3: Commit**

```bash
git add MoolahTests/Shared/TransactionDraftTests.swift
git commit -m "test: add cross-currency transfer round-trip and perspective tests"
```

---

### Task 6: TransactionDetailView — Cross-Currency Amount Field and Derived Rate

**Files:**
- Modify: `Features/Transactions/Views/TransactionDetailView.swift`

This task modifies the view to show the "Received"/"Sent" amount field and derived exchange rate.

- [ ] **Step 1: Add `.counterpartAmount` to the `Field` enum**

```swift
private enum Field: Hashable {
  case payee
  case amount
  case counterpartAmount
  case legAmount(Int)
}
```

- [ ] **Step 2: Add helper computed properties**

Add to `TransactionDetailView`:

```swift
/// Whether the current draft is a cross-currency simple transfer.
private var isCrossCurrency: Bool {
  !draft.isCustom && draft.type == .transfer && draft.isCrossCurrencyTransfer(accounts: accounts)
}

/// The instrument for the counterpart leg's account.
private var counterpartInstrument: Instrument? {
  draft.counterpartLeg?.accountId
    .flatMap { accounts.by(id: $0) }?
    .instrument
}

/// Binding for counterpart amount text.
private var counterpartAmountBinding: Binding<String> {
  Binding(
    get: { draft.counterpartLeg?.amountText ?? "" },
    set: { draft.setCounterpartAmount($0) }
  )
}

/// Derived exchange rate string (e.g., "≈ 1 USD = 1.55 AUD"), or nil when not computable.
private var derivedRateText: String? {
  guard let relevantInst = relevantInstrument,
        let counterpartInst = counterpartInstrument,
        let primaryQty = InstrumentAmount.parseQuantity(
          from: draft.amountText, decimals: relevantInst.decimals),
        let counterQty = InstrumentAmount.parseQuantity(
          from: draft.counterpartLeg?.amountText ?? "", decimals: counterpartInst.decimals),
        primaryQty != .zero && counterQty != .zero
  else { return nil }

  let absPrimary = abs(primaryQty)
  let absCounter = abs(counterQty)
  let rate = absCounter / absPrimary
  let rateFormatted = rate.formatted(.number.precision(.significantDigits(2...4)).grouping(.never))
  return "≈ 1 \(relevantInst.id) = \(rateFormatted) \(counterpartInst.id)"
}

/// Accessibility label for the derived rate.
private var derivedRateAccessibilityLabel: String? {
  guard let relevantInst = relevantInstrument,
        let counterpartInst = counterpartInstrument,
        let primaryQty = InstrumentAmount.parseQuantity(
          from: draft.amountText, decimals: relevantInst.decimals),
        let counterQty = InstrumentAmount.parseQuantity(
          from: draft.counterpartLeg?.amountText ?? "", decimals: counterpartInst.decimals),
        primaryQty != .zero && counterQty != .zero
  else { return nil }

  let absPrimary = abs(primaryQty)
  let absCounter = abs(counterQty)
  let rate = absCounter / absPrimary
  let rateFormatted = rate.formatted(.number.precision(.significantDigits(2...4)).grouping(.never))
  return "Approximate exchange rate: 1 \(relevantInst.id) equals \(rateFormatted) \(counterpartInst.id)"
}
```

- [ ] **Step 3: Update `amountBinding` to use accounts-aware `setAmount`**

```swift
private var amountBinding: Binding<String> {
  Binding(
    get: { draft.amountText },
    set: { draft.setAmount($0, accounts: accounts) }
  )
}
```

- [ ] **Step 4: Add received/sent field and rate label to `accountSection`**

Update `accountSection` to include the cross-currency fields after the to-account picker:

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
      let counterpartIndex = draft.relevantLegIndex == 0 ? 1 : 0
      let toAccountLabel = draft.showFromAccount ? "From Account" : "To Account"
      let currentAccountId = draft.legDrafts[draft.relevantLegIndex].accountId
      let eligibleAccounts = eligibleTransferAccounts(excluding: currentAccountId)

      Picker(toAccountLabel, selection: $draft.legDrafts[counterpartIndex].accountId) {
        Text("Select...").tag(UUID?.none)
        ForEach(eligibleAccounts) { account in
          Text(account.name).tag(UUID?.some(account.id))
        }
      }
      .onChange(of: draft.legDrafts[counterpartIndex].accountId) { _, _ in
        draft.snapToSameCurrencyIfNeeded(accounts: accounts)
      }

      if isCrossCurrency {
        let fieldLabel = draft.showFromAccount ? "Sent" : "Received"
        HStack {
          Text(fieldLabel)
          Spacer()
          TextField("", text: counterpartAmountBinding)
            .multilineTextAlignment(.trailing)
            .monospacedDigit()
            #if os(iOS)
              .keyboardType(.decimalPad)
            #endif
            .focused($focusedField, equals: .counterpartAmount)
          Text(counterpartInstrument?.id ?? "")
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
        .accessibilityLabel(draft.showFromAccount ? "Sent amount" : "Received amount")

        if let rateText = derivedRateText {
          Text(rateText)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .accessibilityLabel(derivedRateAccessibilityLabel ?? "")
        }
      }
    }
  }
}
```

- [ ] **Step 5: Update `eligibleTransferAccounts` to remove same-currency filter**

```swift
private func eligibleTransferAccounts(excluding currentAccountId: UUID?) -> [Account] {
  sortedAccounts.filter { $0.id != currentAccountId && !$0.isHidden }
}
```

- [ ] **Step 6: Add focus management for `.counterpartAmount`**

Update the `.onSubmit` of the amount field in `detailsSection` to advance to `.counterpartAmount` when visible:

```swift
// In detailsSection, update the amount HStack:
HStack {
  TextField("Amount", text: amountBinding)
    .multilineTextAlignment(.trailing)
    .monospacedDigit()
    #if os(iOS)
      .keyboardType(.decimalPad)
    #endif
    .focused($focusedField, equals: .amount)
    .onSubmit {
      if isCrossCurrency {
        focusedField = .counterpartAmount
      }
    }
  Text(relevantInstrument?.id ?? "").foregroundStyle(.secondary)
    .monospacedDigit()
}
```

- [ ] **Step 7: Add the Cross-Currency Transfer preview**

```swift
#Preview("Cross-Currency Transfer") {
  let accountId1 = UUID()
  let accountId2 = UUID()
  NavigationStack {
    TransactionDetailView(
      transaction: Transaction(
        date: Date(),
        payee: "Currency Exchange",
        legs: [
          TransactionLeg(accountId: accountId1, instrument: .USD, quantity: -100, type: .transfer),
          TransactionLeg(accountId: accountId2, instrument: .AUD, quantity: 155, type: .transfer),
        ]
      ),
      accounts: Accounts(from: [
        Account(id: accountId1, name: "US Checking", type: .bank, instrument: .USD),
        Account(id: accountId2, name: "AU Savings", type: .bank, instrument: .AUD),
        Account(name: "Credit Card", type: .creditCard, instrument: .USD),
      ]),
      categories: Categories(from: []),
      earmarks: Earmarks(from: []),
      transactionStore: {
        let (backend, _) = PreviewBackend.create()
        return TransactionStore(
          repository: backend.transactions,
          conversionService: backend.conversionService,
          targetInstrument: .AUD
        )
      }(),
      viewingAccountId: accountId1,
      supportsComplexTransactions: true,
      onUpdate: { _ in },
      onDelete: { _ in }
    )
  }
}
```

- [ ] **Step 8: Update the `init` to pass accounts through to TransactionDraft**

Update the view's init to pass accounts to the draft:

```swift
var initialDraft = TransactionDraft(from: transaction, viewingAccountId: viewingAccountId, accounts: accounts)
```

- [ ] **Step 9: Build and verify**

Run: `just build-mac 2>&1 | tee .agent-tmp/build-task6.txt`
Expected: Clean build.

- [ ] **Step 10: Commit**

```bash
git add Features/Transactions/Views/TransactionDetailView.swift
git commit -m "feat: add cross-currency transfer UI with received amount and derived rate"
```

---

### Task 7: Custom Leg Instrument Picker

**Files:**
- Modify: `Features/Transactions/Views/TransactionDetailView.swift`

- [ ] **Step 1: Add `availableInstruments` parameter to `TransactionDetailView`**

Add to the view's properties:

```swift
let availableInstruments: [Instrument]
```

Add to init, defaulting to the common fiat currencies:

```swift
init(
  // ... existing params ...,
  availableInstruments: [Instrument] = CurrencyPicker.commonCurrencyCodes.map { Instrument.fiat(code: $0) },
  // ...
)
```

- [ ] **Step 2: Add Currency picker to `subTransactionSection`**

In the `subTransactionSection(index:)` method, between the Account picker and the Amount row, add:

```swift
// After Account picker, before Amount HStack:
Picker("Currency", selection: Binding(
  get: { draft.legDrafts[index].instrumentId ?? legInstrumentId(at: index) },
  set: { draft.legDrafts[index].instrumentId = $0 }
)) {
  ForEach(availableInstruments) { instrument in
    Text("\(instrument.id) — \(CurrencyPicker.currencyName(for: instrument.id))")
      .tag(instrument.id)
  }
}
.accessibilityHint("Overrides the currency derived from the account")
```

- [ ] **Step 3: Reset instrumentId when account changes**

Add to the `.onChange(of: draft.legDrafts[index].accountId)` handler:

```swift
.onChange(of: draft.legDrafts[index].accountId) { _, _ in
  draft.enforceEarmarkOnlyInvariants(at: index)
  draft.legDrafts[index].instrumentId = nil  // Reset to account's instrument
}
```

- [ ] **Step 4: Update currency label next to Amount to use instrument override**

In `subTransactionSection`, update the `Text(legInstrumentId(at: index))` to respect `instrumentId`:

```swift
Text(draft.legDrafts[index].instrumentId ?? legInstrumentId(at: index))
  .foregroundStyle(.secondary)
  .monospacedDigit()
```

- [ ] **Step 5: Pass `availableInstruments` through to `toTransaction` in `saveIfValid`**

```swift
private func saveIfValid() {
  guard
    let updated = draft.toTransaction(
      id: transaction.id, accounts: accounts, earmarks: earmarks,
      availableInstruments: availableInstruments)
  else { return }
  onUpdate(updated)
}
```

- [ ] **Step 6: Update all preview blocks and call sites to include `availableInstruments`**

Since the parameter has a default value, existing call sites don't need changes.

- [ ] **Step 7: Build and verify**

Run: `just build-mac 2>&1 | tee .agent-tmp/build-task7.txt`
Expected: Clean build.

- [ ] **Step 8: Commit**

```bash
git add Features/Transactions/Views/TransactionDetailView.swift Shared/Models/TransactionDraft.swift
git commit -m "feat: add custom leg instrument picker"
```

---

### Task 8: Update Call Sites and Fix Compilation

**Files:**
- Modify: Any files that call `TransactionDraft(from:viewingAccountId:)` or `eligibleToAccounts` — search and update.

- [ ] **Step 1: Search for all call sites**

```bash
grep -rn "TransactionDraft(from:" --include="*.swift" .
grep -rn "eligibleToAccounts" --include="*.swift" .
grep -rn "\.toTransaction(" --include="*.swift" .
```

- [ ] **Step 2: Update call sites as needed**

The `accounts` parameter on `init(from:viewingAccountId:)` defaults to empty, so existing call sites compile. But for correctness, pass `accounts` wherever available.

The `eligibleToAccounts` helper in `TransactionDraftHelpers` is now unused by the view (the view filters directly). If it's only used in tests, update the test or remove the helper.

- [ ] **Step 3: Full build**

Run: `just build-mac 2>&1 | tee .agent-tmp/build-task8.txt`
Expected: Clean build with zero warnings.

- [ ] **Step 4: Full test suite**

Run: `just test 2>&1 | tee .agent-tmp/test-task8.txt`
Expected: All tests pass.

- [ ] **Step 5: Check for warnings**

Use `mcp__xcode__XcodeListNavigatorIssues` with severity "warning" to find any warnings. Fix them.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "chore: update call sites for cross-currency transfer changes"
```

---

### Task 9: UI Review and Polish

**Files:**
- Modify: `Features/Transactions/Views/TransactionDetailView.swift` (fixes from review)

- [ ] **Step 1: Run the UI reviewer agent**

Invoke `@ui-review` on the TransactionDetailView to check compliance with STYLE_GUIDE.md and Apple HIG.

- [ ] **Step 2: Fix any issues raised**

Address each finding from the UI review.

- [ ] **Step 3: Run concurrency review**

Invoke `@concurrency-review` on modified files.

- [ ] **Step 4: Fix any concurrency issues**

- [ ] **Step 5: Final build + test**

Run: `just test 2>&1 | tee .agent-tmp/test-final.txt`
Expected: All tests pass, clean build.

- [ ] **Step 6: Commit fixes**

```bash
git add -A
git commit -m "fix: address UI and concurrency review findings"
```
