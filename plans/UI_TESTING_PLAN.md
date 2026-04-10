# UI Testing Plan

## Summary

An audit of every view and store file found **significant business logic living in views** that is currently untestable. This plan has two parts:

- **Part A (Store-level refactoring):** Extract orchestration logic from 6 views into stores, deduplicate shared utilities, fill test coverage gaps across all 5 stores. ~45 new tests.
- **Part B (XCUITest for high-risk flows):** Add a UI test target for the 5 critical user journeys that can't be fully validated at the store level. ~12 UI tests.

---

## Part A: Extract View Logic & Store-Level Tests

### Guiding Principle

Views should be thin wrappers: bind state, dispatch actions, render. Any multi-step orchestration, data transformation, or validation that can fail belongs in the store or a shared utility so it can be tested without rendering UI.

---

### A1. Extract `createNewTransaction` from TransactionListView

**Current state:** `TransactionListView.swift:71-96` contains a multi-step flow: create a default transaction, optimistically select it, call the store, then conditionally update selection with the server-confirmed version using `MainActor.run`.

**Refactor:** Add `TransactionStore.createDefault(for filter:, accounts:)` that returns the created transaction.

```swift
// TransactionStore
func createDefault(
  accountId: UUID?,
  fallbackAccountId: UUID?
) async -> Transaction? {
  let tx = Transaction(
    type: .expense,
    date: Date(),
    accountId: accountId ?? fallbackAccountId,
    amount: .zero,
    payee: ""
  )
  return await create(tx)
}
```

The view becomes:
```swift
Task {
  selectedTransaction = newTransaction  // optimistic
  if let confirmed = await transactionStore.createDefault(
    accountId: filter.accountId,
    fallbackAccountId: accounts.ordered.first?.id
  ) {
    if selectedTransaction?.id == newTransaction.id {
      selectedTransaction = confirmed
    }
  }
}
```

**Tests to write:**
1. `testCreateDefaultUsesFilterAccountId` — passes filter's accountId through
2. `testCreateDefaultFallsBackToFirstAccount` — uses fallback when filter has no accountId
3. `testCreateDefaultSetsExpenseTypeAndZeroAmount` — verifies defaults
4. `testCreateDefaultReturnsNilOnFailure` — error path

---

### A2. Extract `saveIfValid` / amount-signing from TransactionDetailView & TransactionFormView

**Current state:** Both `TransactionDetailView.swift:332-358` and `TransactionFormView.swift:273-300` contain identical amount-signing logic:
```swift
case .expense: signedCents = -abs(cents)
case .income:  signedCents =  abs(cents)
case .transfer: signedCents = -abs(cents)
```

Plus validation (parsed cents, transfer account, recurrence config) and Transaction construction from form fields.

**Refactor:** Create a `TransactionDraft` value type in `Shared/` that encapsulates form state → Transaction conversion:

```swift
struct TransactionDraft {
  var type: TransactionType
  var payee: String
  var amountText: String
  var date: Date
  var accountId: UUID?
  var toAccountId: UUID?
  var categoryId: UUID?
  var earmarkId: UUID?
  var notes: String
  var isRepeating: Bool
  var recurPeriod: RecurPeriod?
  var recurEvery: Int

  init(from transaction: Transaction) { ... }
  init(defaults accountId: UUID?) { ... }

  var parsedCents: Int? { ... }
  var isValid: Bool { ... }

  func toTransaction(id: UUID) -> Transaction? {
    guard let cents = parsedCents, isValid else { return nil }
    let signedCents: Int
    switch type {
    case .expense, .transfer: signedCents = -abs(cents)
    case .income: signedCents = abs(cents)
    }
    return Transaction(
      id: id,
      type: type,
      date: date,
      accountId: accountId,
      toAccountId: type == .transfer ? toAccountId : nil,
      amount: MonetaryAmount(cents: signedCents, currency: Currency.defaultCurrency),
      payee: payee.isEmpty ? nil : payee,
      notes: notes.isEmpty ? nil : notes,
      categoryId: categoryId,
      earmarkId: earmarkId,
      recurPeriod: isRepeating ? recurPeriod : nil,
      recurEvery: isRepeating ? recurEvery : nil
    )
  }
}
```

**Tests to write:**
1. `testExpenseAmountIsNegative` — -abs for expenses
2. `testIncomeAmountIsPositive` — +abs for income
3. `testTransferAmountIsNegative` — -abs for transfers
4. `testParsedCentsFromDecimalString` — "12.50" → 1250
5. `testParsedCentsRejectsNegative` — "-5" → nil
6. `testParsedCentsRejectsNonNumeric` — "abc" → nil
7. `testIsValidRequiresAmount` — zero/nil amount fails
8. `testIsValidRequiresTransferToAccount` — transfer without toAccountId fails
9. `testIsValidRejectsTransferToSameAccount` — toAccountId == accountId fails
10. `testIsValidRequiresRecurrenceConfig` — isRepeating with nil period fails
11. `testToTransactionClearsToAccountForNonTransfer` — toAccountId nil for expense
12. `testToTransactionClearsRecurrenceWhenNotRepeating` — recurPeriod nil
13. `testInitFromExistingTransaction` — round-trips correctly
14. `testInitDefaults` — sensible defaults for new transaction

---

### A3. Extract `debouncedSave` from TransactionDetailView

**Current state:** `TransactionDetailView.swift:318-330` manages a `Task` with 300ms sleep for debouncing, plus cancellation. This is untestable as a private view method.

**Refactor:** This is tightly coupled to SwiftUI's `onChange` modifiers. Rather than extracting the debounce mechanism, the `TransactionDraft.toTransaction()` extraction (A2) makes the *important* logic testable. The debounce itself is a thin scheduling wrapper that doesn't need unit testing — it's a candidate for XCUITest validation (Part B).

**No additional store-level tests needed** — covered by TransactionDraft tests above.

---

### A4. Extract `formatError` from TransactionListView

**Current state:** `TransactionListView.swift:56-69` maps `BackendError` cases to user-friendly strings.

**Refactor:** Move to a static method on `BackendError` or a free function in `Shared/`:

```swift
extension BackendError {
  var userMessage: String {
    switch self {
    case .serverError(let code): return "Server error (\(code)). Please try again."
    case .networkUnavailable: return "Network error. Check your connection."
    case .unauthenticated: return "Session expired. Please log in again."
    }
  }
}
```

**Tests to write:**
1. `testServerErrorMessage` — includes status code
2. `testNetworkUnavailableMessage` — connection message
3. `testUnauthenticatedMessage` — session expired message
4. `testNonBackendErrorFallback` — generic Error uses localizedDescription

---

### A5. Deduplicate `parseCurrency` (4 copies)

**Current state:** Identical `parseCurrency(_ text: String) -> Int` exists in:
- `ContentView.swift:156-162`
- `SidebarView.swift:217-223`
- `EarmarksView.swift:204-210, 309-315`
- `EarmarkDetailView.swift:243-249`

**Refactor:** Create `MonetaryAmount.parseCents(from text: String) -> Int` in `Domain/Models/MonetaryAmount.swift`:

```swift
extension MonetaryAmount {
  static func parseCents(from text: String) -> Int {
    let cleaned = text.replacingOccurrences(
      of: "[^0-9.]", with: "", options: .regularExpression)
    guard let decimal = Decimal(string: cleaned) else { return 0 }
    return Int(truncating: (decimal * 100) as NSNumber)
  }
}
```

Replace all 4 call sites.

**Tests to write:**
1. `testParseCentsWholeNumber` — "100" → 10000
2. `testParseCentsDecimal` — "12.50" → 1250
3. `testParseCentsStripsNonNumeric` — "$12.50" → 1250
4. `testParseCentsEmptyString` — "" → 0
5. `testParseCentsInvalidString` — "abc" → 0
6. `testParseCentsMultipleDecimals` — "1.2.3" → 0 (Decimal(string:) returns nil)

---

### A6. Extract `availableFunds` from SidebarView

**Current state:** `SidebarView.swift:130-135` computes available funds by subtracting positive earmark balances from the current total. This same logic should live in `AccountStore` (which already has a stub `availableFunds` property).

**Refactor:** Move computation to `AccountStore`:

```swift
// AccountStore
func availableFunds(earmarks: Earmarks) -> MonetaryAmount {
  let earmarked = earmarks.ordered
    .filter { !$0.isHidden && $0.balance.isPositive }
    .reduce(MonetaryAmount.zero) { $0 + $1.balance }
  return currentTotal - earmarked
}
```

**Tests to write:**
1. `testAvailableFundsSubtractsPositiveEarmarks`
2. `testAvailableFundsIgnoresNegativeEarmarkBalances`
3. `testAvailableFundsIgnoresHiddenEarmarks`
4. `testAvailableFundsWithNoEarmarks` — equals currentTotal

---

### A7. Extract `hasActiveFilters` from AllTransactionsView

**Current state:** `AllTransactionsView.swift:56-60` checks 6 fields.

**Refactor:** Add to `TransactionFilter`:

```swift
extension TransactionFilter {
  var hasActiveFilters: Bool {
    accountId != nil || earmarkId != nil || scheduled != nil
      || dateRange != nil || categoryIds != nil || payee != nil
  }
}
```

**Tests to write:**
1. `testEmptyFilterHasNoActiveFilters`
2. `testFilterWithAccountIdIsActive`
3. `testFilterWithDateRangeIsActive`
4. `testFilterWithCategoryIdsIsActive`
5. `testFilterWithPayeeIsActive`

---

### A8. Fill Store Test Coverage Gaps

#### CategoryStore (0 tests → full suite)

**Tests to write:**
1. `testLoadPopulatesCategories`
2. `testLoadSetsErrorOnFailure`
3. `testCreateAddsCategory`
4. `testCreateReturnsNilOnFailure`
5. `testUpdateModifiesCategory`
6. `testUpdateReturnsNilOnFailure`
7. `testDeleteRemovesCategory`
8. `testDeleteWithReplacementId`
9. `testDeleteReturnsFalseOnFailure`

#### EarmarkStore (create/update untested)

**Tests to write:**
1. `testCreateAddsEarmark`
2. `testCreateReturnsNilOnFailure`
3. `testCreateReloadsAfterSuccess`
4. `testUpdateModifiesEarmark`
5. `testUpdateReturnsNilOnFailure`

#### AuthStore (signIn untested)

**Tests to write:**
1. `testSignInTransitionsToSignedIn`
2. `testSignInClearsErrorMessage`
3. `testSignInSetsErrorOnFailure`

---

### A9. Deduplicate CreateEarmarkSheet (3 copies)

**Current state:** Nearly identical `CreateEarmarkSheet` structs exist in:
- `ContentView.swift:85-163`
- `SidebarView.swift:146-224`
- `EarmarksView.swift:138-211`

And `EditEarmarkSheet` is duplicated in:
- `EarmarkDetailView.swift:154-250`
- `EarmarksView.swift:213-316`

**Refactor:** Extract into `Features/Earmarks/Views/EarmarkFormSheet.swift` with a single `CreateEarmarkSheet` and `EditEarmarkSheet`. All three call sites use the shared component.

**Tests:** No new tests needed — this is pure deduplication. The `parseCurrency` extraction (A5) covers the logic.

---

### Part A Summary Table

| Step | Files Changed | New Tests | Priority |
|------|--------------|-----------|----------|
| A1. createNewTransaction | TransactionStore, TransactionListView | 4 | Medium |
| A2. TransactionDraft | New file, TransactionDetailView, TransactionFormView | 14 | **High** |
| A4. formatError | BackendError ext, TransactionListView | 4 | Low |
| A5. parseCurrency | MonetaryAmount ext, 4 view files | 6 | **High** |
| A6. availableFunds | AccountStore, SidebarView | 4 | Medium |
| A7. hasActiveFilters | TransactionFilter ext, AllTransactionsView | 5 | Low |
| A8. Store coverage gaps | Test files only | 17 | **High** |
| A9. Earmark sheet dedup | New shared file, 3 view files | 0 | Medium |
| **Total** | | **~54** | |

### Recommended Execution Order

1. **A5** (parseCurrency) — quick win, eliminates 4 copies of duplicated code
2. **A8** (store coverage gaps) — tests only, no production changes, fills biggest holes
3. **A2** (TransactionDraft) — highest-value extraction, eliminates duplicated validation+signing
4. **A9** (earmark sheet dedup) — mechanical, reduces code by ~200 lines
5. **A1** (createNewTransaction) — moderate value
6. **A6** (availableFunds) — small extraction
7. **A7** (hasActiveFilters) — small extraction
8. **A4** (formatError) — small extraction

---

## Part B: XCUITest for High-Risk UI Flows

### Why XCUITest

Store-level tests validate that logic is correct. XCUITest validates that **the view actually calls the right store methods and renders the results**. Use XCUITest for:

- Multi-screen workflows where the wiring between views matters
- Interactions that depend on SwiftUI rendering (debounce, sheet dismiss, selection updates)
- Flows where a regression would lose user money or data

### Infrastructure Setup

#### 1. Add UI Test Target to project.yml

```yaml
MoolahUITests_macOS:
  type: bundle.ui-testing
  platform: macOS
  sources:
    - path: MoolahUITests
  settings:
    base:
      PRODUCT_BUNDLE_IDENTIFIER: com.moolah.uitests
      CODE_SIGN_IDENTITY: "-"
      ENABLE_HARDENED_RUNTIME: NO
  dependencies:
    - target: Moolah_macOS
```

#### 2. Add Launch Argument for InMemoryBackend

In `MoolahApp.swift`, check for `--ui-testing`:

```swift
init() {
  if CommandLine.arguments.contains("--ui-testing") {
    self.backend = InMemoryBackend(/* seeded test data */)
  } else {
    self.backend = RemoteBackend(baseURL: ...)
  }
  // ... rest of init
}
```

Create a `UITestFixtures.swift` in the app target that provides deterministic seed data (fixed UUIDs, known amounts, known dates) when `--ui-testing` is active.

#### 3. Add Accessibility Identifiers

Add `.accessibilityIdentifier()` to key interactive elements:
- Sidebar navigation links: `"sidebar-account-\(id)"`, `"sidebar-upcoming"`
- Transaction rows: `"transaction-row-\(id)"`
- Pay button: `"pay-button-\(id)"`
- Amount displays: `"transaction-amount-\(id)"`
- Detail panel fields: `"detail-payee"`, `"detail-amount"`, `"detail-date"`
- Error alerts: `"error-alert"`
- Empty states: `"empty-state-upcoming"`

#### 4. Update CI

```yaml
# In ci.yml, add after existing test step:
- name: UI Tests
  run: |
    xcodebuild test \
      -scheme Moolah-macOS-UITests \
      -destination 'platform=macOS' \
      -derivedDataPath .DerivedData
```

#### 5. Add Scheme to project.yml

```yaml
Moolah-macOS-UITests:
  build:
    targets:
      Moolah_macOS: all
      MoolahUITests_macOS: [test]
  test:
    targets:
      - MoolahUITests_macOS
```

#### 6. Add just target

```
# Run UI tests on macOS
test-ui: generate
    xcodebuild test \
        -scheme Moolah-macOS-UITests \
        -destination 'platform=macOS' \
        -derivedDataPath .DerivedData \
        CODE_SIGN_IDENTITY="-" \
        ENABLE_HARDENED_RUNTIME=NO
```

---

### UI Tests to Write

#### B1. Pay Scheduled Transaction (the original bug)

**Risk:** Backend updated but UI not refreshed — user sees stale due date.

**Why XCUITest:** Store tests validate the logic is correct, but only XCUITest confirms that `UpcomingView` actually calls `payScheduledTransaction` and re-renders the list with the updated date.

```
Test: testPayRecurringTransactionShowsUpdatedDate
1. Launch app with --ui-testing (seed: monthly rent due Jan 15)
2. Tap "Upcoming" in sidebar
3. Verify "Rent" row shows "Jan 15"
4. Tap "Pay" button on the Rent row
5. Assert: "Rent" row now shows "Feb 15"
6. Assert: row is still visible (not deleted)

Test: testPayOneTimeTransactionRemovesFromList
1. Launch with seed: one-time scheduled "Annual Fee"
2. Navigate to Upcoming
3. Tap "Pay" on "Annual Fee"
4. Assert: "Annual Fee" row no longer exists
5. Assert: if no other scheduled txs, empty state appears
```

#### B2. Create Transaction & Verify in List

**Risk:** Transaction created but not appearing in list, or appearing with wrong values.

**Why XCUITest:** Tests the full Cmd+N → detail panel → auto-save → list update flow, including debounce timing.

```
Test: testCreateTransactionAppearsInList
1. Launch with seed: Checking account, no transactions
2. Navigate to Checking account
3. Tap "+" (or Cmd+N)
4. Assert: detail panel appears with empty payee focused
5. Type "Coffee Shop" in payee field
6. Type "4.50" in amount field
7. Wait 500ms (debounce)
8. Assert: "Coffee Shop" appears in the transaction list
9. Assert: amount shows "$4.50"
```

#### B3. Delete Transaction & Verify Removal

**Risk:** Transaction deleted from backend but remains visible in UI.

```
Test: testDeleteTransactionRemovesFromList
1. Launch with seed: Checking account, one transaction "Woolworths $50.23"
2. Navigate to Checking account
3. Select "Woolworths" transaction
4. Click "Delete" in detail panel
5. Confirm deletion dialog
6. Assert: "Woolworths" no longer in list
7. Assert: detail panel cleared (or empty state)

Test: testSwipeDeleteTransaction (iOS only)
1. Launch with seed data
2. Swipe left on transaction row
3. Tap delete
4. Assert: row removed from list
```

#### B4. Navigation & Account Switching

**Risk:** Switching accounts doesn't reload transactions, showing stale data from previous account.

**Why XCUITest:** Tests the `.task(id: filter)` trigger and selection clearing, which are SwiftUI-specific behaviors.

```
Test: testSwitchingAccountsLoadsCorrectTransactions
1. Launch with seed: Checking (1 tx: "Woolworths"), Savings (1 tx: "Interest")
2. Tap Checking in sidebar
3. Assert: "Woolworths" visible, "Interest" not visible
4. Tap Savings in sidebar
5. Assert: "Interest" visible, "Woolworths" not visible
6. Assert: detail panel cleared (no selection carried over)
```

#### B5. Earmark Create & Appears in Sidebar

**Risk:** Earmark created but sidebar doesn't refresh.

```
Test: testCreateEarmarkAppearsInSidebar
1. Launch with seed: no earmarks
2. Trigger new earmark (Cmd+E or toolbar button)
3. Type "Holiday Fund" for name
4. Type "5000" for savings goal
5. Tap "Create"
6. Assert: "Holiday Fund" appears in sidebar Earmarks section
```

#### B6. Category CRUD

**Risk:** Category store has zero tests currently. UI test validates the full create/edit/delete flow.

```
Test: testCreateCategoryAppearsInList
1. Navigate to Categories
2. Tap "+"
3. Enter "Groceries", select no parent
4. Tap "Create"
5. Assert: "Groceries" appears in category list

Test: testDeleteCategoryRemovesFromList
1. Launch with seed: "Groceries" category
2. Navigate to Categories
3. Select "Groceries"
4. Delete via detail panel
5. Assert: "Groceries" removed from list
```

---

### Part B Summary Table

| Test | Flow | Risk Level | Depends on Part A? |
|------|------|-----------|-------------------|
| B1a. Pay recurring scheduled tx | Upcoming → Pay → verify date | **Critical** | No (already extracted) |
| B1b. Pay one-time scheduled tx | Upcoming → Pay → verify removed | **Critical** | No |
| B2. Create transaction | Account → + → fill form → verify | **High** | No |
| B3a. Delete transaction (detail) | Account → select → delete → verify | **High** | No |
| B3b. Delete transaction (swipe) | Account → swipe → delete → verify | Medium | No |
| B4. Account switching | Sidebar → switch → verify reload | **High** | No |
| B5. Create earmark | Sidebar → + → fill → verify | Medium | No |
| B6a. Create category | Categories → + → fill → verify | Medium | No |
| B6b. Delete category | Categories → select → delete → verify | Medium | No |
| **Total** | | | **~9-12 tests** |

### XCUITest Writing Guidelines for Claude

1. **Always use accessibility identifiers**, not text matching — text changes break tests
2. **Use `app.launchArguments = ["--ui-testing"]`** to get deterministic InMemoryBackend data
3. **Use `expectation` + `waitForExistence(timeout:)`** for async operations, not `sleep`
4. **Keep tests independent** — each test launches a fresh app instance
5. **Assert on absence too** — verify deleted items are gone, not just that new items appear
6. **macOS-first** — write for macOS target (no simulator boot overhead), adapt for iOS later

---

## Execution Roadmap

| Phase | What | Estimated Tests | Prerequisite |
|-------|------|----------------|-------------|
| **1** | A5 (parseCurrency) + A8 (store test gaps) | 23 tests | None |
| **2** | A2 (TransactionDraft) + A9 (earmark dedup) | 14 tests | None |
| **3** | A1, A4, A6, A7 (smaller extractions) | 17 tests | None |
| **4** | Part B infrastructure (UI test target, fixtures, identifiers) | 0 tests | None |
| **5** | B1, B2, B3, B4 (critical UI tests) | 7 tests | Phase 4 |
| **6** | B5, B6 (medium-priority UI tests) | 4 tests | Phase 4 |
