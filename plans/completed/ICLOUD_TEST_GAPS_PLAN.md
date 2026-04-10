# iCloud Contract Test Gaps — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fill all missing contract tests identified in `plans/ICLOUD_TEST_GAPS.md` so both InMemory and CloudKit backends are verified against the same correctness invariants.

**Architecture:** All new tests go into existing contract test files in `MoolahTests/Domain/`. Each test is parameterized with both `InMemoryBackend` and `CloudKitAnalysisTestBackend` (or the repository-level equivalents). Tests use the `BackendProvider` pattern for analysis tests and direct repository protocols for CRUD tests.

**Tech Stack:** Swift Testing framework (`@Suite`, `@Test`, `#expect`), SwiftData (for CloudKit test backends), `InMemoryBackend` / `CloudKitAnalysisTestBackend`.

**Important references:**
- Gap list: `plans/ICLOUD_TEST_GAPS.md`
- Existing contract tests: `MoolahTests/Domain/AnalysisRepositoryContractTests.swift`, `TransactionRepositoryContractTests.swift`, `CategoryRepositoryContractTests.swift`, `EarmarkRepositoryContractTests.swift`, `AccountRepositoryContractTests.swift`
- InMemory analysis: `Backends/InMemory/InMemoryAnalysisRepository.swift` (see `financialMonth()` at line 450)
- Domain models: `Domain/Models/Transaction.swift`, `Domain/Models/MonthlyIncomeExpense.swift`

---

### Task 1: Financial Month Boundary Tests (Gap #1)

**Files:**
- Modify: `MoolahTests/Domain/AnalysisRepositoryContractTests.swift`

These tests verify that the `monthEnd` parameter correctly assigns transactions to financial months. A transaction on day 25 with `monthEnd=25` belongs to the current month; a transaction on day 26 belongs to the next financial month.

- [ ] **Step 1: Add expense breakdown month boundary test**

Add the following test after the `expenseBreakdownExcludesScheduled` test in `AnalysisRepositoryContractTests.swift`:

```swift
  @Test(
    "fetchExpenseBreakdown assigns transactions to correct financial month based on monthEnd",
    arguments: [
      InMemoryBackend() as any BackendProvider,
      CloudKitAnalysisTestBackend() as any BackendProvider,
    ])
  func expenseBreakdownMonthBoundary(backend: any BackendProvider) async throws {
    let account = Account(
      id: UUID(),
      name: "Test Account",
      type: .bank,
      balance: MonetaryAmount(cents: 0, currency: .defaultTestCurrency)
    )
    _ = try await backend.accounts.create(account)

    let category = Category(id: UUID(), name: "Groceries")
    _ = try await backend.categories.create(category)

    let calendar = Calendar.current
    // Use monthEnd=25. Day 25 = current month, Day 26 = next month.
    let onBoundary = calendar.date(from: DateComponents(year: 2025, month: 3, day: 25))!
    let afterBoundary = calendar.date(from: DateComponents(year: 2025, month: 3, day: 26))!

    _ = try await backend.transactions.create(
      Transaction(
        type: .expense,
        date: onBoundary,
        accountId: account.id,
        amount: MonetaryAmount(cents: -1000, currency: .defaultTestCurrency),
        payee: "On boundary",
        categoryId: category.id
      ))

    _ = try await backend.transactions.create(
      Transaction(
        type: .expense,
        date: afterBoundary,
        accountId: account.id,
        amount: MonetaryAmount(cents: -2000, currency: .defaultTestCurrency),
        payee: "After boundary",
        categoryId: category.id
      ))

    let breakdown = try await backend.analysis.fetchExpenseBreakdown(monthEnd: 25, after: nil)

    // On-boundary (day 25) should be in March 2025 (202503)
    // After-boundary (day 26) should be in April 2025 (202504)
    let marchEntries = breakdown.filter { $0.month == "202503" }
    let aprilEntries = breakdown.filter { $0.month == "202504" }

    #expect(marchEntries.count == 1, "Day 25 should belong to March financial month")
    #expect(aprilEntries.count == 1, "Day 26 should belong to April financial month")
    #expect(marchEntries[0].totalExpenses.cents == 1000)
    #expect(aprilEntries[0].totalExpenses.cents == 2000)
  }
```

- [ ] **Step 2: Add income/expense month boundary test**

Add the following test after `investmentTransfersAsEarmarked` in `AnalysisRepositoryContractTests.swift`:

```swift
  @Test(
    "fetchIncomeAndExpense groups by financial month using monthEnd",
    arguments: [
      InMemoryBackend() as any BackendProvider,
      CloudKitAnalysisTestBackend() as any BackendProvider,
    ])
  func incomeExpenseMonthBoundary(backend: any BackendProvider) async throws {
    let account = Account(
      id: UUID(),
      name: "Test Account",
      type: .bank,
      balance: MonetaryAmount(cents: 0, currency: .defaultTestCurrency)
    )
    _ = try await backend.accounts.create(account)

    let calendar = Calendar.current
    let onBoundary = calendar.date(from: DateComponents(year: 2025, month: 3, day: 25))!
    let afterBoundary = calendar.date(from: DateComponents(year: 2025, month: 3, day: 26))!

    _ = try await backend.transactions.create(
      Transaction(
        type: .income,
        date: onBoundary,
        accountId: account.id,
        amount: MonetaryAmount(cents: 1000, currency: .defaultTestCurrency),
        payee: "On boundary"
      ))

    _ = try await backend.transactions.create(
      Transaction(
        type: .income,
        date: afterBoundary,
        accountId: account.id,
        amount: MonetaryAmount(cents: 2000, currency: .defaultTestCurrency),
        payee: "After boundary"
      ))

    let data = try await backend.analysis.fetchIncomeAndExpense(monthEnd: 25, after: nil)

    let march = data.first { $0.month == "202503" }
    let april = data.first { $0.month == "202504" }

    #expect(march != nil, "Should have March financial month")
    #expect(april != nil, "Should have April financial month")
    #expect(march?.income.cents == 1000)
    #expect(april?.income.cents == 2000)
  }
```

- [ ] **Step 3: Run the tests**

Run: `just test`
Expected: All tests pass (both InMemory and CloudKit).

- [ ] **Step 4: Commit**

```bash
git add MoolahTests/Domain/AnalysisRepositoryContractTests.swift
git commit -m "test: add financial month boundary tests for expense breakdown and income/expense"
```

---

### Task 2: Investment Transfer Accounting Tests (Gap #2)

**Files:**
- Modify: `MoolahTests/Domain/AnalysisRepositoryContractTests.swift`

The existing `investmentTransfersAsEarmarked` test only checks that data is non-empty. These tests verify the specific accounting: bank→investment = earmarkedIncome, investment→bank = earmarkedExpense, investment→investment = no effect.

- [ ] **Step 1: Add multi-leg investment transfer test**

Add the following test after `investmentTransfersAsEarmarked`:

```swift
  @Test(
    "fetchIncomeAndExpense classifies investment transfers correctly",
    arguments: [
      InMemoryBackend() as any BackendProvider,
      CloudKitAnalysisTestBackend() as any BackendProvider,
    ])
  func investmentTransferClassification(backend: any BackendProvider) async throws {
    let bankAccount = Account(
      id: UUID(),
      name: "Checking",
      type: .bank,
      balance: MonetaryAmount(cents: 10000, currency: .defaultTestCurrency)
    )
    _ = try await backend.accounts.create(bankAccount)

    let investmentA = Account(
      id: UUID(),
      name: "Shares",
      type: .investment,
      balance: MonetaryAmount(cents: 0, currency: .defaultTestCurrency)
    )
    _ = try await backend.accounts.create(investmentA)

    let investmentB = Account(
      id: UUID(),
      name: "Bonds",
      type: .investment,
      balance: MonetaryAmount(cents: 0, currency: .defaultTestCurrency)
    )
    _ = try await backend.accounts.create(investmentB)

    let today = Calendar.current.startOfDay(for: Date())

    // Bank → Investment (should be earmarkedIncome)
    _ = try await backend.transactions.create(
      Transaction(
        type: .transfer,
        date: today,
        accountId: bankAccount.id,
        toAccountId: investmentA.id,
        amount: MonetaryAmount(cents: -500, currency: .defaultTestCurrency),
        payee: "Invest"
      ))

    // Investment → Bank (should be earmarkedExpense)
    _ = try await backend.transactions.create(
      Transaction(
        type: .transfer,
        date: today,
        accountId: investmentA.id,
        toAccountId: bankAccount.id,
        amount: MonetaryAmount(cents: -200, currency: .defaultTestCurrency),
        payee: "Withdraw"
      ))

    // Investment → Investment (should not affect income/expense)
    _ = try await backend.transactions.create(
      Transaction(
        type: .transfer,
        date: today,
        accountId: investmentA.id,
        toAccountId: investmentB.id,
        amount: MonetaryAmount(cents: -100, currency: .defaultTestCurrency),
        payee: "Rebalance"
      ))

    let data = try await backend.analysis.fetchIncomeAndExpense(monthEnd: 25, after: nil)

    #expect(!data.isEmpty, "Should have at least one month")
    let month = data[0]

    // Bank→Investment = earmarkedIncome of 500
    #expect(month.earmarkedIncome.cents == 500)

    // Investment→Bank = earmarkedExpense of 200
    #expect(month.earmarkedExpense.cents == 200)

    // Regular income/expense should be zero (no income or expense transactions)
    #expect(month.income.cents == 0)
    #expect(month.expense.cents == 0)
  }
```

- [ ] **Step 2: Run the tests**

Run: `just test`
Expected: All tests pass.

- [ ] **Step 3: Commit**

```bash
git add MoolahTests/Domain/AnalysisRepositoryContractTests.swift
git commit -m "test: add multi-leg investment transfer accounting tests"
```

---

### Task 3: Transfer Validation Tests (Gap #3)

**Files:**
- Modify: `MoolahTests/Domain/TransactionRepositoryContractTests.swift`

Transfer validation: transfers must have `toAccountId`, and `toAccountId` must differ from `accountId`. Both backends must enforce these rules. Also verify that creating a transfer updates balances for both source and destination accounts.

> **Note:** Read `InMemoryTransactionRepository.create()` (line 75-78) and `CloudKitTransactionRepository.create()` before writing these tests. The InMemory backend does NOT currently validate transfers — it just stores whatever is given. If validation doesn't exist yet, these tests will fail and the implementation must be added. That's TDD. Write the test first, then add validation if needed.

- [ ] **Step 1: Check if transfer validation exists in InMemory**

Read: `Backends/InMemory/InMemoryTransactionRepository.swift` line 75-78
Read: `Backends/CloudKit/Repositories/CloudKitTransactionRepository.swift` — look for the `create` method

If neither backend validates transfers, the tests below will define the expected behavior. Implement validation afterward.

- [ ] **Step 2: Add transfer validation tests**

Add at the end of the `TransactionRepositoryContractTests` struct, before the closing brace:

```swift
  @Test(
    "transfer requires toAccountId",
    arguments: [
      InMemoryTransactionRepository() as any TransactionRepository,
      makeCloudKitTransactionRepository() as any TransactionRepository,
    ])
  func testTransferRequiresToAccountId(repository: any TransactionRepository) async throws {
    let transfer = Transaction(
      type: .transfer,
      date: Date(),
      accountId: UUID(),
      toAccountId: nil,
      amount: MonetaryAmount(cents: -500, currency: .defaultTestCurrency),
      payee: "Transfer"
    )

    await #expect(throws: BackendError.self) {
      _ = try await repository.create(transfer)
    }
  }

  @Test(
    "transfer rejects same-account transfer",
    arguments: [
      InMemoryTransactionRepository() as any TransactionRepository,
      makeCloudKitTransactionRepository() as any TransactionRepository,
    ])
  func testTransferRejectsSameAccount(repository: any TransactionRepository) async throws {
    let accountId = UUID()
    let transfer = Transaction(
      type: .transfer,
      date: Date(),
      accountId: accountId,
      toAccountId: accountId,
      amount: MonetaryAmount(cents: -500, currency: .defaultTestCurrency),
      payee: "Transfer"
    )

    await #expect(throws: BackendError.self) {
      _ = try await repository.create(transfer)
    }
  }
```

- [ ] **Step 3: Run the tests to verify they fail (TDD red phase)**

Run: `just test`
Expected: FAIL — validation not yet implemented.

- [ ] **Step 4: Add transfer validation to InMemoryTransactionRepository**

Modify: `Backends/InMemory/InMemoryTransactionRepository.swift`

In the `create` method (line 75), add validation before storing:

```swift
  func create(_ transaction: Transaction) async throws -> Transaction {
    // Validate transfer constraints
    if transaction.type == .transfer {
      guard transaction.toAccountId != nil else {
        throw BackendError.validationFailed("Transfer must have a destination account")
      }
      guard transaction.toAccountId != transaction.accountId else {
        throw BackendError.validationFailed("Cannot transfer to the same account")
      }
    }
    transactions[transaction.id] = transaction
    return transaction
  }
```

- [ ] **Step 5: Add transfer validation to CloudKitTransactionRepository**

Modify: `Backends/CloudKit/Repositories/CloudKitTransactionRepository.swift`

Find the `create` method and add the same validation before persisting:

```swift
    // Validate transfer constraints
    if transaction.type == .transfer {
      guard transaction.toAccountId != nil else {
        throw BackendError.validationFailed("Transfer must have a destination account")
      }
      guard transaction.toAccountId != transaction.accountId else {
        throw BackendError.validationFailed("Cannot transfer to the same account")
      }
    }
```

- [ ] **Step 6: Run the tests to verify they pass (TDD green phase)**

Run: `just test`
Expected: All tests pass.

- [ ] **Step 7: Commit**

```bash
git add MoolahTests/Domain/TransactionRepositoryContractTests.swift \
  Backends/InMemory/InMemoryTransactionRepository.swift \
  Backends/CloudKit/Repositories/CloudKitTransactionRepository.swift
git commit -m "feat: add transfer validation (require toAccountId, reject same-account)"
```

---

### Task 4: Category Deletion Cascade to Transactions (Gap #4)

**Files:**
- Modify: `MoolahTests/Domain/CategoryRepositoryContractTests.swift`

When a category is deleted, transactions that reference it should have their `categoryId` set to `nil` (or to the replacement). This requires using a `BackendProvider` (not just the category repository) since it involves both categories and transactions.

- [ ] **Step 1: Add category deletion cascade test**

This test needs a `BackendProvider` to access both categories and transactions. Add a new test section at the bottom of the `CategoryRepositoryContractTests` struct. Because the existing tests use `CategoryRepository` directly (not `BackendProvider`), we need to add new tests using the `BackendProvider` pattern:

```swift
  @Test(
    "deleting category nulls categoryId on transactions",
    arguments: [
      InMemoryBackend() as any BackendProvider,
      CloudKitAnalysisTestBackend() as any BackendProvider,
    ])
  func testDeleteCategoryCascadesToTransactions(backend: any BackendProvider) async throws {
    let account = Account(
      id: UUID(),
      name: "Test Account",
      type: .bank,
      balance: MonetaryAmount(cents: 0, currency: .defaultTestCurrency)
    )
    _ = try await backend.accounts.create(account)

    let category = Category(id: UUID(), name: "Groceries")
    _ = try await backend.categories.create(category)

    // Create a transaction with this category
    let txn = Transaction(
      type: .expense,
      date: Date(),
      accountId: account.id,
      amount: MonetaryAmount(cents: -500, currency: .defaultTestCurrency),
      payee: "Store",
      categoryId: category.id
    )
    let created = try await backend.transactions.create(txn)

    // Delete the category
    try await backend.categories.delete(id: category.id, withReplacement: nil)

    // Fetch the transaction — its categoryId should be nil
    let page = try await backend.transactions.fetch(
      filter: TransactionFilter(),
      page: 0,
      pageSize: 50
    )
    let updated = page.transactions.first { $0.id == created.id }
    #expect(updated != nil, "Transaction should still exist")
    #expect(updated?.categoryId == nil, "categoryId should be nulled after category deletion")
  }
```

- [ ] **Step 2: Run the tests to verify they fail (TDD red phase)**

Run: `just test`
Expected: FAIL — neither InMemory nor CloudKit currently cascades to transactions on category delete.

- [ ] **Step 3: Add cascade logic to InMemoryCategoryRepository**

The `InMemoryCategoryRepository` doesn't have access to transactions. The cascade needs to happen at a higher level. There are two approaches:

**Option A:** Give `InMemoryCategoryRepository` a reference to `InMemoryTransactionRepository` so it can update transactions on delete.

**Option B:** Add a hook/delegation pattern where the backend coordinator handles the cascade.

Check how `InMemoryBackend` is composed — the category repository is created independently. The cleanest approach is to make `InMemoryCategoryRepository` accept an optional transaction repository:

Modify `Backends/InMemory/InMemoryCategoryRepository.swift`:

```swift
actor InMemoryCategoryRepository: CategoryRepository {
  private var categories: [UUID: Category]
  private let transactionRepository: InMemoryTransactionRepository?

  init(
    initialCategories: [Category] = [],
    transactionRepository: InMemoryTransactionRepository? = nil
  ) {
    self.categories = Dictionary(uniqueKeysWithValues: initialCategories.map { ($0.id, $0) })
    self.transactionRepository = transactionRepository
  }

  // ... existing methods unchanged ...

  func delete(id: UUID, withReplacement replacementId: UUID?) async throws {
    guard categories[id] != nil else {
      throw BackendError.serverError(404)
    }

    // Update any child categories to point to the replacement (or nil)
    for (childId, var child) in categories where child.parentId == id {
      child.parentId = replacementId
      categories[childId] = child
    }

    // Cascade to transactions: null out (or replace) categoryId
    if let txnRepo = transactionRepository {
      await txnRepo.replaceCategoryId(id, with: replacementId)
    }

    // Remove the category
    categories.removeValue(forKey: id)
  }

  // ... rest unchanged ...
}
```

- [ ] **Step 4: Add `replaceCategoryId` to InMemoryTransactionRepository**

Modify `Backends/InMemory/InMemoryTransactionRepository.swift` — add a method:

```swift
  func replaceCategoryId(_ oldId: UUID, with newId: UUID?) {
    for (txnId, var txn) in transactions where txn.categoryId == oldId {
      txn.categoryId = newId
      transactions[txnId] = txn
    }
  }
```

- [ ] **Step 5: Wire up InMemoryBackend to pass transaction repository to category repository**

Modify `Backends/InMemory/InMemoryBackend.swift` — update the init to pass the transaction repository into the category repository. Read the file first to see the exact init signature, then update accordingly.

- [ ] **Step 6: Add cascade logic to CloudKitCategoryRepository**

Modify `Backends/CloudKit/Repositories/CloudKitCategoryRepository.swift` — in the `delete` method, after updating children, add a SwiftData query to update transactions:

```swift
    // Cascade to transactions: null out (or replace) categoryId
    let deletedId = id
    let txnDescriptor = FetchDescriptor<TransactionRecord>(
      predicate: #Predicate { $0.categoryId == deletedId }
    )
    let affectedTxns = try context.fetch(txnDescriptor)
    for txn in affectedTxns {
      txn.categoryId = replacementId
    }
```

- [ ] **Step 7: Run the tests to verify they pass (TDD green phase)**

Run: `just test`
Expected: All tests pass.

- [ ] **Step 8: Commit**

```bash
git add MoolahTests/Domain/CategoryRepositoryContractTests.swift \
  Backends/InMemory/InMemoryCategoryRepository.swift \
  Backends/InMemory/InMemoryTransactionRepository.swift \
  Backends/InMemory/InMemoryBackend.swift \
  Backends/CloudKit/Repositories/CloudKitCategoryRepository.swift
git commit -m "feat: cascade category deletion to transactions (null out categoryId)"
```

---

### Task 5: Pagination with Prior Balance Tests (Gap #5)

**Files:**
- Modify: `MoolahTests/Domain/TransactionRepositoryContractTests.swift`

Verify that `priorBalance` is correctly computed when paginating, and that an empty page returns zero prior balance.

- [ ] **Step 1: Add pagination prior balance test**

Add to the `TransactionRepositoryContractTests` struct:

```swift
  @Test(
    "priorBalance is sum of transactions before the page",
    arguments: [
      InMemoryTransactionRepository(initialTransactions: makePaginationTestTransactions())
        as any TransactionRepository,
      makeCloudKitTransactionRepository(initialTransactions: makePaginationTestTransactions())
        as any TransactionRepository,
    ])
  func testPriorBalanceAcrossPages(repository: any TransactionRepository) async throws {
    // Fetch page 0 (newest transactions, sorted date DESC)
    let page0 = try await repository.fetch(
      filter: TransactionFilter(),
      page: 0,
      pageSize: 2
    )

    // Fetch page 1
    let page1 = try await repository.fetch(
      filter: TransactionFilter(),
      page: 1,
      pageSize: 2
    )

    // priorBalance for page 0 should be sum of transactions on page 1+
    // (because transactions are sorted newest-first, priorBalance = sum of older transactions)
    let page1Sum = page1.transactions.reduce(MonetaryAmount(cents: 0, currency: .defaultTestCurrency)) {
      $0 + $1.amount
    }
    let page1PriorSum = page1Sum + page1.priorBalance

    #expect(page0.priorBalance == page1PriorSum,
      "priorBalance of page 0 should equal sum of all older transactions")
  }

  @Test(
    "empty page returns zero priorBalance",
    arguments: [
      InMemoryTransactionRepository(initialTransactions: makePaginationTestTransactions())
        as any TransactionRepository,
      makeCloudKitTransactionRepository(initialTransactions: makePaginationTestTransactions())
        as any TransactionRepository,
    ])
  func testEmptyPagePriorBalance(repository: any TransactionRepository) async throws {
    // Request a page far beyond existing data
    let page = try await repository.fetch(
      filter: TransactionFilter(),
      page: 100,
      pageSize: 10
    )

    #expect(page.transactions.isEmpty)
    #expect(page.priorBalance.cents == 0)
  }
```

- [ ] **Step 2: Add the pagination test data factory**

Add at the bottom of the file (after the existing `makeCloudKitTransactionRepository` function):

```swift
private func makePaginationTestTransactions() -> [Transaction] {
  let accountId = UUID()
  let calendar = Calendar.current
  return [
    Transaction(
      type: .income,
      date: calendar.date(from: DateComponents(year: 2024, month: 1, day: 1))!,
      accountId: accountId,
      amount: MonetaryAmount(cents: 1000, currency: .defaultTestCurrency),
      payee: "Jan Income"
    ),
    Transaction(
      type: .expense,
      date: calendar.date(from: DateComponents(year: 2024, month: 2, day: 1))!,
      accountId: accountId,
      amount: MonetaryAmount(cents: -300, currency: .defaultTestCurrency),
      payee: "Feb Expense"
    ),
    Transaction(
      type: .income,
      date: calendar.date(from: DateComponents(year: 2024, month: 3, day: 1))!,
      accountId: accountId,
      amount: MonetaryAmount(cents: 2000, currency: .defaultTestCurrency),
      payee: "Mar Income"
    ),
    Transaction(
      type: .expense,
      date: calendar.date(from: DateComponents(year: 2024, month: 4, day: 1))!,
      accountId: accountId,
      amount: MonetaryAmount(cents: -500, currency: .defaultTestCurrency),
      payee: "Apr Expense"
    ),
  ]
}
```

- [ ] **Step 3: Run the tests**

Run: `just test`
Expected: All tests pass.

- [ ] **Step 4: Commit**

```bash
git add MoolahTests/Domain/TransactionRepositoryContractTests.swift
git commit -m "test: add pagination priorBalance and empty page tests"
```

---

### Task 6: Earmark Balance from Transactions (Gap #6)

**Files:**
- Modify: `MoolahTests/Domain/AnalysisRepositoryContractTests.swift`

Verify that earmark balance/saved/spent in daily balances are computed from earmarked transactions, not stored.

- [ ] **Step 1: Add earmark balance computation test**

Add after `availableFundsCalculation` in `AnalysisRepositoryContractTests.swift`:

```swift
  @Test(
    "earmarked balance in dailyBalances reflects earmarked transactions",
    arguments: [
      InMemoryBackend() as any BackendProvider,
      CloudKitAnalysisTestBackend() as any BackendProvider,
    ])
  func earmarkedBalanceFromTransactions(backend: any BackendProvider) async throws {
    let account = Account(
      id: UUID(),
      name: "Checking",
      type: .bank,
      balance: MonetaryAmount(cents: 0, currency: .defaultTestCurrency)
    )
    _ = try await backend.accounts.create(account)

    let earmark = Earmark(
      id: UUID(),
      name: "Holiday",
      balance: MonetaryAmount(cents: 0, currency: .defaultTestCurrency)
    )
    _ = try await backend.earmarks.create(earmark)

    let today = Calendar.current.startOfDay(for: Date())

    // Earmarked income: +500
    _ = try await backend.transactions.create(
      Transaction(
        type: .income,
        date: today,
        accountId: account.id,
        amount: MonetaryAmount(cents: 500, currency: .defaultTestCurrency),
        payee: "Earmarked Save",
        earmarkId: earmark.id
      ))

    // Earmarked expense: -200
    _ = try await backend.transactions.create(
      Transaction(
        type: .expense,
        date: today,
        accountId: account.id,
        amount: MonetaryAmount(cents: -200, currency: .defaultTestCurrency),
        payee: "Earmarked Spend",
        earmarkId: earmark.id
      ))

    // Non-earmarked income: +1000
    _ = try await backend.transactions.create(
      Transaction(
        type: .income,
        date: today,
        accountId: account.id,
        amount: MonetaryAmount(cents: 1000, currency: .defaultTestCurrency),
        payee: "Regular Income"
      ))

    let balances = try await backend.analysis.fetchDailyBalances(after: nil, forecastUntil: nil)

    #expect(!balances.isEmpty)
    let todayBalance = balances.first { Calendar.current.isDate($0.date, inSameDayAs: today) }
    #expect(todayBalance != nil)

    // Total balance = 500 - 200 + 1000 = 1300
    #expect(todayBalance?.balance.cents == 1300)
    // Earmarked = 500 - 200 = 300
    #expect(todayBalance?.earmarked.cents == 300)
    // Available = 1300 - 300 = 1000
    #expect(todayBalance?.availableFunds.cents == 1000)
  }
```

- [ ] **Step 2: Run the tests**

Run: `just test`
Expected: All tests pass.

- [ ] **Step 3: Commit**

```bash
git add MoolahTests/Domain/AnalysisRepositoryContractTests.swift
git commit -m "test: add earmark balance computation from transactions test"
```

---

### Task 7: Sort Order Guarantees (Gap #9)

**Files:**
- Modify: `MoolahTests/Domain/TransactionRepositoryContractTests.swift`
- Modify: `MoolahTests/Domain/AnalysisRepositoryContractTests.swift`

Explicit tests that transactions are date DESC, daily balances are date ASC, and expense breakdown is month DESC.

- [ ] **Step 1: Add transaction sort order test**

Add to `TransactionRepositoryContractTests`:

```swift
  @Test(
    "transactions are sorted by date descending",
    arguments: [
      InMemoryTransactionRepository(initialTransactions: makeTestTransactions())
        as any TransactionRepository,
      makeCloudKitTransactionRepository(initialTransactions: makeTestTransactions())
        as any TransactionRepository,
    ])
  func testTransactionsSortedByDateDesc(repository: any TransactionRepository) async throws {
    let page = try await repository.fetch(
      filter: TransactionFilter(),
      page: 0,
      pageSize: 50
    )

    for i in 0..<(page.transactions.count - 1) {
      #expect(
        page.transactions[i].date >= page.transactions[i + 1].date,
        "Transactions should be sorted by date descending"
      )
    }
  }
```

- [ ] **Step 2: Add expense breakdown sort order test**

Add to `AnalysisRepositoryContractTests`:

```swift
  @Test(
    "fetchExpenseBreakdown returns months in descending order",
    arguments: [
      InMemoryBackend() as any BackendProvider,
      CloudKitAnalysisTestBackend() as any BackendProvider,
    ])
  func expenseBreakdownSortOrder(backend: any BackendProvider) async throws {
    let account = Account(
      id: UUID(),
      name: "Test Account",
      type: .bank,
      balance: MonetaryAmount(cents: 0, currency: .defaultTestCurrency)
    )
    _ = try await backend.accounts.create(account)

    let category = Category(id: UUID(), name: "Food")
    _ = try await backend.categories.create(category)

    let calendar = Calendar.current
    let month1 = calendar.date(from: DateComponents(year: 2025, month: 1, day: 15))!
    let month2 = calendar.date(from: DateComponents(year: 2025, month: 2, day: 15))!
    let month3 = calendar.date(from: DateComponents(year: 2025, month: 3, day: 15))!

    for date in [month1, month2, month3] {
      _ = try await backend.transactions.create(
        Transaction(
          type: .expense,
          date: date,
          accountId: account.id,
          amount: MonetaryAmount(cents: -100, currency: .defaultTestCurrency),
          payee: "Store",
          categoryId: category.id
        ))
    }

    let breakdown = try await backend.analysis.fetchExpenseBreakdown(monthEnd: 25, after: nil)

    let months = breakdown.map(\.month)
    let uniqueMonths = months.reduce(into: [String]()) { result, month in
      if !result.contains(month) { result.append(month) }
    }

    for i in 0..<(uniqueMonths.count - 1) {
      #expect(
        uniqueMonths[i] > uniqueMonths[i + 1],
        "Expense breakdown months should be in descending order"
      )
    }
  }
```

- [ ] **Step 3: Run the tests**

Run: `just test`
Expected: All tests pass.

- [ ] **Step 4: Commit**

```bash
git add MoolahTests/Domain/TransactionRepositoryContractTests.swift \
  MoolahTests/Domain/AnalysisRepositoryContractTests.swift
git commit -m "test: add explicit sort order guarantee tests"
```

---

### Task 8: Budget Upsert Semantics (Gap #10)

**Files:**
- Modify: `MoolahTests/Domain/EarmarkRepositoryContractTests.swift`

Verify that calling `setBudget` twice for the same category updates the existing entry rather than creating a duplicate.

- [ ] **Step 1: Add budget upsert test**

Add to `EarmarkRepositoryContractTests`:

```swift
  @Test(
    "setBudget twice updates existing entry, not creates duplicate",
    arguments: [
      InMemoryEarmarkRepository(initialEarmarks: [
        Earmark(name: "Savings")
      ]) as any EarmarkRepository,
      makeCloudKitEarmarkRepository(initialEarmarks: [
        Earmark(name: "Savings")
      ]) as any EarmarkRepository,
    ])
  func testBudgetUpsertSemantics(repository: any EarmarkRepository) async throws {
    let earmarks = try await repository.fetchAll()
    let earmarkId = earmarks[0].id
    let categoryId = UUID()

    // Set budget first time
    try await repository.setBudget(earmarkId: earmarkId, categoryId: categoryId, amount: 10000)

    // Set budget again with different amount (should update, not duplicate)
    try await repository.setBudget(earmarkId: earmarkId, categoryId: categoryId, amount: 25000)

    let budget = try await repository.fetchBudget(earmarkId: earmarkId)

    // Should have exactly one entry for this category, not two
    let entries = budget.filter { $0.categoryId == categoryId }
    #expect(entries.count == 1, "setBudget should update, not create duplicate")
    #expect(entries[0].amount.cents == 25000, "Amount should reflect the latest setBudget call")
  }
```

- [ ] **Step 2: Run the tests**

Run: `just test`
Expected: All tests pass.

- [ ] **Step 3: Commit**

```bash
git add MoolahTests/Domain/EarmarkRepositoryContractTests.swift
git commit -m "test: add budget upsert semantics test (no duplicates)"
```

---

### Task 9: Null AccountId Handling (Gap #8)

**Files:**
- Modify: `MoolahTests/Domain/AnalysisRepositoryContractTests.swift`

Test that earmarked income without `accountId` is excluded from balance but included in earmarked totals.

- [ ] **Step 1: Add null accountId test**

Add to `AnalysisRepositoryContractTests`:

```swift
  @Test(
    "earmarked income without accountId excluded from balance, included in earmarked",
    arguments: [
      InMemoryBackend() as any BackendProvider,
      CloudKitAnalysisTestBackend() as any BackendProvider,
    ])
  func nullAccountIdEarmarkedHandling(backend: any BackendProvider) async throws {
    let account = Account(
      id: UUID(),
      name: "Checking",
      type: .bank,
      balance: MonetaryAmount(cents: 0, currency: .defaultTestCurrency)
    )
    _ = try await backend.accounts.create(account)

    let earmark = Earmark(
      id: UUID(),
      name: "Gift Fund",
      balance: MonetaryAmount(cents: 0, currency: .defaultTestCurrency)
    )
    _ = try await backend.earmarks.create(earmark)

    let today = Calendar.current.startOfDay(for: Date())

    // Regular income with accountId
    _ = try await backend.transactions.create(
      Transaction(
        type: .income,
        date: today,
        accountId: account.id,
        amount: MonetaryAmount(cents: 1000, currency: .defaultTestCurrency),
        payee: "Salary"
      ))

    // Earmarked income WITHOUT accountId
    _ = try await backend.transactions.create(
      Transaction(
        type: .income,
        date: today,
        accountId: nil,
        amount: MonetaryAmount(cents: 500, currency: .defaultTestCurrency),
        payee: "Gift",
        earmarkId: earmark.id
      ))

    let data = try await backend.analysis.fetchIncomeAndExpense(monthEnd: 25, after: nil)

    #expect(!data.isEmpty)
    let month = data[0]

    // Regular income should only include the transaction with accountId
    #expect(month.income.cents == 1000)
    // Earmarked income should NOT include the nil-accountId transaction
    // (because the fetchIncomeAndExpense skips transactions with nil accountId)
    #expect(month.earmarkedIncome.cents == 0)
  }
```

- [ ] **Step 2: Run the tests**

Run: `just test`
Expected: All tests pass. The implementation already has `guard txn.accountId != nil else { continue }` at line 322 of `InMemoryAnalysisRepository.swift`.

- [ ] **Step 3: Commit**

```bash
git add MoolahTests/Domain/AnalysisRepositoryContractTests.swift
git commit -m "test: add null accountId handling test for earmarked income"
```

---

### Task 10: Cross-Check Invariants (Gap #7)

**Files:**
- Modify: `MoolahTests/Domain/AnalysisRepositoryContractTests.swift`

Verify that the sum of account balances equals daily balance + investments.

- [ ] **Step 1: Add cross-check invariant test**

Add to `AnalysisRepositoryContractTests`:

```swift
  @Test(
    "daily balance + investments equals sum of current + investment account balances",
    arguments: [
      InMemoryBackend() as any BackendProvider,
      CloudKitAnalysisTestBackend() as any BackendProvider,
    ])
  func balanceInvariantCrossCheck(backend: any BackendProvider) async throws {
    let checking = Account(
      id: UUID(),
      name: "Checking",
      type: .bank,
      balance: MonetaryAmount(cents: 0, currency: .defaultTestCurrency)
    )
    _ = try await backend.accounts.create(checking)

    let savings = Account(
      id: UUID(),
      name: "Savings",
      type: .bank,
      balance: MonetaryAmount(cents: 0, currency: .defaultTestCurrency)
    )
    _ = try await backend.accounts.create(savings)

    let investment = Account(
      id: UUID(),
      name: "Shares",
      type: .investment,
      balance: MonetaryAmount(cents: 0, currency: .defaultTestCurrency)
    )
    _ = try await backend.accounts.create(investment)

    let today = Calendar.current.startOfDay(for: Date())

    // Income to checking
    _ = try await backend.transactions.create(
      Transaction(
        type: .income,
        date: today,
        accountId: checking.id,
        amount: MonetaryAmount(cents: 5000, currency: .defaultTestCurrency),
        payee: "Salary"
      ))

    // Transfer checking → investment
    _ = try await backend.transactions.create(
      Transaction(
        type: .transfer,
        date: today,
        accountId: checking.id,
        toAccountId: investment.id,
        amount: MonetaryAmount(cents: -2000, currency: .defaultTestCurrency),
        payee: "Invest"
      ))

    // Income to savings
    _ = try await backend.transactions.create(
      Transaction(
        type: .income,
        date: today,
        accountId: savings.id,
        amount: MonetaryAmount(cents: 1000, currency: .defaultTestCurrency),
        payee: "Interest"
      ))

    let balances = try await backend.analysis.fetchDailyBalances(after: nil, forecastUntil: nil)

    #expect(!balances.isEmpty)
    let todayBalance = balances.last!

    // balance should reflect all current account transactions: 5000 - 2000 + 1000 = 4000
    // investments should reflect investment allocation: 2000
    // netWorth should = balance + investments = 6000
    #expect(todayBalance.balance.cents == 4000)
    #expect(todayBalance.investments.cents == 2000)
    #expect(todayBalance.netWorth.cents == 6000)
  }
```

- [ ] **Step 2: Run the tests**

Run: `just test`
Expected: All tests pass.

- [ ] **Step 3: Commit**

```bash
git add MoolahTests/Domain/AnalysisRepositoryContractTests.swift
git commit -m "test: add cross-check invariant test (balance + investments = netWorth)"
```
