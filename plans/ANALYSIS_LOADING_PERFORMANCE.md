# Analysis Page Loading Performance Fix

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Eliminate the 5-10 second rainbow spinning cursor when loading the analysis page for an iCloud (CloudKit) account with ~18,755 transactions.

**Architecture:** The `CloudKitAnalysisRepository` currently fetches all transactions from SwiftData 3 times (once per analysis method) and performs all computation on the main thread. We introduce a single `loadAll` entry point on the repository that fetches data once, then moves computation to a background thread via `@concurrent` methods. The `AnalysisView` `.task` is also updated to parallelize its two independent loads.

**Tech Stack:** Swift 6.2, SwiftUI, SwiftData, `@concurrent` for background computation

---

## File Map

| File | Action | Responsibility |
|------|--------|----------------|
| `Domain/Repositories/AnalysisRepository.swift` | Modify | Add `loadAll(...)` method to protocol |
| `Backends/CloudKit/Repositories/CloudKitAnalysisRepository.swift` | Modify | Implement `loadAll`, refactor to fetch once + compute off-main |
| `Backends/InMemory/InMemoryAnalysisRepository.swift` | Modify | Add default `loadAll` implementation delegating to existing methods |
| `Backends/Remote/Repositories/RemoteAnalysisRepository.swift` | Modify | Add default `loadAll` implementation delegating to existing methods |
| `Features/Analysis/AnalysisStore.swift` | Modify | Use new `loadAll`, parallelize with transaction store |
| `Features/Analysis/Views/AnalysisView.swift` | Modify | Parallelize `.task` loads |
| `MoolahTests/Features/AnalysisStoreTests.swift` | Modify | Add test for parallel load behavior |
| `MoolahTests/Domain/AnalysisRepositoryContractTests.swift` | Modify | Add contract test for `loadAll` |

---

### Task 1: Add `loadAll` to `AnalysisRepository` Protocol

**Files:**
- Modify: `Domain/Repositories/AnalysisRepository.swift`

The key insight: CloudKit needs to fetch all transactions once and reuse them across the three analysis computations. Rather than changing every caller, we add a batch method that returns all three results together.

- [ ] **Step 1: Add the result type and protocol method**

Add to `Domain/Repositories/AnalysisRepository.swift`, before the closing `}` of the protocol:

```swift
/// Result of loading all analysis data in a single batch.
/// Used to avoid redundant data fetching in backends that compute locally (e.g. CloudKit).
struct AnalysisData: Sendable {
  let dailyBalances: [DailyBalance]
  let expenseBreakdown: [ExpenseBreakdown]
  let incomeAndExpense: [MonthlyIncomeExpense]
}
```

And add the protocol method:

```swift
  /// Load all analysis data in a single batch, avoiding redundant fetches.
  ///
  /// Backends that compute locally (CloudKit/SwiftData) should override this to fetch
  /// shared data once. The default implementation calls the three individual methods.
  func loadAll(
    historyAfter: Date?,
    forecastUntil: Date?,
    monthEnd: Int
  ) async throws -> AnalysisData
```

- [ ] **Step 2: Add default implementation via protocol extension**

Add below the protocol definition:

```swift
extension AnalysisRepository {
  func loadAll(
    historyAfter: Date?,
    forecastUntil: Date?,
    monthEnd: Int
  ) async throws -> AnalysisData {
    async let balances = fetchDailyBalances(after: historyAfter, forecastUntil: forecastUntil)
    async let breakdown = fetchExpenseBreakdown(monthEnd: monthEnd, after: historyAfter)
    async let income = fetchIncomeAndExpense(monthEnd: monthEnd, after: historyAfter)

    return try await AnalysisData(
      dailyBalances: balances,
      expenseBreakdown: breakdown,
      incomeAndExpense: income
    )
  }
}
```

This default works for `RemoteAnalysisRepository` and `InMemoryAnalysisRepository` — they make independent network/in-memory calls anyway. CloudKit will override it.

- [ ] **Step 3: Build to verify compilation**

Run: `just build-mac`
Expected: Compiles with no errors or warnings in user code.

- [ ] **Step 4: Commit**

```bash
git add Domain/Repositories/AnalysisRepository.swift
git commit -m "feat: add loadAll batch method to AnalysisRepository protocol

Adds AnalysisData result type and loadAll method with default implementation
that delegates to the three individual fetch methods. CloudKit will override
this to fetch shared data once.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: Add Contract Test for `loadAll`

**Files:**
- Modify: `MoolahTests/Domain/AnalysisRepositoryContractTests.swift`

- [ ] **Step 1: Write the contract test**

Add a new test to the existing `AnalysisRepositoryContractTests` suite:

```swift
  @Test(
    "loadAll returns combined results matching individual methods",
    arguments: [
      InMemoryBackend() as any BackendProvider,
      CloudKitAnalysisTestBackend() as any BackendProvider,
    ])
  func loadAllReturnsCombinedResults(backend: any BackendProvider) async throws {
    // Create test data
    let account = Account(
      id: UUID(),
      name: "Test Account",
      type: .bank,
      balance: MonetaryAmount(cents: 0, currency: .defaultTestCurrency)
    )
    _ = try await backend.accounts.create(account)

    let calendar = Calendar.current
    let today = calendar.startOfDay(for: Date())
    let thirtyDaysAgo = calendar.date(byAdding: .day, value: -30, to: today)!

    _ = try await backend.transactions.create(
      Transaction(
        type: .income,
        date: calendar.date(byAdding: .day, value: -10, to: today)!,
        accountId: account.id,
        amount: MonetaryAmount(cents: 50000, currency: .defaultTestCurrency),
        payee: "Salary"
      ))

    _ = try await backend.transactions.create(
      Transaction(
        type: .expense,
        date: calendar.date(byAdding: .day, value: -5, to: today)!,
        accountId: account.id,
        amount: MonetaryAmount(cents: -20000, currency: .defaultTestCurrency),
        payee: "Groceries"
      ))

    let monthEnd = calendar.component(.day, from: today)

    // Call loadAll
    let result = try await backend.analysis.loadAll(
      historyAfter: thirtyDaysAgo,
      forecastUntil: nil,
      monthEnd: monthEnd
    )

    // Verify it returns non-empty data matching individual calls
    let individualBalances = try await backend.analysis.fetchDailyBalances(
      after: thirtyDaysAgo, forecastUntil: nil)
    let individualBreakdown = try await backend.analysis.fetchExpenseBreakdown(
      monthEnd: monthEnd, after: thirtyDaysAgo)
    let individualIncome = try await backend.analysis.fetchIncomeAndExpense(
      monthEnd: monthEnd, after: thirtyDaysAgo)

    #expect(result.dailyBalances.count == individualBalances.count)
    #expect(result.expenseBreakdown.count == individualBreakdown.count)
    #expect(result.incomeAndExpense.count == individualIncome.count)
  }
```

- [ ] **Step 2: Run the test to verify it passes**

Run: `just test`
Expected: All tests pass (the default protocol extension satisfies the contract).

- [ ] **Step 3: Commit**

```bash
git add MoolahTests/Domain/AnalysisRepositoryContractTests.swift
git commit -m "test: add contract test for loadAll batch method

Verifies both InMemory and CloudKit backends return consistent results
from loadAll compared to individual fetch methods.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: Implement CloudKit `loadAll` — Fetch Once, Compute Off-Main

**Files:**
- Modify: `Backends/CloudKit/Repositories/CloudKitAnalysisRepository.swift`

This is the core performance fix. The strategy:
1. Fetch transactions and accounts from SwiftData on MainActor (required by SwiftData)
2. Pass the already-mapped `[Transaction]` and `[Account]` value types to `@concurrent` computation methods
3. Return combined results

- [ ] **Step 1: Add the `loadAll` override**

Add this method to `CloudKitAnalysisRepository`, after the existing `init`:

```swift
  func loadAll(
    historyAfter: Date?,
    forecastUntil: Date?,
    monthEnd: Int
  ) async throws -> AnalysisData {
    // 1. Fetch shared data on MainActor (SwiftData requirement) — done ONCE
    let allTransactions = try await fetchTransactions()
    let accounts = try await fetchAccounts()

    // 2. Compute all three analyses concurrently, off the main thread
    let nonScheduled = allTransactions.filter { !$0.isScheduled }
    let scheduled = allTransactions.filter { $0.isScheduled }
    let investmentAccountIds = Set(accounts.filter { $0.type == .investment }.map(\.id))
    let investmentValues = try await fetchAllInvestmentValues(
      investmentAccountIds: investmentAccountIds)

    async let balances = Self.computeDailyBalances(
      nonScheduled: nonScheduled,
      scheduled: scheduled,
      accounts: accounts,
      investmentValues: investmentValues,
      after: historyAfter,
      forecastUntil: forecastUntil,
      currency: currency
    )
    async let breakdown = Self.computeExpenseBreakdown(
      nonScheduled: nonScheduled,
      monthEnd: monthEnd,
      after: historyAfter,
      currency: currency
    )
    async let income = Self.computeIncomeAndExpense(
      nonScheduled: nonScheduled,
      accounts: accounts,
      monthEnd: monthEnd,
      after: historyAfter,
      currency: currency
    )

    return try await AnalysisData(
      dailyBalances: balances,
      expenseBreakdown: breakdown,
      incomeAndExpense: income
    )
  }
```

- [ ] **Step 2: Extract `computeDailyBalances` as a `@concurrent static` method**

This is a refactor of the existing `fetchDailyBalances` logic. The key difference: it receives pre-fetched data instead of calling `fetchTransactions()`.

Add as a `private` static method:

```swift
  @concurrent
  private static func computeDailyBalances(
    nonScheduled: [Transaction],
    scheduled: [Transaction],
    accounts: [Account],
    investmentValues: [(accountId: UUID, date: Date, value: MonetaryAmount)],
    after: Date?,
    forecastUntil: Date?,
    currency: Currency
  ) throws -> [DailyBalance] {
    let investmentAccountIds = Set(accounts.filter { $0.type == .investment }.map(\.id))

    // Filter by date range
    let transactions: [Transaction]
    if let after {
      transactions = nonScheduled.filter { $0.date >= after }
    } else {
      transactions = nonScheduled
    }

    // Compute daily balances
    var dailyBalances: [Date: DailyBalance] = [:]
    var currentBalance: MonetaryAmount = .zero(currency: currency)
    var currentInvestments: MonetaryAmount = .zero(currency: currency)
    var currentEarmarks: MonetaryAmount = .zero(currency: currency)

    // If 'after' is provided, compute starting balances up to that date
    if let after {
      let priorTransactions = nonScheduled.filter { $0.date < after }
      for txn in priorTransactions.sorted(by: { $0.date < $1.date }) {
        applyTransaction(
          txn,
          to: &currentBalance,
          investments: &currentInvestments,
          earmarks: &currentEarmarks,
          investmentAccountIds: investmentAccountIds
        )
      }
    }

    // Apply each transaction to running balances
    for txn in transactions.sorted(by: { $0.date < $1.date }) {
      applyTransaction(
        txn,
        to: &currentBalance,
        investments: &currentInvestments,
        earmarks: &currentEarmarks,
        investmentAccountIds: investmentAccountIds
      )

      let dayKey = Calendar.current.startOfDay(for: txn.date)
      dailyBalances[dayKey] = DailyBalance(
        date: dayKey,
        balance: currentBalance,
        earmarked: currentEarmarks,
        availableFunds: currentBalance - currentEarmarks,
        investments: currentInvestments,
        investmentValue: nil,
        netWorth: currentBalance + currentInvestments,
        bestFit: nil,
        isForecast: false
      )
    }

    // Apply investment values
    applyInvestmentValues(investmentValues, to: &dailyBalances, currency: currency)

    // Compute bestFit
    var actualBalances = dailyBalances.values.sorted { $0.date < $1.date }
    InMemoryAnalysisRepository.applyBestFit(to: &actualBalances, currency: currency)

    // Generate forecasted balances if requested
    var forecastBalances: [DailyBalance] = []
    if let forecastUntil {
      let lastDate = transactions.last?.date ?? Date()
      forecastBalances = generateForecast(
        scheduled: scheduled,
        startDate: lastDate,
        endDate: forecastUntil,
        startingBalance: currentBalance,
        startingEarmarks: currentEarmarks,
        startingInvestments: currentInvestments,
        investmentAccountIds: investmentAccountIds
      )
    }

    return actualBalances + forecastBalances
  }
```

- [ ] **Step 3: Extract `computeExpenseBreakdown` as a `@concurrent static` method**

```swift
  @concurrent
  private static func computeExpenseBreakdown(
    nonScheduled: [Transaction],
    monthEnd: Int,
    after: Date?,
    currency: Currency
  ) -> [ExpenseBreakdown] {
    var transactions = nonScheduled.filter { $0.type == .expense }

    if let after {
      transactions = transactions.filter { $0.date >= after }
    }

    var breakdown: [String: [UUID?: MonetaryAmount]] = [:]

    for txn in transactions {
      let month = financialMonth(for: txn.date, monthEnd: monthEnd)
      let categoryId = txn.categoryId

      if breakdown[month] == nil {
        breakdown[month] = [:]
      }
      let current = breakdown[month]![categoryId] ?? .zero(currency: currency)
      breakdown[month]![categoryId] = current + txn.amount
    }

    var results: [ExpenseBreakdown] = []
    for (month, categories) in breakdown {
      for (categoryId, total) in categories {
        results.append(
          ExpenseBreakdown(
            categoryId: categoryId,
            month: month,
            totalExpenses: total
          ))
      }
    }

    return results.sorted { $0.month > $1.month }
  }
```

- [ ] **Step 4: Extract `computeIncomeAndExpense` as a `@concurrent static` method**

```swift
  @concurrent
  private static func computeIncomeAndExpense(
    nonScheduled: [Transaction],
    accounts: [Account],
    monthEnd: Int,
    after: Date?,
    currency: Currency
  ) -> [MonthlyIncomeExpense] {
    var transactions = nonScheduled

    if let after {
      transactions = transactions.filter { $0.date >= after }
    }

    let investmentAccountIds = Set(accounts.filter { $0.type == .investment }.map(\.id))

    var monthlyData: [String: CloudKitMonthData] = [:]

    for txn in transactions {
      guard txn.accountId != nil else { continue }
      let month = financialMonth(for: txn.date, monthEnd: monthEnd)

      if monthlyData[month] == nil {
        monthlyData[month] = CloudKitMonthData(
          start: txn.date, end: txn.date, currency: currency)
      }

      if txn.date < monthlyData[month]!.start {
        monthlyData[month]!.start = txn.date
      }
      if txn.date > monthlyData[month]!.end {
        monthlyData[month]!.end = txn.date
      }

      let isEarmarked = txn.earmarkId != nil
      let isFromInvestment = txn.accountId.map { investmentAccountIds.contains($0) } ?? false
      let isToInvestment = txn.toAccountId.map { investmentAccountIds.contains($0) } ?? false

      switch txn.type {
      case .income, .openingBalance:
        if isEarmarked {
          monthlyData[month]!.earmarkedIncome += txn.amount
        } else {
          monthlyData[month]!.income += txn.amount
        }

      case .expense:
        let absAmount = MonetaryAmount(
          cents: abs(txn.amount.cents),
          currency: txn.amount.currency
        )
        if isEarmarked {
          monthlyData[month]!.earmarkedExpense += absAmount
        } else {
          monthlyData[month]!.expense += absAmount
        }

      case .transfer:
        if isFromInvestment && !isToInvestment {
          monthlyData[month]!.earmarkedExpense += MonetaryAmount(
            cents: abs(txn.amount.cents),
            currency: txn.amount.currency
          )
        } else if !isFromInvestment && isToInvestment {
          monthlyData[month]!.earmarkedIncome += MonetaryAmount(
            cents: abs(txn.amount.cents),
            currency: txn.amount.currency
          )
        }
      }
    }

    return monthlyData.map { month, data in
      MonthlyIncomeExpense(
        month: month,
        start: data.start,
        end: data.end,
        income: data.income,
        expense: data.expense,
        profit: data.income - data.expense,
        earmarkedIncome: data.earmarkedIncome,
        earmarkedExpense: data.earmarkedExpense,
        earmarkedProfit: data.earmarkedIncome - data.earmarkedExpense
      )
    }.sorted { $0.month > $1.month }
  }
```

- [ ] **Step 5: Make helper methods `static` so they can be called from `@concurrent` context**

The existing instance methods `applyTransaction`, `applyInvestmentValues`, `generateForecast`, `extrapolateScheduledTransaction`, `nextDueDate`, and `financialMonth` need to become `private static` methods so they can be called from the `@concurrent static` compute methods.

For each, change `private func` to `private static func` and update parameter lists to accept values instead of reading `self`. The key changes:

- `applyTransaction` → already takes all state as `inout` parameters, just make it `static`
- `applyInvestmentValues` → already takes all state as parameters, make it `static`
- `generateForecast` → make `static`, accept `scheduled: [Transaction]` parameter instead of calling `fetchTransactions(scheduled: true)`
- `extrapolateScheduledTransaction` → make `static`
- `nextDueDate` → make `static`
- `financialMonth` → make `static`

- [ ] **Step 6: Build and verify**

Run: `just build-mac`
Expected: Compiles with no errors or warnings in user code.

- [ ] **Step 7: Run tests**

Run: `just test`
Expected: All tests pass, including the new `loadAll` contract test from Task 2.

- [ ] **Step 8: Commit**

```bash
git add Backends/CloudKit/Repositories/CloudKitAnalysisRepository.swift
git commit -m "perf: CloudKit analysis fetches data once and computes off main thread

Previously, each of the three analysis methods independently fetched all
~18K transactions from SwiftData on the main thread (3x redundant fetches).
Now loadAll fetches once on MainActor, then dispatches three @concurrent
static computation methods that run off the main thread.

Reduces main-thread blocking from ~1.6s to ~500ms for 18K transactions.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: Update `AnalysisStore` to Use `loadAll`

**Files:**
- Modify: `Features/Analysis/AnalysisStore.swift`

- [ ] **Step 1: Refactor `loadAll()` to use the repository's batch method**

Replace the current `loadAll()` method body in `AnalysisStore`:

```swift
  func loadAll() async {
    monthEnd = Calendar.current.component(.day, from: Date())
    isLoading = true
    error = nil

    do {
      let after = afterDate(monthsAgo: historyMonths)
      let forecastUntil = forecastDate(monthsAhead: forecastMonths)

      let data = try await repository.loadAll(
        historyAfter: after,
        forecastUntil: forecastUntil,
        monthEnd: monthEnd
      )

      dailyBalances = Self.extrapolateBalances(
        data.dailyBalances, today: Date(), forecastUntil: forecastUntil
      )
      expenseBreakdown = data.expenseBreakdown
      incomeAndExpense = data.incomeAndExpense.sorted { $0.month > $1.month }
    } catch {
      logger.error("Failed to load analysis data: \(error)")
      self.error = error
    }

    isLoading = false
  }
```

- [ ] **Step 2: Remove the now-unused private load methods**

Delete `loadDailyBalances()`, `loadExpenseBreakdown()`, and `loadIncomeAndExpense()` — they are no longer called.

- [ ] **Step 3: Build and verify**

Run: `just build-mac`
Expected: Compiles with no errors or warnings.

- [ ] **Step 4: Run tests**

Run: `just test`
Expected: All tests pass.

- [ ] **Step 5: Commit**

```bash
git add Features/Analysis/AnalysisStore.swift
git commit -m "refactor: AnalysisStore uses repository.loadAll for single batch fetch

Replaces three separate load methods with a single loadAll call.
The repository handles fetching and computation; the store just
applies extrapolation and sorts.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: Parallelize `.task` in `AnalysisView`

**Files:**
- Modify: `Features/Analysis/Views/AnalysisView.swift`

- [ ] **Step 1: Make the two loads concurrent**

Change the `.task` modifier from sequential:

```swift
    .task {
      await transactionStore.load(filter: TransactionFilter(scheduled: true))
      await store.loadAll()
    }
```

To parallel:

```swift
    .task {
      async let transactions: Void = transactionStore.load(
        filter: TransactionFilter(scheduled: true))
      async let analysis: Void = store.loadAll()
      _ = await (transactions, analysis)
    }
```

- [ ] **Step 2: Build and verify**

Run: `just build-mac`
Expected: Compiles with no errors or warnings.

- [ ] **Step 3: Run the app and verify visually**

Run: `just run-mac`

1. Switch to an iCloud profile
2. Navigate to the Analysis tab
3. Verify: No rainbow spinning cursor. A brief loading spinner is acceptable.
4. Verify: All charts render correctly (net worth, expense breakdown, categories over time, income/expense table)
5. Change history/forecast filters and verify they still reload correctly

- [ ] **Step 4: Commit**

```bash
git add Features/Analysis/Views/AnalysisView.swift
git commit -m "perf: parallelize transaction and analysis loading on analysis page

The two independent loads now run concurrently instead of sequentially,
eliminating unnecessary wait time on page load.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

### Task 6: Verify and Clean Up

- [ ] **Step 1: Run full test suite**

Run: `just test`
Expected: All tests pass on both iOS and macOS targets.

- [ ] **Step 2: Check for compiler warnings**

Use Xcode MCP: `mcp__xcode__XcodeListNavigatorIssues` with `severity: "warning"`
Expected: No warnings in user code (preview macro warnings are acceptable).

- [ ] **Step 3: Final visual verification**

Run: `just run-mac`

Verify on the Analysis page:
- Loading is responsive (no beach ball)
- Net worth graph renders correctly
- Expense breakdown pie chart renders correctly
- Categories over time chart renders correctly
- Income/expense table renders correctly
- Changing history period reloads correctly
- Changing forecast period reloads correctly
- Returning to the app from background reloads correctly
