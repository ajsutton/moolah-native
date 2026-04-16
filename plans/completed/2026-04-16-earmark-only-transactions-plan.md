# Earmark-Only Transaction Support — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Support earmark-only transactions (legs with `earmarkId` set but `accountId` nil) in TransactionDraft validation, conversion, and the detail view UI.

**Architecture:** All earmark-only business logic lives in `TransactionDraft` / `LegDraft`. The view conditionally hides sections based on computed properties. Transaction creation from earmark views passes the earmark ID through.

**Tech Stack:** Swift, SwiftUI, Swift Testing

---

## File Map

- **Modify:** `Shared/Models/TransactionDraft.swift` — Add `LegDraft.isEarmarkOnly`, earmark-only invariant enforcement, update validation and `toTransaction`, add `init(earmarkId:)` support
- **Modify:** `Features/Transactions/Views/TransactionDetailView.swift` — Conditionally hide sections for earmark-only legs in both simple and custom modes
- **Modify:** `Features/Transactions/TransactionStore.swift` — Add `createDefaultEarmark` method
- **Modify:** `Features/Transactions/Views/TransactionListView.swift` — Use earmark creation when filter has earmarkId
- **Test:** `MoolahTests/Shared/TransactionDraftTests.swift` — All earmark-only tests

---

### Task 1: LegDraft.isEarmarkOnly and invariant enforcement

**Files:**
- Modify: `Shared/Models/TransactionDraft.swift:34-44`
- Test: `MoolahTests/Shared/TransactionDraftTests.swift`

- [ ] **Step 1: Write tests for `isEarmarkOnly`**

Add to `MoolahTests/Shared/TransactionDraftTests.swift` at the end of the file, before the closing brace:

```swift
// MARK: - Earmark-Only Legs

@Test func isEarmarkOnlyWithEarmarkAndNoAccount() {
  let leg = TransactionDraft.LegDraft(
    type: .income, accountId: nil, amountText: "100",
    categoryId: nil, categoryText: "", earmarkId: UUID())
  #expect(leg.isEarmarkOnly == true)
}

@Test func isEarmarkOnlyWithAccountAndEarmark() {
  let leg = TransactionDraft.LegDraft(
    type: .income, accountId: UUID(), amountText: "100",
    categoryId: nil, categoryText: "", earmarkId: UUID())
  #expect(leg.isEarmarkOnly == false)
}

@Test func isEarmarkOnlyWithAccountNoEarmark() {
  let leg = TransactionDraft.LegDraft(
    type: .expense, accountId: UUID(), amountText: "100",
    categoryId: nil, categoryText: "", earmarkId: nil)
  #expect(leg.isEarmarkOnly == false)
}

@Test func isEarmarkOnlyWithNeitherAccountNorEarmark() {
  let leg = TransactionDraft.LegDraft(
    type: .expense, accountId: nil, amountText: "100",
    categoryId: nil, categoryText: "", earmarkId: nil)
  #expect(leg.isEarmarkOnly == false)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `just test 2>&1 | tee .agent-tmp/test-earmark-1.txt`
Expected: FAIL — `isEarmarkOnly` not defined

- [ ] **Step 3: Implement `isEarmarkOnly`**

In `Shared/Models/TransactionDraft.swift`, add to the `LegDraft` struct (after line 43, the `earmarkId` property):

```swift
/// True when this leg represents an earmark-only entry (no account).
var isEarmarkOnly: Bool {
  accountId == nil && earmarkId != nil
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `just test 2>&1 | tee .agent-tmp/test-earmark-1.txt`
Expected: PASS for all four `isEarmarkOnly` tests

- [ ] **Step 5: Write tests for invariant enforcement**

Add to `MoolahTests/Shared/TransactionDraftTests.swift`:

```swift
@Test func earmarkOnlyLegEnforcesIncomeType() {
  var draft = TransactionDraft(
    payee: "", date: Date(), notes: "",
    isRepeating: false, recurPeriod: nil, recurEvery: 1,
    isCustom: false,
    legDrafts: [
      TransactionDraft.LegDraft(
        type: .expense, accountId: UUID(), amountText: "100",
        categoryId: UUID(), categoryText: "Food", earmarkId: UUID())
    ],
    relevantLegIndex: 0, viewingAccountId: nil
  )
  // Clear the account — should enforce earmark-only invariants
  draft.legDrafts[0].accountId = nil
  draft.enforceEarmarkOnlyInvariants(at: 0)
  #expect(draft.legDrafts[0].type == .income)
  #expect(draft.legDrafts[0].categoryId == nil)
  #expect(draft.legDrafts[0].categoryText == "")
}

@Test func earmarkOnlyInvariantsNoOpWhenNotEarmarkOnly() {
  var draft = TransactionDraft(
    payee: "", date: Date(), notes: "",
    isRepeating: false, recurPeriod: nil, recurEvery: 1,
    isCustom: false,
    legDrafts: [
      TransactionDraft.LegDraft(
        type: .expense, accountId: UUID(), amountText: "100",
        categoryId: UUID(), categoryText: "Food", earmarkId: nil)
    ],
    relevantLegIndex: 0, viewingAccountId: nil
  )
  let originalCategoryId = draft.legDrafts[0].categoryId
  draft.enforceEarmarkOnlyInvariants(at: 0)
  #expect(draft.legDrafts[0].type == .expense)
  #expect(draft.legDrafts[0].categoryId == originalCategoryId)
}
```

- [ ] **Step 6: Run tests to verify they fail**

Run: `just test 2>&1 | tee .agent-tmp/test-earmark-1.txt`
Expected: FAIL — `enforceEarmarkOnlyInvariants` not defined

- [ ] **Step 7: Implement `enforceEarmarkOnlyInvariants`**

In `Shared/Models/TransactionDraft.swift`, add a new extension after the `LegDraft` struct section:

```swift
// MARK: - Earmark-Only Invariants

extension TransactionDraft {
  /// Enforce earmark-only invariants on a leg: force income type, clear category.
  /// No-op if the leg is not earmark-only.
  mutating func enforceEarmarkOnlyInvariants(at index: Int) {
    guard legDrafts[index].isEarmarkOnly else { return }
    legDrafts[index].type = .income
    legDrafts[index].categoryId = nil
    legDrafts[index].categoryText = ""
  }
}
```

- [ ] **Step 8: Run tests to verify they pass**

Run: `just test 2>&1 | tee .agent-tmp/test-earmark-1.txt`
Expected: PASS

- [ ] **Step 9: Commit**

```bash
git add Shared/Models/TransactionDraft.swift MoolahTests/Shared/TransactionDraftTests.swift
git commit -m "feat: add LegDraft.isEarmarkOnly and invariant enforcement"
```

---

### Task 2: Update validation for earmark-only legs

**Files:**
- Modify: `Shared/Models/TransactionDraft.swift:345-360`
- Test: `MoolahTests/Shared/TransactionDraftTests.swift`

- [ ] **Step 1: Write tests for earmark-only validation**

Add to `MoolahTests/Shared/TransactionDraftTests.swift`:

```swift
@Test func validEarmarkOnlyLeg() {
  let draft = TransactionDraft(
    payee: "", date: Date(), notes: "",
    isRepeating: false, recurPeriod: nil, recurEvery: 1,
    isCustom: false,
    legDrafts: [
      TransactionDraft.LegDraft(
        type: .income, accountId: nil, amountText: "100",
        categoryId: nil, categoryText: "", earmarkId: UUID())
    ],
    relevantLegIndex: 0, viewingAccountId: nil
  )
  #expect(draft.isValid == true)
}

@Test func invalidLegWithNeitherAccountNorEarmark() {
  let draft = TransactionDraft(
    payee: "", date: Date(), notes: "",
    isRepeating: false, recurPeriod: nil, recurEvery: 1,
    isCustom: false,
    legDrafts: [
      TransactionDraft.LegDraft(
        type: .expense, accountId: nil, amountText: "100",
        categoryId: nil, categoryText: "", earmarkId: nil)
    ],
    relevantLegIndex: 0, viewingAccountId: nil
  )
  #expect(draft.isValid == false)
}

@Test func validCustomWithMixedAccountAndEarmarkOnlyLegs() {
  let draft = TransactionDraft(
    payee: "", date: Date(), notes: "",
    isRepeating: false, recurPeriod: nil, recurEvery: 1,
    isCustom: true,
    legDrafts: [
      TransactionDraft.LegDraft(
        type: .expense, accountId: UUID(), amountText: "50",
        categoryId: nil, categoryText: "", earmarkId: nil),
      TransactionDraft.LegDraft(
        type: .income, accountId: nil, amountText: "50",
        categoryId: nil, categoryText: "", earmarkId: UUID()),
    ],
    relevantLegIndex: 0, viewingAccountId: nil
  )
  #expect(draft.isValid == true)
}
```

- [ ] **Step 2: Run tests to verify the earmark-only valid test fails**

Run: `just test 2>&1 | tee .agent-tmp/test-earmark-2.txt`
Expected: `validEarmarkOnlyLeg` FAILS (current validation requires accountId)

- [ ] **Step 3: Update validation**

In `Shared/Models/TransactionDraft.swift`, replace the validation method (lines 345-360):

```swift
// MARK: - Validation

extension TransactionDraft {
  /// Whether the draft represents a valid, saveable transaction.
  var isValid: Bool {
    guard !legDrafts.isEmpty else { return false }
    for leg in legDrafts {
      // Each leg must have either an account or an earmark (or both)
      guard leg.accountId != nil || leg.earmarkId != nil else { return false }
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
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `just test 2>&1 | tee .agent-tmp/test-earmark-2.txt`
Expected: PASS — including existing `invalidMissingAccount` test (which has neither account nor earmark)

- [ ] **Step 5: Commit**

```bash
git add Shared/Models/TransactionDraft.swift MoolahTests/Shared/TransactionDraftTests.swift
git commit -m "feat: allow earmark-only legs in validation"
```

---

### Task 3: Update `toTransaction` for earmark-only legs

**Files:**
- Modify: `Shared/Models/TransactionDraft.swift:364-403` (the `toTransaction` method)
- Test: `MoolahTests/Shared/TransactionDraftTests.swift`

Earmark-only legs have no account to look up the instrument from. Instead, `toTransaction` needs access to `Earmarks` to resolve the instrument from the earmark's `balance.instrument`.

- [ ] **Step 1: Write tests for earmark-only `toTransaction`**

Add to `MoolahTests/Shared/TransactionDraftTests.swift`:

```swift
@Test func toTransactionEarmarkOnlyLeg() {
  let emId = UUID()
  let draft = TransactionDraft(
    payee: "", date: Date(), notes: "",
    isRepeating: false, recurPeriod: nil, recurEvery: 1,
    isCustom: false,
    legDrafts: [
      TransactionDraft.LegDraft(
        type: .income, accountId: nil, amountText: "500",
        categoryId: nil, categoryText: "", earmarkId: emId)
    ],
    relevantLegIndex: 0, viewingAccountId: nil
  )
  let earmarks = Earmarks(from: [
    Earmark(id: emId, name: "Holiday",
            balance: .zero(instrument: .defaultTestInstrument))
  ])
  let tx = draft.toTransaction(id: UUID(), accounts: Accounts(from: []), earmarks: earmarks)
  #expect(tx != nil)
  #expect(tx!.legs.count == 1)
  #expect(tx!.legs[0].accountId == nil)
  #expect(tx!.legs[0].earmarkId == emId)
  #expect(tx!.legs[0].quantity == Decimal(string: "500"))
  #expect(tx!.legs[0].type == .income)
  #expect(tx!.legs[0].instrument == .defaultTestInstrument)
}

@Test func toTransactionMixedAccountAndEarmarkOnlyLegs() {
  let emId = UUID()
  let acctId = UUID()
  let draft = TransactionDraft(
    payee: "", date: Date(), notes: "",
    isRepeating: false, recurPeriod: nil, recurEvery: 1,
    isCustom: true,
    legDrafts: [
      TransactionDraft.LegDraft(
        type: .expense, accountId: acctId, amountText: "50",
        categoryId: nil, categoryText: "", earmarkId: nil),
      TransactionDraft.LegDraft(
        type: .income, accountId: nil, amountText: "50",
        categoryId: nil, categoryText: "", earmarkId: emId),
    ],
    relevantLegIndex: 0, viewingAccountId: nil
  )
  let accounts = Accounts(from: [
    Account(id: acctId, name: "Checking", type: .bank)
  ])
  let earmarks = Earmarks(from: [
    Earmark(id: emId, name: "Holiday",
            balance: .zero(instrument: .defaultTestInstrument))
  ])
  let tx = draft.toTransaction(id: UUID(), accounts: accounts, earmarks: earmarks)
  #expect(tx != nil)
  #expect(tx!.legs.count == 2)
  #expect(tx!.legs[0].accountId == acctId)
  #expect(tx!.legs[1].accountId == nil)
  #expect(tx!.legs[1].earmarkId == emId)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `just test 2>&1 | tee .agent-tmp/test-earmark-3.txt`
Expected: FAIL — `toTransaction` doesn't accept `earmarks` parameter

- [ ] **Step 3: Update `toTransaction` to accept earmarks and handle earmark-only legs**

Replace the `toTransaction` method in `Shared/Models/TransactionDraft.swift` (lines 364-403):

```swift
// MARK: - Conversion

extension TransactionDraft {
  /// Build a `Transaction` from the draft, looking up instruments from `accounts` and `earmarks`.
  /// Returns nil when the draft is not valid.
  func toTransaction(id: UUID, accounts: Accounts, earmarks: Earmarks = Earmarks(from: [])) -> Transaction? {
    guard isValid else { return nil }

    var legs: [TransactionLeg] = []
    for legDraft in legDrafts {
      let instrument: Instrument
      if let acctId = legDraft.accountId, let account = accounts.by(id: acctId) {
        instrument = account.balance.instrument
      } else if let emId = legDraft.earmarkId, let earmark = earmarks.by(id: emId) {
        instrument = earmark.balance.instrument
      } else {
        return nil
      }

      guard
        let quantity = Self.parseDisplayText(
          legDraft.amountText, type: legDraft.type, decimals: instrument.decimals)
      else { return nil }

      legs.append(
        TransactionLeg(
          accountId: legDraft.accountId,
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

- [ ] **Step 4: Update all existing `toTransaction` call sites to pass `earmarks`**

The call site in `TransactionDetailView.swift` (line 779) needs updating:

```swift
private func saveIfValid() {
  guard let updated = draft.toTransaction(id: transaction.id, accounts: accounts, earmarks: earmarks) else { return }
  onUpdate(updated)
}
```

The existing tests use the default parameter `earmarks: Earmarks(from: [])` so they don't need changes.

- [ ] **Step 5: Run tests to verify they pass**

Run: `just test 2>&1 | tee .agent-tmp/test-earmark-3.txt`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add Shared/Models/TransactionDraft.swift Features/Transactions/Views/TransactionDetailView.swift MoolahTests/Shared/TransactionDraftTests.swift
git commit -m "feat: support earmark-only legs in toTransaction"
```

---

### Task 4: Update `canSwitchToSimple` for earmark-only transfer constraint

**Files:**
- Modify: `Shared/Models/TransactionDraft.swift:318-334`
- Test: `MoolahTests/Shared/TransactionDraftTests.swift`

Simple transfers cannot have earmark-only legs — both legs must have accounts.

- [ ] **Step 1: Write test for simple transfer with earmark-only leg**

Add to `MoolahTests/Shared/TransactionDraftTests.swift`:

```swift
@Test func cannotSwitchToSimpleWhenTransferHasEarmarkOnlyLeg() {
  let draft = TransactionDraft(
    payee: "", date: Date(), notes: "",
    isRepeating: false, recurPeriod: nil, recurEvery: 1,
    isCustom: true,
    legDrafts: [
      TransactionDraft.LegDraft(
        type: .transfer, accountId: UUID(), amountText: "100",
        categoryId: nil, categoryText: "", earmarkId: nil),
      TransactionDraft.LegDraft(
        type: .transfer, accountId: nil, amountText: "-100",
        categoryId: nil, categoryText: "", earmarkId: UUID()),
    ],
    relevantLegIndex: 0, viewingAccountId: nil
  )
  #expect(draft.canSwitchToSimple == false)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `just test 2>&1 | tee .agent-tmp/test-earmark-4.txt`
Expected: FAIL — current `canSwitchToSimple` checks `a.accountId != b.accountId` but nil != UUID passes

- [ ] **Step 3: Update `canSwitchToSimple`**

In `Shared/Models/TransactionDraft.swift`, update the `canSwitchToSimple` property. Add an account check after the existing `guard a.accountId != b.accountId` line (line 327):

Replace:
```swift
guard a.accountId != b.accountId else { return false }
```

With:
```swift
// Simple transfers require both legs to have accounts
guard a.accountId != nil && b.accountId != nil else { return false }
guard a.accountId != b.accountId else { return false }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `just test 2>&1 | tee .agent-tmp/test-earmark-4.txt`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Shared/Models/TransactionDraft.swift MoolahTests/Shared/TransactionDraftTests.swift
git commit -m "feat: prevent simple transfers with earmark-only legs"
```

---

### Task 5: Add earmark-aware draft initialization

**Files:**
- Modify: `Shared/Models/TransactionDraft.swift:191-209`
- Modify: `Features/Transactions/TransactionStore.swift:60-74`
- Modify: `Features/Transactions/Views/TransactionListView.swift:118-144`
- Test: `MoolahTests/Shared/TransactionDraftTests.swift`

- [ ] **Step 1: Write test for earmark-only draft initialization**

Add to `MoolahTests/Shared/TransactionDraftTests.swift`:

```swift
@Test func initBlankEarmarkOnlyDraft() {
  let emId = UUID()
  let draft = TransactionDraft(earmarkId: emId)
  #expect(draft.legDrafts.count == 1)
  #expect(draft.legDrafts[0].earmarkId == emId)
  #expect(draft.legDrafts[0].accountId == nil)
  #expect(draft.legDrafts[0].type == .income)
  #expect(draft.legDrafts[0].amountText == "0")
  #expect(draft.legDrafts[0].categoryId == nil)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `just test 2>&1 | tee .agent-tmp/test-earmark-5.txt`
Expected: FAIL — `init(earmarkId:)` doesn't exist

- [ ] **Step 3: Add earmark-only init to TransactionDraft**

In `Shared/Models/TransactionDraft.swift`, add a new initializer after the existing blank init (after line 209):

```swift
/// Create a blank earmark-only draft for a new earmark transaction.
init(earmarkId: UUID, viewingAccountId: UUID? = nil) {
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
        type: .income, accountId: nil, amountText: "0",
        categoryId: nil, categoryText: "", earmarkId: earmarkId)
    ],
    relevantLegIndex: 0,
    viewingAccountId: viewingAccountId
  )
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `just test 2>&1 | tee .agent-tmp/test-earmark-5.txt`
Expected: PASS

- [ ] **Step 5: Add `createDefaultEarmark` to TransactionStore**

In `Features/Transactions/TransactionStore.swift`, add after the existing `createDefault` method (after line 74):

```swift
/// Creates a default earmark-only transaction (income type, zero amount, today's date).
func createDefaultEarmark(
  earmarkId: UUID,
  instrument: Instrument
) async -> Transaction? {
  let tx = Transaction(
    date: Date(),
    payee: "",
    legs: [TransactionLeg(accountId: nil, instrument: instrument, quantity: 0, type: .income,
                          earmarkId: earmarkId)]
  )
  return await create(tx)
}
```

- [ ] **Step 6: Update `TransactionListView.createNewTransaction` for earmark context**

In `Features/Transactions/Views/TransactionListView.swift`, replace the `createNewTransaction` method (lines 118-144):

```swift
private func createNewTransaction() {
  let instrument = accounts.ordered.first?.balance.instrument ?? .AUD

  // When viewing from an earmark (no account in filter), create an earmark-only transaction
  if let earmarkId = filter.earmarkId, filter.accountId == nil {
    let placeholder = Transaction(
      date: Date(),
      payee: "",
      legs: [TransactionLeg(accountId: nil, instrument: instrument, quantity: 0, type: .income,
                            earmarkId: earmarkId)]
    )
    selectedTransaction = placeholder
    Task {
      if let created = await transactionStore.createDefaultEarmark(
        earmarkId: earmarkId,
        instrument: instrument
      ) {
        if selectedTransaction?.id == placeholder.id {
          selectedTransaction = created
        }
      }
    }
    return
  }

  let acctId = filter.accountId ?? accounts.ordered.first?.id

  // Create a placeholder for optimistic selection while the store creates it
  let placeholder: Transaction? = acctId.map { id in
    Transaction(
      date: Date(),
      payee: "",
      legs: [TransactionLeg(accountId: id, instrument: instrument, quantity: 0, type: .expense)]
    )
  }
  selectedTransaction = placeholder

  // Create the transaction in the store and update selection with server-confirmed version
  Task {
    if let created = await transactionStore.createDefault(
      accountId: filter.accountId,
      fallbackAccountId: accounts.ordered.first?.id,
      instrument: instrument
    ) {
      if selectedTransaction?.id == placeholder?.id {
        selectedTransaction = created
      }
    }
  }
}
```

- [ ] **Step 7: Run tests to verify everything passes**

Run: `just test 2>&1 | tee .agent-tmp/test-earmark-5.txt`
Expected: PASS

- [ ] **Step 8: Commit**

```bash
git add Shared/Models/TransactionDraft.swift Features/Transactions/TransactionStore.swift Features/Transactions/Views/TransactionListView.swift MoolahTests/Shared/TransactionDraftTests.swift
git commit -m "feat: add earmark-only draft init and creation flow"
```

---

### Task 6: Simple mode UI adaptation for earmark-only transactions

**Files:**
- Modify: `Features/Transactions/Views/TransactionDetailView.swift:239-265` (formContent), `295-375` (sections)

- [ ] **Step 1: Add `isSimpleEarmarkOnly` computed property to TransactionDetailView**

In `TransactionDetailView.swift`, add after the `isEditable` property (after line 91):

```swift
/// Whether the current draft is a simple earmark-only transaction.
private var isSimpleEarmarkOnly: Bool {
  !draft.isCustom && draft.relevantLeg.isEarmarkOnly
}
```

- [ ] **Step 2: Update `formContent` to conditionally show sections**

Replace the `formContent` computed property (lines 239-266):

```swift
private var formContent: some View {
  Form {
    if isSimpleEarmarkOnly {
      earmarkOnlyDetailsSection
      if showRecurrence {
        recurrenceSection
      }
      notesSection
    } else if draft.isCustom {
      typeSection.disabled(!isEditable)
      customDetailsSection
      ForEach(draft.legDrafts.indices, id: \.self) { index in
        subTransactionSection(index: index)
      }
      addSubTransactionSection
      if showRecurrence {
        recurrenceSection
      }
      notesSection
    } else {
      typeSection.disabled(!isEditable)
      detailsSection.disabled(!isEditable)
      accountSection.disabled(!isEditable)
      categorySection.disabled(!isEditable)
      if showRecurrence {
        recurrenceSection.disabled(!isEditable)
      }
      notesSection
    }
    if isScheduled {
      paySection
    }
    deleteSection
  }
}
```

- [ ] **Step 3: Add `earmarkOnlyDetailsSection`**

Add a new section to `TransactionDetailView.swift`, near the other section definitions:

```swift
private var earmarkOnlyDetailsSection: some View {
  Section {
    LabeledContent("Type") {
      Text("Earmark funds")
        .foregroundStyle(.secondary)
    }

    Picker("Earmark", selection: $draft.earmarkId) {
      ForEach(earmarks.ordered.filter { !$0.isHidden }) { earmark in
        Text(earmark.name).tag(UUID?.some(earmark.id))
      }
    }
    #if os(macOS)
      .pickerStyle(.menu)
    #endif

    HStack {
      TextField("Amount", text: amountBinding)
        .multilineTextAlignment(.trailing)
        .monospacedDigit()
        #if os(iOS)
          .keyboardType(.decimalPad)
        #endif
      Text(earmarkInstrumentId ?? "").foregroundStyle(.secondary)
        .monospacedDigit()
    }

    DatePicker("Date", selection: $draft.date, displayedComponents: .date)
  }
}

/// The instrument ID for the earmark on the relevant leg.
private var earmarkInstrumentId: String? {
  draft.relevantLeg.earmarkId
    .flatMap { earmarks.by(id: $0) }?
    .balance.instrument.id
}
```

- [ ] **Step 4: Update `isNewTransaction` for earmark-only transactions**

The current `isNewTransaction` checks payee, but earmark-only transactions don't have payees. Update to also focus the amount field for earmark-only new transactions.

In the `onAppear` modifier (line 186-189), update:

```swift
.onAppear {
  if isNewTransaction {
    focusedField = isSimpleEarmarkOnly ? .amount : .payee
  }
}
```

- [ ] **Step 5: Build and verify**

Run: `just build-mac 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 6: Check for warnings**

Use Xcode MCP: `mcp__xcode__XcodeListNavigatorIssues` with `severity: "warning"`. Fix any warnings in user code.

- [ ] **Step 7: Commit**

```bash
git add Features/Transactions/Views/TransactionDetailView.swift
git commit -m "feat: simplified detail view for earmark-only transactions"
```

---

### Task 7: Custom mode UI adaptation for earmark-only legs

**Files:**
- Modify: `Features/Transactions/Views/TransactionDetailView.swift:440-512` (subTransactionSection)

- [ ] **Step 1: Update `subTransactionSection` to adapt for earmark-only legs**

Replace the `subTransactionSection` method (lines 440-512):

```swift
@ViewBuilder
private func subTransactionSection(index: Int) -> some View {
  let isLegEarmarkOnly = draft.legDrafts[index].isEarmarkOnly
  Section("Sub-transaction \(index + 1) of \(draft.legDrafts.count)") {
    if !isLegEarmarkOnly {
      Picker("Type", selection: $draft.legDrafts[index].type) {
        Text(TransactionType.income.displayName).tag(TransactionType.income)
        Text(TransactionType.expense.displayName).tag(TransactionType.expense)
        Text(TransactionType.transfer.displayName).tag(TransactionType.transfer)
      }
    }

    Picker("Account", selection: $draft.legDrafts[index].accountId) {
      Text("None").tag(UUID?.none)
      ForEach(sortedAccounts) { account in
        Text(account.name).tag(UUID?.some(account.id))
      }
    }
    .onChange(of: draft.legDrafts[index].accountId) { _, _ in
      draft.enforceEarmarkOnlyInvariants(at: index)
    }

    HStack {
      TextField("Amount", text: $draft.legDrafts[index].amountText)
        .multilineTextAlignment(.trailing)
        .monospacedDigit()
        #if os(iOS)
          .keyboardType(.decimalPad)
        #endif
        .focused($focusedField, equals: .legAmount(index))
      Text(
        legInstrumentId(at: index)
      )
      .foregroundStyle(.secondary)
      .monospacedDigit()
    }

    if !isLegEarmarkOnly {
      LegCategoryAutocompleteField(
        legIndex: index,
        text: $draft.legDrafts[index].categoryText,
        highlightedIndex: Binding(
          get: { legCategoryHighlightedIndex[index] ?? nil },
          set: { legCategoryHighlightedIndex[index] = $0 }
        ),
        suggestionCount: legCategoryVisibleSuggestions(for: index).count,
        onTextChange: { _ in
          if legCategoryJustSelected[index] == true {
            legCategoryJustSelected[index] = false
          } else {
            showLegCategorySuggestions[index] = true
          }
        },
        onAcceptHighlighted: { acceptHighlightedLegCategory(at: index) }
      )
      .focused($legCategoryFieldFocused, equals: index)
    }

    Picker("Earmark", selection: $draft.legDrafts[index].earmarkId) {
      if !isLegEarmarkOnly {
        Text("None").tag(UUID?.none)
      }
      ForEach(earmarks.ordered.filter { !$0.isHidden }) { earmark in
        Text(earmark.name).tag(UUID?.some(earmark.id))
      }
    }
    #if os(macOS)
      .pickerStyle(.menu)
    #endif
    .onChange(of: draft.legDrafts[index].earmarkId) { _, _ in
      draft.enforceEarmarkOnlyInvariants(at: index)
    }

    if draft.legDrafts.count > 1 {
      Button(role: .destructive) {
        legPendingDeletion = index
      } label: {
        Text("Delete Sub-transaction")
          .frame(maxWidth: .infinity)
      }
      .accessibilityLabel("Delete Sub-transaction")
    }
  }
}
```

- [ ] **Step 2: Add `legInstrumentId` helper**

Add a helper method that resolves the instrument from either account or earmark:

```swift
/// Resolve the instrument ID for a leg, checking account first then earmark.
private func legInstrumentId(at index: Int) -> String {
  let leg = draft.legDrafts[index]
  if let acctId = leg.accountId, let account = accounts.by(id: acctId) {
    return account.balance.instrument.id
  }
  if let emId = leg.earmarkId, let earmark = earmarks.by(id: emId) {
    return earmark.balance.instrument.id
  }
  return ""
}
```

- [ ] **Step 3: Build and verify**

Run: `just build-mac 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 4: Check for warnings**

Use Xcode MCP: `mcp__xcode__XcodeListNavigatorIssues` with `severity: "warning"`. Fix any warnings in user code.

- [ ] **Step 5: Commit**

```bash
git add Features/Transactions/Views/TransactionDetailView.swift
git commit -m "feat: adapt custom sub-transaction section for earmark-only legs"
```

---

### Task 8: Add preview for earmark-only transaction and do final verification

**Files:**
- Modify: `Features/Transactions/Views/TransactionDetailView.swift` (add preview)

- [ ] **Step 1: Add earmark-only transaction preview**

Add a new `#Preview` at the end of `TransactionDetailView.swift`:

```swift
#Preview("Earmark-Only Transaction") {
  let earmarkId = UUID()
  NavigationStack {
    TransactionDetailView(
      transaction: Transaction(
        date: Date(),
        legs: [
          TransactionLeg(
            accountId: nil, instrument: .AUD, quantity: 500, type: .income,
            earmarkId: earmarkId)
        ]
      ),
      accounts: Accounts(from: [
        Account(name: "Checking", type: .bank),
        Account(name: "Savings", type: .bank),
      ]),
      categories: Categories(from: []),
      earmarks: Earmarks(from: [
        Earmark(id: earmarkId, name: "Income Tax FY2025"),
        Earmark(name: "Holiday Fund"),
      ]),
      transactionStore: {
        let (backend, _) = PreviewBackend.create()
        return TransactionStore(
          repository: backend.transactions,
          conversionService: backend.conversionService,
          targetInstrument: .AUD
        )
      }(),
      supportsComplexTransactions: true,
      onUpdate: { _ in },
      onDelete: { _ in }
    )
  }
}
```

- [ ] **Step 2: Run full test suite**

Run: `just test 2>&1 | tee .agent-tmp/test-earmark-final.txt`
Expected: ALL PASS

- [ ] **Step 3: Build for both platforms**

Run: `just build-mac 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 4: Check for warnings**

Use Xcode MCP: `mcp__xcode__XcodeListNavigatorIssues` with `severity: "warning"`. Fix any warnings in user code.

- [ ] **Step 5: Clean up temp files**

```bash
rm -f .agent-tmp/test-earmark-*.txt
```

- [ ] **Step 6: Commit**

```bash
git add Features/Transactions/Views/TransactionDetailView.swift
git commit -m "feat: add earmark-only transaction preview"
```
