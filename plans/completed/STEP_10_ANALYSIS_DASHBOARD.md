# Step 10 — Analysis Dashboard

**Date:** 2026-04-08

## Executive Summary

The Analysis Dashboard is Moolah's primary data visualization and financial health monitoring screen. It provides four key insights:

1. **Net Worth Graph** — Daily balances over time (actual + forecast) showing current funds, investments, earmarked funds, and net worth
2. **Expense Breakdown** — Pie chart showing expenses by category with drill-down capability
3. **Income & Expense Table** — Monthly summary of income, expenses, and cumulative savings
4. **Upcoming Transactions Widget** — Short-term (14-day) scheduled transactions preview

This step implements all necessary domain models, repository protocols, backend logic, and SwiftUI views to deliver a fully functional, interactive dashboard that matches the feature set of the moolah web app.

---

## 1. Overview

### Purpose

The Analysis Dashboard answers critical financial questions:
- **Where am I?** Current net worth, available funds, earmarked funds
- **Where am I going?** Forecasted balance based on scheduled transactions
- **Where does my money go?** Category-level expense breakdown
- **Am I saving or losing money?** Month-by-month profit/loss trends
- **What's coming up?** Near-term scheduled transactions requiring action

### Server API Endpoints

The moolah-server exposes three analysis endpoints:

| Endpoint | Parameters | Response |
|----------|-----------|----------|
| `GET /api/analysis/dailyBalances/` | `after: Date?`, `forecastUntil: Date?` | `{ dailyBalances: [DailyBalance], scheduledBalances: [DailyBalance]? }` |
| `GET /api/analysis/expenseBreakdown/` | `monthEnd: Int`, `after: Date?` | `[{ categoryId: UUID, month: String, totalExpenses: Int }]` |
| `GET /api/analysis/incomeAndExpense/` | `monthEnd: Int`, `after: Date?` | `{ incomeAndExpense: [MonthlyIncomeExpense] }` |

**Note:** `monthEnd` is the user's configured "end of month" day (e.g., 25 for the 25th). The server uses this to group transactions into financial months (e.g., Jan 26 – Feb 25 is "February").

---

## 2. Domain Models

All domain models are plain Swift structs in `Domain/Models/`. They must be `Sendable`, `Codable`, and have no dependencies on backend-specific types (no `URLSession`, `SwiftData`, etc.).

### 2.1 DailyBalance

Represents a single day's financial snapshot (actual or forecasted).

**File:** `Domain/Models/DailyBalance.swift`

```swift
import Foundation

/// A single day's financial snapshot, either historical (isForecast: false)
/// or projected from scheduled transactions (isForecast: true).
struct DailyBalance: Sendable, Codable, Identifiable, Hashable {
  var id: String { date.ISO8601Format() }  // For SwiftUI List/ForEach

  /// The date of this balance snapshot (YYYY-MM-DD midnight UTC)
  let date: Date

  /// Total balance in non-investment accounts (current funds)
  let balance: MonetaryAmount

  /// Amount allocated to earmarks (subset of balance)
  let earmarked: MonetaryAmount

  /// Available funds = balance - earmarked
  let availableFunds: MonetaryAmount

  /// Total amount in investment accounts (contributed amount, not market value)
  let investments: MonetaryAmount

  /// Market value of investments (if available from investment tracking)
  let investmentValue: MonetaryAmount?

  /// Net worth = balance + (investmentValue ?? investments)
  let netWorth: MonetaryAmount

  /// Linear regression best-fit value (for trend line visualization)
  let bestFit: MonetaryAmount?

  /// True if this balance was projected from scheduled transactions
  /// (only present in scheduledBalances array from dailyBalances endpoint)
  let isForecast: Bool
}

extension DailyBalance {
  /// Convenience initializer for testing (sets isForecast: false, no bestFit)
  init(
    date: Date,
    balance: MonetaryAmount,
    earmarked: MonetaryAmount = .zero,
    investments: MonetaryAmount = .zero,
    investmentValue: MonetaryAmount? = nil
  ) {
    self.date = date
    self.balance = balance
    self.earmarked = earmarked
    self.availableFunds = balance - earmarked
    self.investments = investments
    self.investmentValue = investmentValue
    self.netWorth = balance + (investmentValue ?? investments)
    self.bestFit = nil
    self.isForecast = false
  }
}
```

**Validation Rules:**
- `balance`, `earmarked`, `investments`, `netWorth` can be negative (debt/overdraft)
- `availableFunds = balance - earmarked` (server-computed, enforced in DTO mapping)
- `netWorth = balance + (investmentValue ?? investments)` (server-computed)
- `investmentValue` is optional (only present if user tracks investment market values)
- `bestFit` is optional (only computed by server when there are ≥2 data points)

### 2.2 ExpenseBreakdown

Represents total expenses for a single category in a single month.

**File:** `Domain/Models/ExpenseBreakdown.swift`

```swift
import Foundation

/// Aggregated expenses for one category in one financial month.
struct ExpenseBreakdown: Sendable, Codable, Identifiable, Hashable {
  var id: String { "\(categoryId)-\(month)" }

  /// The category (nil means uncategorized expenses)
  let categoryId: UUID?

  /// Financial month in YYYYMM format (e.g., "202604" for April 2026 financial month)
  /// Grouped by user's monthEnd preference (e.g., Jan 26 – Feb 25 = "202602")
  let month: String

  /// Total expenses in cents (always positive, sum of transaction amounts)
  let totalExpenses: MonetaryAmount
}

extension ExpenseBreakdown {
  /// Parse month string to Date (first day of calendar month)
  var monthDate: Date? {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyyMM"
    formatter.timeZone = TimeZone(identifier: "UTC")
    return formatter.date(from: month)
  }
}
```

**Validation Rules:**
- `totalExpenses` must be ≥ 0 (server guarantees this via `SUM(amount)` of expense transactions)
- `month` format: exactly 6 digits `YYYYMM`
- `categoryId` may be nil (uncategorized expenses)

**Computation (InMemoryBackend):**
1. Filter transactions: `type == .expense`, `recurPeriod == nil`, `date` in range
2. Group by `categoryId` and financial month (based on `monthEnd` parameter)
3. Sum `amount` for each group

### 2.3 MonthlyIncomeExpense

Represents income, expenses, and savings for a single financial month.

**File:** `Domain/Models/MonthlyIncomeExpense.swift`

```swift
import Foundation

/// Aggregated income and expenses for one financial month.
struct MonthlyIncomeExpense: Sendable, Codable, Identifiable, Hashable {
  var id: String { month }

  /// Financial month in YYYYMM format (e.g., "202604")
  let month: String

  /// First transaction date in this financial month (for display)
  let start: Date

  /// Last transaction date in this financial month (for display)
  let end: Date

  // --- Non-earmarked income & expenses ---

  /// Total income (excluding earmarked income) in cents
  let income: MonetaryAmount

  /// Total expenses (excluding earmarked expenses) in cents
  let expense: MonetaryAmount

  /// Profit = income - expense (can be negative)
  let profit: MonetaryAmount

  // --- Earmarked income & expenses ---

  /// Income allocated to earmarks (including investment contributions)
  let earmarkedIncome: MonetaryAmount

  /// Expenses paid from earmarks (including investment withdrawals)
  let earmarkedExpense: MonetaryAmount

  /// Earmarked profit = earmarkedIncome - earmarkedExpense
  let earmarkedProfit: MonetaryAmount
}

extension MonthlyIncomeExpense {
  /// Compute total income (including earmarks)
  var totalIncome: MonetaryAmount {
    income + earmarkedIncome
  }

  /// Compute total expenses (including earmarks)
  var totalExpense: MonetaryAmount {
    expense + earmarkedExpense
  }

  /// Compute total profit (including earmarks)
  var totalProfit: MonetaryAmount {
    profit + earmarkedProfit
  }
}
```

**Validation Rules:**
- `income`, `expense` ≥ 0 (sums of amounts, always positive)
- `profit` can be negative (loss)
- `earmarkedIncome`, `earmarkedExpense` ≥ 0
- `earmarkedProfit` can be negative
- `start <= end` (server guarantees via `MIN(date)`, `MAX(date)`)

**Investment Handling:**
- Transfers *to* investment accounts count as `earmarkedIncome` (money leaving available funds)
- Transfers *from* investment accounts count as `earmarkedExpense` (money returning to available funds)
- Server SQL:
  ```sql
  SUM(IF(t.type = 'transfer' AND af.type = 'investment' AND amount < 0, amount, 0)) AS earmarkedIncome
  SUM(IF(t.type = 'transfer' AND at.type = 'investment' AND amount < 0, -amount, 0)) AS earmarkedExpense
  ```

---

## 3. Repository Protocol

### 3.1 AnalysisRepository

**File:** `Domain/Repositories/AnalysisRepository.swift`

```swift
import Foundation

/// Repository for fetching aggregated financial analysis data.
protocol AnalysisRepository: Sendable {
  /// Fetch daily balance snapshots for a date range, optionally including forecasts.
  ///
  /// - Parameters:
  ///   - after: Start date (inclusive). Nil = all history.
  ///   - forecastUntil: End date for forecast (inclusive). Nil = no forecast.
  /// - Returns: Array of DailyBalance (actual + forecast if requested).
  /// - Throws: BackendError on network/auth failure.
  func fetchDailyBalances(
    after: Date?,
    forecastUntil: Date?
  ) async throws -> [DailyBalance]

  /// Fetch expense breakdown by category for a date range.
  ///
  /// - Parameters:
  ///   - monthEnd: Day of month representing the user's financial month end (1–31).
  ///   - after: Start date (inclusive). Nil = all history.
  /// - Returns: Array of ExpenseBreakdown grouped by category and financial month.
  /// - Throws: BackendError on network/auth failure.
  func fetchExpenseBreakdown(
    monthEnd: Int,
    after: Date?
  ) async throws -> [ExpenseBreakdown]

  /// Fetch monthly income and expense summary for a date range.
  ///
  /// - Parameters:
  ///   - monthEnd: Day of month representing the user's financial month end (1–31).
  ///   - after: Start date (inclusive). Nil = all history.
  /// - Returns: Array of MonthlyIncomeExpense grouped by financial month.
  /// - Throws: BackendError on network/auth failure.
  func fetchIncomeAndExpense(
    monthEnd: Int,
    after: Date?
  ) async throws -> [MonthlyIncomeExpense]
}
```

**Error Cases:**
- `.unauthorized`: Session expired or invalid auth token
- `.networkError(underlying: Error)`: No internet, timeout, DNS failure
- `.serverError(statusCode: Int, message: String?)`: 5xx server errors
- `.invalidResponse`: Malformed JSON, missing fields, type mismatch

**Thread Safety:**
- All methods are `async` and may be called from any actor (repository implementations handle dispatching to correct thread)
- Return types are `Sendable` (safe to pass across actor boundaries)

### 3.2 Update BackendProvider

**File:** `Domain/Repositories/BackendProvider.swift`

```swift
protocol BackendProvider: Sendable {
  var auth: any AuthProvider { get }
  var accounts: any AccountRepository { get }
  var transactions: any TransactionRepository { get }
  var categories: any CategoryRepository { get }
  var earmarks: any EarmarkRepository { get }
  var analysis: any AnalysisRepository { get }  // ← NEW
}
```

---

## 4. Backend Implementation

### 4.1 InMemoryBackend

**File:** `Backends/InMemory/InMemoryAnalysisRepository.swift`

The in-memory implementation computes analysis results from the stored transactions array. This is used in tests and SwiftUI previews.

#### 4.1.1 Daily Balances Algorithm

```swift
import Foundation

final class InMemoryAnalysisRepository: AnalysisRepository {
  private let transactionRepository: InMemoryTransactionRepository
  private let accountRepository: InMemoryAccountRepository
  private let earmarkRepository: InMemoryEarmarkRepository

  init(
    transactionRepository: InMemoryTransactionRepository,
    accountRepository: InMemoryAccountRepository,
    earmarkRepository: InMemoryEarmarkRepository
  ) {
    self.transactionRepository = transactionRepository
    self.accountRepository = accountRepository
    self.earmarkRepository = earmarkRepository
  }

  func fetchDailyBalances(
    after: Date?,
    forecastUntil: Date?
  ) async throws -> [DailyBalance] {
    // 1. Fetch all non-scheduled transactions
    let filter = TransactionFilter(scheduled: false)
    let allTransactions = try await transactionRepository.fetch(filter: filter)

    // 2. Filter by date range
    let transactions = allTransactions.filter { txn in
      guard let after = after else { return true }
      return txn.date >= after
    }

    // 3. Get accounts to classify as current vs investment
    let accounts = try await accountRepository.fetchAll()
    let investmentAccountIds = Set(accounts.filter { $0.type == .investment }.map(\.id))

    // 4. Compute daily balances
    var dailyBalances: [Date: DailyBalance] = [:]
    var currentBalance: MonetaryAmount = .zero
    var currentInvestments: MonetaryAmount = .zero
    var currentEarmarks: MonetaryAmount = .zero

    // If 'after' is provided, compute starting balances up to that date
    if let after = after {
      let priorFilter = TransactionFilter(scheduled: false)
      let priorTransactions = try await transactionRepository.fetch(filter: priorFilter)
        .filter { $0.date < after }

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
        investmentValue: nil,  // Not computed in-memory (requires external data)
        netWorth: currentBalance + currentInvestments,
        bestFit: nil,  // Not computed in-memory (requires regression library)
        isForecast: false
      )
    }

    // 5. Generate forecasted balances if requested
    var scheduledBalances: [DailyBalance] = []
    if let forecastUntil = forecastUntil {
      scheduledBalances = try await generateForecast(
        startDate: transactions.last?.date ?? Date(),
        endDate: forecastUntil,
        startingBalance: currentBalance,
        startingEarmarks: currentEarmarks,
        investmentAccountIds: investmentAccountIds
      )
    }

    // 6. Combine and return
    let actualBalances = dailyBalances.values.sorted { $0.date < $1.date }
    return actualBalances + scheduledBalances
  }

  private func applyTransaction(
    _ txn: Transaction,
    to balance: inout MonetaryAmount,
    investments: inout MonetaryAmount,
    earmarks: inout MonetaryAmount,
    investmentAccountIds: Set<UUID>
  ) {
    let isFromInvestment = txn.accountId.map { investmentAccountIds.contains($0) } ?? false
    let isToInvestment = txn.toAccountId.map { investmentAccountIds.contains($0) } ?? false

    switch txn.type {
    case .income, .expense:
      // Only count if accountId is non-nil (completed transaction)
      if txn.accountId != nil {
        balance += txn.amount  // income: positive, expense: negative
      }
      if txn.earmarkId != nil {
        earmarks += txn.amount
      }

    case .transfer:
      // Transfer: amount is always from the perspective of accountId
      if isFromInvestment && !isToInvestment {
        // From investment to current: increase balance, decrease investments
        balance += txn.amount
        investments -= txn.amount
      } else if !isFromInvestment && isToInvestment {
        // From current to investment: decrease balance, increase investments
        balance -= txn.amount
        investments += txn.amount
      }
      // Current-to-current transfers are net-zero on balance
    }
  }

  private func generateForecast(
    startDate: Date,
    endDate: Date,
    startingBalance: MonetaryAmount,
    startingEarmarks: MonetaryAmount,
    investmentAccountIds: Set<UUID>
  ) async throws -> [DailyBalance] {
    // 1. Fetch all scheduled transactions
    let scheduledFilter = TransactionFilter(scheduled: true)
    let scheduledTransactions = try await transactionRepository.fetch(filter: scheduledFilter)

    // 2. Extrapolate instances up to endDate
    var instances: [Transaction] = []
    for scheduled in scheduledTransactions {
      instances.append(contentsOf: extrapolateScheduledTransaction(scheduled, until: endDate))
    }

    // 3. Sort by date and apply to running balances
    instances.sort { $0.date < $1.date }
    var balance = startingBalance
    var earmarks = startingEarmarks
    var investments: MonetaryAmount = .zero  // Forecast doesn't track investment transfers (simplified)

    var forecastBalances: [Date: DailyBalance] = [:]
    for instance in instances {
      applyTransaction(
        instance,
        to: &balance,
        investments: &investments,
        earmarks: &earmarks,
        investmentAccountIds: investmentAccountIds
      )

      let dayKey = Calendar.current.startOfDay(for: instance.date)
      forecastBalances[dayKey] = DailyBalance(
        date: dayKey,
        balance: balance,
        earmarked: earmarks,
        availableFunds: balance - earmarks,
        investments: investments,
        investmentValue: nil,
        netWorth: balance + investments,
        bestFit: nil,
        isForecast: true
      )
    }

    return forecastBalances.values.sorted { $0.date < $1.date }
  }

  private func extrapolateScheduledTransaction(
    _ scheduled: Transaction,
    until endDate: Date
  ) -> [Transaction] {
    guard let period = scheduled.recurPeriod, period != .once else {
      // One-time scheduled transactions: single instance if date <= endDate
      return scheduled.date <= endDate ? [scheduled] : []
    }

    let every = scheduled.recurEvery ?? 1
    var instances: [Transaction] = []
    var currentDate = scheduled.date

    while currentDate <= endDate {
      var instance = scheduled
      instance.date = currentDate
      instance.recurPeriod = nil  // Instances are not scheduled
      instance.recurEvery = nil
      instances.append(instance)

      // Calculate next occurrence
      guard let nextDate = nextDueDate(from: currentDate, period: period, every: every) else {
        break
      }
      currentDate = nextDate
    }

    return instances
  }

  private func nextDueDate(from date: Date, period: RecurPeriod, every: Int) -> Date? {
    let calendar = Calendar.current
    var components = DateComponents()

    switch period {
    case .day:
      components.day = every
    case .week:
      components.weekOfYear = every
    case .month:
      components.month = every
    case .year:
      components.year = every
    case .once:
      return nil  // No recurrence
    }

    return calendar.date(byAdding: components, to: date)
  }

  // ... fetchExpenseBreakdown and fetchIncomeAndExpense implementations below
}
```

#### 4.1.2 Expense Breakdown Algorithm

```swift
func fetchExpenseBreakdown(
  monthEnd: Int,
  after: Date?
) async throws -> [ExpenseBreakdown] {
  // 1. Fetch all non-scheduled expense transactions
  let filter = TransactionFilter(scheduled: false, type: .expense)
  var transactions = try await transactionRepository.fetch(filter: filter)

  // 2. Filter by date range
  if let after = after {
    transactions = transactions.filter { $0.date >= after }
  }

  // 3. Group by (categoryId, financialMonth)
  var breakdown: [String: [UUID?: MonetaryAmount]] = [:]  // [month: [categoryId: total]]

  for txn in transactions {
    guard txn.categoryId != nil || txn.amount.cents < 0 else { continue }  // Only categorized expenses
    let month = financialMonth(for: txn.date, monthEnd: monthEnd)
    let categoryId = txn.categoryId

    if breakdown[month] == nil {
      breakdown[month] = [:]
    }
    let current = breakdown[month]![categoryId] ?? .zero
    breakdown[month]![categoryId] = current + MonetaryAmount(cents: abs(txn.amount.cents))
  }

  // 4. Flatten to ExpenseBreakdown array
  var results: [ExpenseBreakdown] = []
  for (month, categories) in breakdown {
    for (categoryId, total) in categories {
      results.append(ExpenseBreakdown(
        categoryId: categoryId,
        month: month,
        totalExpenses: total
      ))
    }
  }

  return results.sorted { $0.month > $1.month }  // Most recent first
}

private func financialMonth(for date: Date, monthEnd: Int) -> String {
  let calendar = Calendar.current
  let dayOfMonth = calendar.component(.day, from: date)
  let adjustedDate = dayOfMonth > monthEnd
    ? calendar.date(byAdding: .month, value: 1, to: date)!
    : date

  let year = calendar.component(.year, from: adjustedDate)
  let month = calendar.component(.month, from: adjustedDate)
  return String(format: "%04d%02d", year, month)
}
```

#### 4.1.3 Income and Expense Algorithm

```swift
func fetchIncomeAndExpense(
  monthEnd: Int,
  after: Date?
) async throws -> [MonthlyIncomeExpense] {
  // 1. Fetch all non-scheduled transactions
  let filter = TransactionFilter(scheduled: false)
  var transactions = try await transactionRepository.fetch(filter: filter)

  // 2. Filter by date range
  if let after = after {
    transactions = transactions.filter { $0.date >= after }
  }

  // 3. Get investment account IDs
  let accounts = try await accountRepository.fetchAll()
  let investmentAccountIds = Set(accounts.filter { $0.type == .investment }.map(\.id))

  // 4. Group by financial month
  var monthlyData: [String: (
    start: Date,
    end: Date,
    income: MonetaryAmount,
    expense: MonetaryAmount,
    earmarkedIncome: MonetaryAmount,
    earmarkedExpense: MonetaryAmount
  )] = [:]

  for txn in transactions {
    guard txn.accountId != nil else { continue }  // Only completed transactions
    let month = financialMonth(for: txn.date, monthEnd: monthEnd)

    // Initialize month entry
    if monthlyData[month] == nil {
      monthlyData[month] = (
        start: txn.date,
        end: txn.date,
        income: .zero,
        expense: .zero,
        earmarkedIncome: .zero,
        earmarkedExpense: .zero
      )
    }

    // Update date range
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
    case .income:
      if isEarmarked {
        monthlyData[month]!.earmarkedIncome += txn.amount
      } else {
        monthlyData[month]!.income += txn.amount
      }

    case .expense:
      let absAmount = MonetaryAmount(cents: abs(txn.amount.cents))
      if isEarmarked {
        monthlyData[month]!.earmarkedExpense += absAmount
      } else {
        monthlyData[month]!.expense += absAmount
      }

    case .transfer:
      if isFromInvestment && !isToInvestment {
        // From investment to current: earmarked expense (returning funds)
        monthlyData[month]!.earmarkedExpense += MonetaryAmount(cents: abs(txn.amount.cents))
      } else if !isFromInvestment && isToInvestment {
        // From current to investment: earmarked income (allocating funds)
        monthlyData[month]!.earmarkedIncome += MonetaryAmount(cents: abs(txn.amount.cents))
      }
    }
  }

  // 5. Convert to MonthlyIncomeExpense array
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
  }.sorted { $0.month > $1.month }  // Most recent first
}
```

**Testing Strategy (InMemoryBackend):**
- Create sample transactions with known dates, amounts, categories
- Verify daily balances match hand-calculated values
- Verify forecasts extrapolate correctly for each RecurPeriod
- Verify expense breakdown groups by category and month
- Verify income/expense table handles earmarks and investment transfers correctly
- Verify financial month calculation (monthEnd parameter)

### 4.2 RemoteBackend

**File:** `Backends/Remote/Repositories/RemoteAnalysisRepository.swift`

The remote implementation calls the moolah-server REST API and maps JSON responses to domain models.

```swift
import Foundation

final class RemoteAnalysisRepository: AnalysisRepository {
  private let apiClient: APIClient

  init(apiClient: APIClient) {
    self.apiClient = apiClient
  }

  func fetchDailyBalances(
    after: Date?,
    forecastUntil: Date?
  ) async throws -> [DailyBalance] {
    var queryItems: [URLQueryItem] = []
    if let after = after {
      queryItems.append(URLQueryItem(name: "after", value: after.ISO8601Format()))
    }
    if let forecastUntil = forecastUntil {
      queryItems.append(URLQueryItem(name: "forecastUntil", value: forecastUntil.ISO8601Format()))
    }

    let response: DailyBalancesResponseDTO = try await apiClient.get(
      path: "/api/analysis/dailyBalances/",
      queryItems: queryItems
    )

    var balances = response.dailyBalances.map { $0.toDomain(isForecast: false) }
    if let scheduled = response.scheduledBalances {
      balances.append(contentsOf: scheduled.map { $0.toDomain(isForecast: true) })
    }
    return balances.sorted { $0.date < $1.date }
  }

  func fetchExpenseBreakdown(
    monthEnd: Int,
    after: Date?
  ) async throws -> [ExpenseBreakdown] {
    var queryItems: [URLQueryItem] = [
      URLQueryItem(name: "monthEnd", value: String(monthEnd))
    ]
    if let after = after {
      queryItems.append(URLQueryItem(name: "after", value: after.ISO8601Format()))
    }

    let response: [ExpenseBreakdownDTO] = try await apiClient.get(
      path: "/api/analysis/expenseBreakdown/",
      queryItems: queryItems
    )

    return response.map { $0.toDomain() }
  }

  func fetchIncomeAndExpense(
    monthEnd: Int,
    after: Date?
  ) async throws -> [MonthlyIncomeExpense] {
    var queryItems: [URLQueryItem] = [
      URLQueryItem(name: "monthEnd", value: String(monthEnd))
    ]
    if let after = after {
      queryItems.append(URLQueryItem(name: "after", value: after.ISO8601Format()))
    }

    let response: IncomeAndExpenseResponseDTO = try await apiClient.get(
      path: "/api/analysis/incomeAndExpense/",
      queryItems: queryItems
    )

    return response.incomeAndExpense.map { $0.toDomain() }
  }
}
```

**DTOs:**

**File:** `Backends/Remote/DTOs/DailyBalanceDTO.swift`

```swift
import Foundation

struct DailyBalancesResponseDTO: Codable {
  let dailyBalances: [DailyBalanceDTO]
  let scheduledBalances: [DailyBalanceDTO]?
}

struct DailyBalanceDTO: Codable {
  let date: String  // "YYYY-MM-DD"
  let balance: Int
  let earmarked: Int
  let availableFunds: Int
  let investments: Int
  let investmentValue: Int?
  let netWorth: Int
  let bestFit: Double?

  func toDomain(isForecast: Bool) -> DailyBalance {
    let dateFormatter = ISO8601DateFormatter()
    dateFormatter.formatOptions = [.withFullDate]

    return DailyBalance(
      date: dateFormatter.date(from: date) ?? Date(),
      balance: MonetaryAmount(cents: balance),
      earmarked: MonetaryAmount(cents: earmarked),
      availableFunds: MonetaryAmount(cents: availableFunds),
      investments: MonetaryAmount(cents: investments),
      investmentValue: investmentValue.map { MonetaryAmount(cents: $0) },
      netWorth: MonetaryAmount(cents: netWorth),
      bestFit: bestFit.map { MonetaryAmount(cents: Int($0)) },
      isForecast: isForecast
    )
  }
}
```

**File:** `Backends/Remote/DTOs/ExpenseBreakdownDTO.swift`

```swift
import Foundation

struct ExpenseBreakdownDTO: Codable {
  let categoryId: String?  // UUID string or null
  let month: String        // "YYYYMM"
  let totalExpenses: Int

  func toDomain() -> ExpenseBreakdown {
    ExpenseBreakdown(
      categoryId: categoryId.flatMap { UUID(uuidString: $0) },
      month: month,
      totalExpenses: MonetaryAmount(cents: totalExpenses)
    )
  }
}
```

**File:** `Backends/Remote/DTOs/MonthlyIncomeExpenseDTO.swift`

```swift
import Foundation

struct IncomeAndExpenseResponseDTO: Codable {
  let incomeAndExpense: [MonthlyIncomeExpenseDTO]
}

struct MonthlyIncomeExpenseDTO: Codable {
  let month: String  // "YYYYMM"
  let start: String  // "YYYY-MM-DD"
  let end: String    // "YYYY-MM-DD"
  let income: Int
  let expense: Int
  let profit: Int
  let earmarkedIncome: Int
  let earmarkedExpense: Int
  let earmarkedProfit: Int

  func toDomain() -> MonthlyIncomeExpense {
    let dateFormatter = ISO8601DateFormatter()
    dateFormatter.formatOptions = [.withFullDate]

    return MonthlyIncomeExpense(
      month: month,
      start: dateFormatter.date(from: start) ?? Date(),
      end: dateFormatter.date(from: end) ?? Date(),
      income: MonetaryAmount(cents: income),
      expense: MonetaryAmount(cents: expense),
      profit: MonetaryAmount(cents: profit),
      earmarkedIncome: MonetaryAmount(cents: earmarkedIncome),
      earmarkedExpense: MonetaryAmount(cents: earmarkedExpense),
      earmarkedProfit: MonetaryAmount(cents: earmarkedProfit)
    )
  }
}
```

**Fixture JSON:**

**File:** `MoolahTests/Support/Fixtures/analysis_dailyBalances.json`

```json
{
  "dailyBalances": [
    {
      "date": "2026-04-01",
      "balance": 500000,
      "earmarked": 100000,
      "availableFunds": 400000,
      "investments": 200000,
      "investmentValue": 220000,
      "netWorth": 720000,
      "bestFit": 500000
    },
    {
      "date": "2026-04-02",
      "balance": 480000,
      "earmarked": 100000,
      "availableFunds": 380000,
      "investments": 200000,
      "investmentValue": 220000,
      "netWorth": 700000,
      "bestFit": 499500
    }
  ],
  "scheduledBalances": [
    {
      "date": "2026-04-03",
      "balance": 460000,
      "earmarked": 100000,
      "availableFunds": 360000,
      "investments": 200000,
      "investmentValue": null,
      "netWorth": 660000,
      "bestFit": 499000
    }
  ]
}
```

**File:** `MoolahTests/Support/Fixtures/analysis_expenseBreakdown.json`

```json
[
  {
    "categoryId": "550e8400-e29b-41d4-a716-446655440001",
    "month": "202604",
    "totalExpenses": 150000
  },
  {
    "categoryId": "550e8400-e29b-41d4-a716-446655440002",
    "month": "202604",
    "totalExpenses": 80000
  }
]
```

**File:** `MoolahTests/Support/Fixtures/analysis_incomeAndExpense.json`

```json
{
  "incomeAndExpense": [
    {
      "month": "202604",
      "start": "2026-03-26",
      "end": "2026-04-25",
      "income": 500000,
      "expense": 300000,
      "profit": 200000,
      "earmarkedIncome": 50000,
      "earmarkedExpense": 20000,
      "earmarkedProfit": 30000
    }
  ]
}
```

---

## 5. UI Components

### 5.1 AnalysisStore

**File:** `Features/Analysis/AnalysisStore.swift`

```swift
import Foundation
import OSLog
import Observation

@Observable
@MainActor
final class AnalysisStore {
  // State
  private(set) var dailyBalances: [DailyBalance] = []
  private(set) var expenseBreakdown: [ExpenseBreakdown] = []
  private(set) var incomeAndExpense: [MonthlyIncomeExpense] = []
  private(set) var isLoading = false
  private(set) var error: Error?

  // Filters
  var historyMonths: Int = 12  // 1, 3, 6, 12, 24, 36, etc., or 0 = "All"
  var forecastMonths: Int = 1  // 0 = "None", 1, 3, 6, etc.
  var monthEnd: Int = 25       // User's financial month-end day (1-31)

  private let repository: AnalysisRepository
  private let logger = Logger(subsystem: "com.moolah.app", category: "AnalysisStore")

  init(repository: AnalysisRepository) {
    self.repository = repository
  }

  func loadAll() async {
    isLoading = true
    error = nil

    do {
      async let balances = loadDailyBalances()
      async let breakdown = loadExpenseBreakdown()
      async let income = loadIncomeAndExpense()

      _ = try await (balances, breakdown, income)
    } catch {
      logger.error("Failed to load analysis data: \(error.localizedDescription)")
      self.error = error
    }

    isLoading = false
  }

  private func loadDailyBalances() async throws {
    let after = afterDate(monthsAgo: historyMonths)
    let forecastUntil = forecastDate(monthsAhead: forecastMonths)

    dailyBalances = try await repository.fetchDailyBalances(
      after: after,
      forecastUntil: forecastUntil
    )
  }

  private func loadExpenseBreakdown() async throws {
    let after = afterDate(monthsAgo: historyMonths)

    expenseBreakdown = try await repository.fetchExpenseBreakdown(
      monthEnd: monthEnd,
      after: after
    )
  }

  private func loadIncomeAndExpense() async throws {
    let after = afterDate(monthsAgo: historyMonths)

    incomeAndExpense = try await repository.fetchIncomeAndExpense(
      monthEnd: monthEnd,
      after: after
    )
  }

  private func afterDate(monthsAgo: Int) -> Date? {
    guard monthsAgo > 0 else { return nil }  // 0 = "All"
    return Calendar.current.date(byAdding: .month, value: -monthsAgo, to: Date())
  }

  private func forecastDate(monthsAhead: Int) -> Date? {
    guard monthsAhead > 0 else { return nil }  // 0 = "None"
    return Calendar.current.date(byAdding: .month, value: monthsAhead, to: Date())
  }
}
```

**Reactivity:**
- Changes to `historyMonths`, `forecastMonths`, or `monthEnd` should trigger `loadAll()` (SwiftUI `.onChange` in view)
- All state properties are `@Observable` (SwiftUI tracks dependencies automatically)

### 5.2 AnalysisView

**File:** `Features/Analysis/Views/AnalysisView.swift`

```swift
import SwiftUI

struct AnalysisView: View {
  @Environment(BackendProvider.self) private var backend
  @State private var store: AnalysisStore?

  var body: some View {
    ScrollView {
      if let store = store {
        VStack(spacing: 20) {
          // Net Worth Graph
          NetWorthGraphCard(balances: store.dailyBalances)

          HStack(alignment: .top, spacing: 20) {
            // Left column: Upcoming + Expense Breakdown
            VStack(spacing: 20) {
              UpcomingTransactionsCard()
              ExpenseBreakdownCard(breakdown: store.expenseBreakdown)
            }
            .frame(maxWidth: .infinity)

            // Right column: Income & Expense Table
            IncomeExpenseTableCard(data: store.incomeAndExpense)
              .frame(maxWidth: .infinity)
          }
        }
        .padding()
      } else {
        ProgressView("Loading analysis...")
      }
    }
    .navigationTitle("Analysis")
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Menu {
          HistoryPicker(selection: $store?.historyMonths ?? .constant(12))
          ForecastPicker(selection: $store?.forecastMonths ?? .constant(1))
        } label: {
          Label("Filters", systemImage: "slider.horizontal.3")
        }
      }
    }
    .task {
      if store == nil {
        store = AnalysisStore(repository: backend.analysis)
      }
      await store?.loadAll()
    }
    .onChange(of: store?.historyMonths) { _, _ in
      Task { await store?.loadAll() }
    }
    .onChange(of: store?.forecastMonths) { _, _ in
      Task { await store?.loadAll() }
    }
  }
}
```

**Layout:**
- macOS/iPad: Two-column layout (HStack) with flexible widths
- iPhone: Single-column vertical stack (VStack instead of HStack, conditional on `horizontalSizeClass`)

### 5.3 NetWorthGraphCard

**File:** `Features/Analysis/Views/NetWorthGraphCard.swift`

Uses **Swift Charts** to render a multi-series area/line chart.

```swift
import SwiftUI
import Charts

struct NetWorthGraphCard: View {
  let balances: [DailyBalance]

  @State private var selectedDate: Date?

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Net Worth")
        .font(.title2)
        .fontWeight(.semibold)

      Chart {
        ForEach(actualBalances) { balance in
          // Available Funds (solid green area)
          AreaMark(
            x: .value("Date", balance.date),
            y: .value("Amount", balance.availableFunds.cents)
          )
          .foregroundStyle(.green.opacity(0.3))
          .interpolationMethod(.stepEnd)

          LineMark(
            x: .value("Date", balance.date),
            y: .value("Amount", balance.availableFunds.cents)
          )
          .foregroundStyle(.green)
          .interpolationMethod(.stepEnd)

          // Net Worth (solid blue line)
          LineMark(
            x: .value("Date", balance.date),
            y: .value("Amount", balance.netWorth.cents)
          )
          .foregroundStyle(.blue)
          .interpolationMethod(.stepEnd)

          // Best Fit (gray dashed line)
          if let bestFit = balance.bestFit {
            LineMark(
              x: .value("Date", balance.date),
              y: .value("Amount", bestFit.cents)
            )
            .foregroundStyle(.gray)
            .lineStyle(StrokeStyle(lineWidth: 1, dash: [5, 5]))
          }
        }

        // Forecasted balances (lighter colors, dashed)
        ForEach(forecastBalances) { balance in
          AreaMark(
            x: .value("Date", balance.date),
            y: .value("Amount", balance.availableFunds.cents)
          )
          .foregroundStyle(.green.opacity(0.1))
          .interpolationMethod(.stepEnd)

          LineMark(
            x: .value("Date", balance.date),
            y: .value("Amount", balance.availableFunds.cents)
          )
          .foregroundStyle(.green.opacity(0.5))
          .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
          .interpolationMethod(.stepEnd)

          LineMark(
            x: .value("Date", balance.date),
            y: .value("Amount", balance.netWorth.cents)
          )
          .foregroundStyle(.blue.opacity(0.5))
          .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
          .interpolationMethod(.stepEnd)
        }

        // Selection rule
        if let selectedDate = selectedDate {
          RuleMark(x: .value("Selected", selectedDate))
            .foregroundStyle(.gray.opacity(0.5))
            .lineStyle(StrokeStyle(lineWidth: 1))
        }
      }
      .chartXAxis {
        AxisMarks(values: .automatic(desiredCount: 6)) { value in
          AxisGridLine()
          AxisTick()
          AxisValueLabel(format: .dateTime.month().day())
        }
      }
      .chartYAxis {
        AxisMarks { value in
          AxisGridLine()
          AxisValueLabel {
            if let cents = value.as(Int.self) {
              Text(MonetaryAmount(cents: cents).formatted())
            }
          }
        }
      }
      .chartXSelection(value: $selectedDate)
      .frame(height: 300)
      .padding()
      .background(Color(.systemBackground))
      .cornerRadius(12)
      .shadow(radius: 2)

      // Legend
      HStack(spacing: 16) {
        LegendItem(color: .green, label: "Available Funds")
        LegendItem(color: .blue, label: "Net Worth")
        LegendItem(color: .gray, label: "Best Fit", dashed: true)
      }
      .font(.caption)
      .padding(.horizontal)
    }
  }

  private var actualBalances: [DailyBalance] {
    balances.filter { !$0.isForecast }
  }

  private var forecastBalances: [DailyBalance] {
    balances.filter { $0.isForecast }
  }
}

struct LegendItem: View {
  let color: Color
  let label: String
  var dashed: Bool = false

  var body: some View {
    HStack(spacing: 4) {
      Rectangle()
        .fill(color)
        .frame(width: 16, height: 2)
        .overlay {
          if dashed {
            Rectangle()
              .stroke(style: StrokeStyle(lineWidth: 2, dash: [3, 3]))
              .fill(color)
          }
        }
      Text(label)
    }
  }
}
```

**Interaction:**
- Tap/click to select a date → show tooltip with exact values
- Pinch-to-zoom on iOS, trackpad zoom on macOS
- Forecast balances rendered with lighter opacity and dashed lines

### 5.4 ExpenseBreakdownCard

**File:** `Features/Analysis/Views/ExpenseBreakdownCard.swift`

Pie chart with drill-down by category hierarchy.

```swift
import SwiftUI
import Charts

struct ExpenseBreakdownCard: View {
  let breakdown: [ExpenseBreakdown]

  @Environment(\.categoryStore) private var categoryStore
  @State private var rootCategoryId: UUID? = nil

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Expenses by Category")
        .font(.title2)
        .fontWeight(.semibold)

      if filteredBreakdown.isEmpty {
        Text("No expense data")
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .center)
          .padding(.vertical, 40)
      } else {
        Chart(filteredBreakdown, id: \.categoryId) { item in
          SectorMark(
            angle: .value("Amount", item.totalExpenses.cents),
            innerRadius: .ratio(0.5),
            angularInset: 1.5
          )
          .foregroundStyle(by: .value("Category", categoryName(for: item.categoryId)))
          .annotation(position: .overlay) {
            if item.percentage > 5 {  // Only show label if >5%
              Text("\(Int(item.percentage))%")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.white)
            }
          }
        }
        .frame(height: 250)

        // Legend
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150))], spacing: 8) {
          ForEach(filteredBreakdown, id: \.categoryId) { item in
            HStack {
              Circle()
                .fill(categoryColor(for: item.categoryId))
                .frame(width: 10, height: 10)
              Text(categoryName(for: item.categoryId))
                .font(.caption)
              Spacer()
              Text(item.totalExpenses.formatted())
                .font(.caption)
                .monospacedDigit()
            }
            .onTapGesture {
              if let category = categoryStore.categories.first(where: { $0.id == item.categoryId }),
                 !category.children.isEmpty {
                rootCategoryId = item.categoryId
              }
            }
          }
        }

        // Breadcrumbs
        if rootCategoryId != nil {
          HStack {
            Button("All Categories") {
              rootCategoryId = nil
            }
            .font(.caption)
            .foregroundStyle(.blue)
          }
        }
      }
    }
    .padding()
    .background(Color(.systemBackground))
    .cornerRadius(12)
    .shadow(radius: 2)
  }

  private var filteredBreakdown: [ExpenseBreakdownWithPercentage] {
    // Sum all expenses for this category level
    let categoryTotals = Dictionary(grouping: breakdown) { $0.categoryId }
      .mapValues { items in
        items.reduce(MonetaryAmount.zero) { $0 + $1.totalExpenses }
      }

    // Filter by rootCategoryId (show only children if drill-down active)
    let visibleCategories: [UUID?]
    if let rootId = rootCategoryId {
      let children = categoryStore.categories
        .filter { $0.parentId == rootId }
        .map { $0.id as UUID? }
      visibleCategories = children
    } else {
      // Show top-level categories (no parent)
      visibleCategories = categoryStore.categories
        .filter { $0.parentId == nil }
        .map { $0.id as UUID? }
    }

    let filtered = categoryTotals.filter { visibleCategories.contains($0.key) }
    let total = filtered.values.reduce(MonetaryAmount.zero, +)

    return filtered.map { categoryId, amount in
      ExpenseBreakdownWithPercentage(
        categoryId: categoryId,
        totalExpenses: amount,
        percentage: total.cents > 0 ? Double(amount.cents) / Double(total.cents) * 100 : 0
      )
    }
    .sorted { $0.totalExpenses.cents > $1.totalExpenses.cents }
  }

  private func categoryName(for id: UUID?) -> String {
    guard let id = id else { return "Uncategorized" }
    return categoryStore.categories.first { $0.id == id }?.name ?? "Unknown"
  }

  private func categoryColor(for id: UUID?) -> Color {
    // Use category's color or generate from hash
    guard let id = id else { return .gray }
    return categoryStore.categories.first { $0.id == id }?.color ?? Color.random(seed: id.uuidString)
  }
}

struct ExpenseBreakdownWithPercentage {
  let categoryId: UUID?
  let totalExpenses: MonetaryAmount
  let percentage: Double
}

extension Color {
  static func random(seed: String) -> Color {
    var hash = seed.hashValue
    let r = Double((hash & 0xFF0000) >> 16) / 255.0
    let g = Double((hash & 0x00FF00) >> 8) / 255.0
    let b = Double(hash & 0x0000FF) / 255.0
    return Color(red: r, green: g, blue: b)
  }
}
```

**Drill-Down:**
- Tap a category with children → filter to show only those children
- Breadcrumb to return to top-level view

### 5.5 IncomeExpenseTableCard

**File:** `Features/Analysis/Views/IncomeExpenseTableCard.swift`

```swift
import SwiftUI

struct IncomeExpenseTableCard: View {
  let data: [MonthlyIncomeExpense]

  @State private var includeEarmarks = false

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("Monthly Income & Expense")
          .font(.title2)
          .fontWeight(.semibold)

        Spacer()

        Toggle("Include Earmarks", isOn: $includeEarmarks)
          .toggleStyle(.switch)
          .font(.caption)
      }

      Table(of: MonthlyIncomeExpense.self) {
        TableColumn("Month") { item in
          VStack(alignment: .leading, spacing: 2) {
            Text(monthLabel(for: item))
              .font(.body)
            Text(monthsAgoLabel(for: item))
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }

        TableColumn("Income") { item in
          Text(income(for: item).formatted())
            .monospacedDigit()
            .foregroundStyle(.green)
        }
        .alignment(.trailing)

        TableColumn("Expense") { item in
          Text(expense(for: item).formatted())
            .monospacedDigit()
            .foregroundStyle(.red)
        }
        .alignment(.trailing)

        TableColumn("Savings") { item in
          Text(profit(for: item).formatted())
            .monospacedDigit()
            .foregroundStyle(profit(for: item).cents >= 0 ? .green : .red)
        }
        .alignment(.trailing)

        TableColumn("Total Savings") { item in
          Text(cumulativeSavings(upTo: item).formatted())
            .monospacedDigit()
            .foregroundStyle(.blue)
        }
        .alignment(.trailing)
      } rows: {
        ForEach(data) { item in
          TableRow(item)
        }
      }
      .frame(height: 400)
    }
    .padding()
    .background(Color(.systemBackground))
    .cornerRadius(12)
    .shadow(radius: 2)
  }

  private func income(for item: MonthlyIncomeExpense) -> MonetaryAmount {
    includeEarmarks ? item.totalIncome : item.income
  }

  private func expense(for item: MonthlyIncomeExpense) -> MonetaryAmount {
    includeEarmarks ? item.totalExpense : item.expense
  }

  private func profit(for item: MonthlyIncomeExpense) -> MonetaryAmount {
    includeEarmarks ? item.totalProfit : item.profit
  }

  private func cumulativeSavings(upTo item: MonthlyIncomeExpense) -> MonetaryAmount {
    let index = data.firstIndex { $0.id == item.id } ?? 0
    return data[index...].reduce(MonetaryAmount.zero) { total, month in
      total + profit(for: month)
    }
  }

  private func monthLabel(for item: MonthlyIncomeExpense) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "MMM yyyy"
    return formatter.string(from: item.start)
  }

  private func monthsAgoLabel(for item: MonthlyIncomeExpense) -> String {
    let months = Calendar.current.dateComponents([.month], from: item.end, to: Date()).month ?? 0
    if months == 0 { return "This month" }
    if months == 1 { return "Last month" }
    return "\(months) months ago"
  }
}
```

**iPhone Adaptation:**
- Replace `Table` with `List` (Table is macOS/iPad only)
- Each row shows month + key metrics (income/expense/savings)
- Tap row → sheet with full details

### 5.6 UpcomingTransactionsCard

**File:** `Features/Analysis/Views/UpcomingTransactionsCard.swift`

Reuses the existing `UpcomingView` with a filter for short-term (14 days).

```swift
import SwiftUI

struct UpcomingTransactionsCard: View {
  @Environment(BackendProvider.self) private var backend
  @State private var store: TransactionStore?

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Upcoming (Next 14 Days)")
        .font(.title2)
        .fontWeight(.semibold)

      if let store = store {
        if shortTermTransactions.isEmpty {
          Text("No upcoming transactions")
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 20)
        } else {
          List(shortTermTransactions) { txn in
            UpcomingTransactionRow(transaction: txn.transaction) {
              await store.payTransaction(txn.transaction)
            }
          }
          .listStyle(.plain)
          .frame(height: 200)
        }
      } else {
        ProgressView()
      }
    }
    .padding()
    .background(Color(.systemBackground))
    .cornerRadius(12)
    .shadow(radius: 2)
    .task {
      if store == nil {
        store = TransactionStore(repository: backend.transactions)
      }
      await store?.load(filter: TransactionFilter(scheduled: true))
    }
  }

  private var shortTermTransactions: [TransactionWithBalance] {
    let twoWeeksFromNow = Calendar.current.date(byAdding: .day, value: 14, to: Date()) ?? Date()
    return store?.transactions.filter { $0.transaction.date <= twoWeeksFromNow } ?? []
  }
}
```

---

## 6. Testing Strategy

### 6.1 Contract Tests

**File:** `MoolahTests/Domain/AnalysisRepositoryContractTests.swift`

Defines the expected behavior of `AnalysisRepository` implementations. Both `InMemoryAnalysisRepository` and `RemoteAnalysisRepository` must pass these tests.

```swift
import Testing
import Foundation
@testable import Moolah

@Suite("AnalysisRepository Contract Tests")
struct AnalysisRepositoryContractTests {
  @Test("fetchDailyBalances returns balances ordered by date")
  func dailyBalancesOrdering() async throws {
    let repository = makeRepository()
    // Seed with transactions on different dates
    // ...

    let balances = try await repository.fetchDailyBalances(after: nil, forecastUntil: nil)

    for i in 0..<balances.count - 1 {
      #expect(balances[i].date <= balances[i + 1].date)
    }
  }

  @Test("fetchDailyBalances computes availableFunds correctly")
  func availableFundsCalculation() async throws {
    let repository = makeRepository()
    // ...

    let balances = try await repository.fetchDailyBalances(after: nil, forecastUntil: nil)

    for balance in balances {
      #expect(balance.availableFunds == balance.balance - balance.earmarked)
    }
  }

  @Test("fetchDailyBalances with forecastUntil includes scheduled balances")
  func forecastIncludesScheduled() async throws {
    let repository = makeRepository()
    // Seed with a recurring transaction
    // ...

    let balances = try await repository.fetchDailyBalances(
      after: nil,
      forecastUntil: Date().addingTimeInterval(30 * 86400)  // 30 days
    )

    let forecast = balances.filter { $0.isForecast }
    #expect(forecast.count > 0)
  }

  @Test("fetchExpenseBreakdown groups by category and month")
  func expenseBreakdownGrouping() async throws {
    let repository = makeRepository()
    // Seed with expenses in same category, different months
    // ...

    let breakdown = try await repository.fetchExpenseBreakdown(monthEnd: 25, after: nil)

    // Verify grouping (same category, different months should appear separately)
    // ...
  }

  @Test("fetchExpenseBreakdown excludes scheduled transactions")
  func expenseBreakdownExcludesScheduled() async throws {
    let repository = makeRepository()
    // Seed with scheduled expense
    // ...

    let breakdown = try await repository.fetchExpenseBreakdown(monthEnd: 25, after: nil)

    // Verify no scheduled transactions in results
    #expect(breakdown.allSatisfy { /* not from scheduled txn */ })
  }

  @Test("fetchIncomeAndExpense computes profit correctly")
  func incomeExpenseProfitCalculation() async throws {
    let repository = makeRepository()
    // ...

    let data = try await repository.fetchIncomeAndExpense(monthEnd: 25, after: nil)

    for month in data {
      #expect(month.profit == month.income - month.expense)
      #expect(month.earmarkedProfit == month.earmarkedIncome - month.earmarkedExpense)
    }
  }

  @Test("fetchIncomeAndExpense handles investment transfers as earmarked")
  func investmentTransfersAsEarmarked() async throws {
    let repository = makeRepository()
    // Seed with transfer to investment account
    // ...

    let data = try await repository.fetchIncomeAndExpense(monthEnd: 25, after: nil)

    // Verify transfer to investment appears in earmarkedIncome
    // ...
  }
}
```

### 6.2 InMemoryBackend Computation Tests

**File:** `MoolahTests/Backends/InMemory/InMemoryAnalysisRepositoryTests.swift`

Tests specific to the in-memory implementation's algorithms.

```swift
@Test("Financial month calculation respects monthEnd parameter")
func financialMonthCalculation() async throws {
  let repository = InMemoryAnalysisRepository(/* ... */)
  // Create transaction on Jan 26 with monthEnd = 25
  // Expected: grouped into "202602" (Feb financial month)

  let breakdown = try await repository.fetchExpenseBreakdown(monthEnd: 25, after: nil)

  #expect(breakdown.first?.month == "202602")
}

@Test("Forecast extrapolates daily recurring transactions correctly")
func dailyRecurrenceExtrapolation() async throws {
  let repository = InMemoryAnalysisRepository(/* ... */)
  // Seed with daily recurring transaction (recurPeriod: .day, recurEvery: 1)
  // Forecast 7 days ahead
  // Expected: 7 instances

  let balances = try await repository.fetchDailyBalances(
    after: nil,
    forecastUntil: Date().addingTimeInterval(7 * 86400)
  )

  let forecast = balances.filter { $0.isForecast }
  #expect(forecast.count == 7)
}

@Test("Forecast marks all balances with isForecast: true")
func forecastFlagSetCorrectly() async throws {
  let repository = InMemoryAnalysisRepository(/* ... */)
  // ...

  let balances = try await repository.fetchDailyBalances(
    after: nil,
    forecastUntil: Date().addingTimeInterval(30 * 86400)
  )

  let actual = balances.filter { !$0.isForecast }
  let forecast = balances.filter { $0.isForecast }

  #expect(actual.count > 0)
  #expect(forecast.count > 0)
  #expect(actual.allSatisfy { $0.date <= Date() })
  #expect(forecast.allSatisfy { $0.date > Date() })
}
```

### 6.3 RemoteBackend Tests

**File:** `MoolahTests/Backends/Remote/RemoteAnalysisRepositoryTests.swift`

Uses `URLProtocol` stubs with fixture JSON.

```swift
@Test("fetchDailyBalances parses server response correctly")
func dailyBalancesParsing() async throws {
  let apiClient = makeAPIClient(fixture: "analysis_dailyBalances")
  let repository = RemoteAnalysisRepository(apiClient: apiClient)

  let balances = try await repository.fetchDailyBalances(after: nil, forecastUntil: nil)

  #expect(balances.count == 3)  // 2 actual + 1 forecast
  #expect(balances[0].isForecast == false)
  #expect(balances[2].isForecast == true)
}

@Test("fetchExpenseBreakdown sends correct query parameters")
func expenseBreakdownQueryParams() async throws {
  let apiClient = makeAPIClient(fixture: "analysis_expenseBreakdown")
  let repository = RemoteAnalysisRepository(apiClient: apiClient)

  let after = Date(timeIntervalSince1970: 1672531200)  // 2023-01-01
  _ = try await repository.fetchExpenseBreakdown(monthEnd: 25, after: after)

  // Verify APIClient was called with correct query params
  // (requires spy/mock implementation of APIClient)
}
```

### 6.4 UI Tests

**File:** `MoolahTests/Features/Analysis/AnalysisViewTests.swift`

Snapshot tests for layout and rendering (use inline snapshots or compare to reference images).

```swift
@Test("AnalysisView renders net worth graph")
func netWorthGraphRendering() async throws {
  let store = AnalysisStore(repository: makeInMemoryRepository())
  await store.loadAll()

  let view = AnalysisView()
    .environment(\.analysisStore, store)

  // Verify chart is rendered (use accessibility labels or view hierarchy inspection)
}

@Test("ExpenseBreakdownCard shows empty state when no data")
func expenseBreakdownEmptyState() async throws {
  let card = ExpenseBreakdownCard(breakdown: [])

  // Verify "No expense data" message is visible
}

@Test("IncomeExpenseTableCard toggles earmark inclusion")
func earmarkToggleBehavior() async throws {
  let data = [
    MonthlyIncomeExpense(/* ... with earmarked amounts */)
  ]
  let card = IncomeExpenseTableCard(data: data)

  // Initially includeEarmarks = false
  // Verify income == item.income (not totalIncome)

  // Toggle includeEarmarks = true
  // Verify income == item.totalIncome
}
```

---

## 7. Acceptance Criteria

### 7.1 Functional Requirements

- [ ] **Dashboard loads on app launch** (after successful authentication)
- [ ] **Net worth graph displays actual balances** (solid line/area)
- [ ] **Net worth graph displays forecasted balances** when forecast period > 0 (dashed line/lighter area)
- [ ] **Expense breakdown shows top-level categories** by default
- [ ] **Expense breakdown allows drill-down** to subcategories (tap category with children)
- [ ] **Expense breakdown shows percentages** and total amounts
- [ ] **Income/expense table shows monthly data** sorted most recent first
- [ ] **Income/expense table toggles earmark inclusion** (checkbox/switch)
- [ ] **Income/expense table shows cumulative savings** (running total)
- [ ] **Upcoming widget shows next 14 days** of scheduled transactions
- [ ] **Upcoming widget allows paying transactions** (inline action)
- [ ] **History filter updates all charts** (1 month, 3 months, 6 months, 1 year, 2 years, 3 years, All)
- [ ] **Forecast filter updates net worth graph** (None, 1 month, 3 months, 6 months)
- [ ] **Empty state shown** when user has no transaction history

### 7.2 Data Integrity

- [ ] **Daily balances are ordered by date** (ascending)
- [ ] **Available funds = balance - earmarked** (verified in tests)
- [ ] **Net worth = balance + investmentValue (or investments)** (verified in tests)
- [ ] **Forecast balances have isForecast: true** (verified in tests)
- [ ] **Expense breakdown excludes scheduled transactions** (verified in tests)
- [ ] **Income/expense table excludes scheduled transactions** (verified in tests)
- [ ] **Financial month grouping respects monthEnd parameter** (e.g., 25th = Jan 26 – Feb 25 is "Feb")
- [ ] **Investment transfers appear in earmarked columns** (not regular income/expense)

### 7.3 UI/UX Requirements (per UI_GUIDE.md)

- [ ] **All monetary amounts use .monospacedDigit()** modifier
- [ ] **All charts use semantic colors** (.green for income/available, .red for expense, .blue for net worth)
- [ ] **Net worth graph uses .stepEnd interpolation** (not smooth curves) to reflect daily snapshots
- [ ] **Expense breakdown pie chart has inner radius** (donut chart, not full pie)
- [ ] **Tables support sorting** (if >1 column is sortable)
- [ ] **VoiceOver labels on all chart elements** (accessibility)
- [ ] **Keyboard navigation works** (macOS: tab through controls, arrow keys in charts)
- [ ] **Dynamic Type support** (text scales correctly at all sizes)
- [ ] **Layout adapts to horizontal size class** (two-column on macOS/iPad, single-column on iPhone)

### 7.4 Performance

- [ ] **Dashboard loads in <2 seconds** (on typical data set: 1000 transactions, 20 categories)
- [ ] **Chart rendering is smooth** (60fps on macOS, 120fps on ProMotion displays)
- [ ] **No UI jank when toggling filters** (debounced or optimistic updates)

### 7.5 Testing

- [ ] **All contract tests pass for InMemoryBackend**
- [ ] **All contract tests pass for RemoteBackend** (with fixture JSON)
- [ ] **All computation tests pass** (financial month, forecast extrapolation, etc.)
- [ ] **All UI tests pass** (rendering, empty states, interactions)
- [ ] **Manual testing on macOS and iOS** (both light and dark mode)

---

## 8. Implementation Steps (TDD Order)

Follow strict TDD: write the test first, watch it fail, implement the minimum code to make it pass, refactor.

### Step 1: Domain Models (1 hour)

1. Create `Domain/Models/DailyBalance.swift` (struct + tests)
2. Create `Domain/Models/ExpenseBreakdown.swift` (struct + tests)
3. Create `Domain/Models/MonthlyIncomeExpense.swift` (struct + tests)
4. Write tests for computed properties (e.g., `MonthlyIncomeExpense.totalIncome`)

### Step 2: Repository Protocol (30 min)

1. Create `Domain/Repositories/AnalysisRepository.swift` (protocol only)
2. Update `Domain/Repositories/BackendProvider.swift` to add `var analysis: any AnalysisRepository`
3. Write contract test stubs in `MoolahTests/Domain/AnalysisRepositoryContractTests.swift`

### Step 3: InMemoryBackend — Daily Balances (3 hours)

1. Write test: "fetchDailyBalances returns empty array when no transactions"
2. Implement `InMemoryAnalysisRepository.fetchDailyBalances` (minimal: return `[]`)
3. Write test: "fetchDailyBalances computes balance from single transaction"
4. Implement: apply transaction to running balance
5. Write test: "fetchDailyBalances handles income, expense, transfer"
6. Implement: transaction type logic
7. Write test: "fetchDailyBalances respects 'after' parameter"
8. Implement: date filtering
9. Write test: "fetchDailyBalances computes availableFunds correctly"
10. Implement: `availableFunds = balance - earmarked`
11. Write test: "fetchDailyBalances includes forecast when forecastUntil is set"
12. Implement: `generateForecast` method
13. Write test: "forecast extrapolates daily recurring transactions"
14. Implement: `extrapolateScheduledTransaction` for `.day` period
15. Write test: "forecast extrapolates weekly/monthly/yearly recurring transactions"
16. Implement: all `RecurPeriod` cases in `nextDueDate`
17. Refactor: extract helper methods

### Step 4: InMemoryBackend — Expense Breakdown (2 hours)

1. Write test: "fetchExpenseBreakdown groups by category"
2. Implement: basic grouping logic
3. Write test: "fetchExpenseBreakdown groups by financial month"
4. Implement: `financialMonth` helper
5. Write test: "fetchExpenseBreakdown respects monthEnd parameter"
6. Implement: adjust month based on day-of-month
7. Write test: "fetchExpenseBreakdown excludes scheduled transactions"
8. Implement: filter by `recurPeriod == nil`
9. Write test: "fetchExpenseBreakdown handles uncategorized expenses"
10. Implement: allow `categoryId == nil`
11. Refactor: simplify grouping logic

### Step 5: InMemoryBackend — Income & Expense (2 hours)

1. Write test: "fetchIncomeAndExpense computes income and expense"
2. Implement: basic aggregation by month
3. Write test: "fetchIncomeAndExpense computes profit"
4. Implement: `profit = income - expense`
5. Write test: "fetchIncomeAndExpense handles earmarked income/expense"
6. Implement: separate earmarked totals
7. Write test: "fetchIncomeAndExpense treats investment transfers as earmarked"
8. Implement: check `accountType` for investment classification
9. Write test: "fetchIncomeAndExpense respects monthEnd parameter"
10. Implement: use `financialMonth` helper
11. Refactor: extract common logic with expense breakdown

### Step 6: RemoteBackend — DTOs & Mapping (2 hours)

1. Create `Backends/Remote/DTOs/DailyBalanceDTO.swift`
2. Write test: "DailyBalanceDTO maps to DailyBalance correctly"
3. Implement: `toDomain()` method
4. Create `Backends/Remote/DTOs/ExpenseBreakdownDTO.swift` + test + mapping
5. Create `Backends/Remote/DTOs/MonthlyIncomeExpenseDTO.swift` + test + mapping
6. Create fixture JSON files in `MoolahTests/Support/Fixtures/`

### Step 7: RemoteBackend — Repository Implementation (2 hours)

1. Create `Backends/Remote/Repositories/RemoteAnalysisRepository.swift`
2. Write test: "fetchDailyBalances calls correct endpoint with query params"
3. Implement: `fetchDailyBalances` using `apiClient.get`
4. Write test: "fetchDailyBalances handles forecastUntil parameter"
5. Implement: conditional query param
6. Write test: "fetchDailyBalances parses response correctly"
7. Implement: map DTOs to domain models
8. Repeat for `fetchExpenseBreakdown` and `fetchIncomeAndExpense`
9. Write error handling tests (network error, 401, 500)
10. Implement: error mapping in APIClient

### Step 8: AnalysisStore (1 hour)

1. Create `Features/Analysis/AnalysisStore.swift`
2. Write test: "AnalysisStore loads all data on loadAll()"
3. Implement: call all three repository methods
4. Write test: "AnalysisStore computes afterDate from historyMonths"
5. Implement: date calculation helper
6. Write test: "AnalysisStore computes forecastUntil from forecastMonths"
7. Implement: date calculation helper
8. Write test: "AnalysisStore sets isLoading during fetch"
9. Implement: wrap async calls with `isLoading = true/false`

### Step 9: NetWorthGraphCard (3 hours)

1. Create `Features/Analysis/Views/NetWorthGraphCard.swift`
2. Write test: "NetWorthGraphCard renders actual balances"
3. Implement: basic Chart with LineMark
4. Write test: "NetWorthGraphCard renders forecast balances with different style"
5. Implement: filter by `isForecast`, apply dashed line
6. Write test: "NetWorthGraphCard shows best fit line"
7. Implement: additional LineMark for bestFit
8. Write test: "NetWorthGraphCard uses stepEnd interpolation"
9. Implement: `.interpolationMethod(.stepEnd)`
10. Add legend, axis labels, colors
11. Test on macOS and iOS (manual)

### Step 10: ExpenseBreakdownCard (2 hours)

1. Create `Features/Analysis/Views/ExpenseBreakdownCard.swift`
2. Write test: "ExpenseBreakdownCard renders pie chart"
3. Implement: Chart with SectorMark
4. Write test: "ExpenseBreakdownCard shows percentages"
5. Implement: compute percentage, annotate sectors
6. Write test: "ExpenseBreakdownCard filters by rootCategoryId"
7. Implement: drill-down state + filtering logic
8. Write test: "ExpenseBreakdownCard shows breadcrumbs when drilled down"
9. Implement: breadcrumb trail
10. Add colors, legend
11. Test on macOS and iOS (manual)

### Step 11: IncomeExpenseTableCard (2 hours)

1. Create `Features/Analysis/Views/IncomeExpenseTableCard.swift`
2. Write test: "IncomeExpenseTableCard renders table rows"
3. Implement: Table with columns
4. Write test: "IncomeExpenseTableCard shows earmarked toggle"
5. Implement: Toggle + conditional logic
6. Write test: "IncomeExpenseTableCard computes cumulative savings"
7. Implement: running total calculation
8. Add month labels, date formatting
9. Test on macOS (Table not available on iPhone, create List fallback)

### Step 12: UpcomingTransactionsCard (1 hour)

1. Create `Features/Analysis/Views/UpcomingTransactionsCard.swift`
2. Reuse `UpcomingView` with filter for 14 days
3. Write test: "UpcomingTransactionsCard shows only next 14 days"
4. Implement: filter transactions by date
5. Add empty state
6. Test on macOS and iOS (manual)

### Step 13: AnalysisView (1 hour)

1. Create `Features/Analysis/Views/AnalysisView.swift`
2. Assemble all subviews in ScrollView
3. Add toolbar with history/forecast pickers
4. Write test: "AnalysisView initializes AnalysisStore on appear"
5. Implement: `.task` modifier
6. Write test: "AnalysisView reloads on filter change"
7. Implement: `.onChange` modifiers
8. Test layout on macOS (two-column) and iOS (single-column)

### Step 14: Integration & Polish (2 hours)

1. Add AnalysisView to main navigation
2. Update BackendProvider implementations to include analysis repository
3. Run all tests (contract, unit, UI)
4. Fix any failing tests
5. Manual testing on macOS and iOS (light + dark mode)
6. Accessibility audit (VoiceOver, keyboard navigation)
7. Performance profiling (Instruments: Time Profiler, allocations)
8. Address any performance issues (lazy loading, pagination if needed)

**Total Estimated Effort: ~25 hours**

---

## 9. Out of Scope (Deferred to Future Steps)

The following features are present in the web app but are **not** included in this step:

1. **Categories Over Time Graph** — Line chart showing category spending trends over multiple months
2. **Custom Date Range Picker** — Allow user to select arbitrary start/end dates (instead of preset "6 months", "1 year")
3. **Financial Year Picker** — User-configurable fiscal year start (e.g., July 1 for Australian tax year)
4. **Investment Value Tracking** — Manually entered market values for investments (separate from contribution amounts)
5. **Export to CSV** — Download analysis data for external analysis
6. **Comparison Mode** — Side-by-side comparison of two time periods (e.g., this year vs. last year)

These will be addressed in **Step 14 — Platform Polish & Feature Parity**.

---

## 10. Dependencies

This step depends on:

- **Step 9 — Scheduled Transactions** (forecasting requires extrapolating scheduled transactions)
- **Swift Charts** (built-in, no external dependency)
- **CategoryStore** (for category names/colors in expense breakdown)
- **TransactionStore** (for upcoming transactions widget)

No external packages or libraries are required.

---

## 11. Migration Notes

### Web App Differences

| Feature | Web App | moolah-native |
|---------|---------|---------------|
| Chart library | C3.js (D3 wrapper) | Swift Charts |
| Net worth series | 8 series (balance, scheduled, investments, netWorth, etc.) | Simplified to 4 (availableFunds, netWorth, forecast, bestFit) |
| Expense breakdown drill-down | Breadcrumbs at bottom | Breadcrumbs above chart |
| Income/expense table pagination | Vuetify DataTable (6/12/18/24 per page) | Native Table (scrollable, no pagination) |
| Upcoming widget | Separate component | Embedded in AnalysisView |

### Server API Compatibility

The moolah-server API is stable and unchanged. All endpoints return the expected JSON structure as documented in the DTOs above.

---

## 12. Future Enhancements

1. **Offline Support** — Cache analysis data in SwiftData for offline viewing
2. **Interactive Tooltips** — Tap/hover on chart to show exact values for that date
3. **Export/Share** — Export graph as PNG or PDF, share via system share sheet
4. **Predictive Forecasting** — Use machine learning (Core ML) to predict future balances based on historical trends (beyond simple scheduled transaction extrapolation)
5. **Budget vs. Actual** — Overlay budget goals on expense breakdown and income/expense table
6. **Alerts** — Notify user when forecasted balance drops below zero (overdraft warning)

---

**End of Implementation Plan**
