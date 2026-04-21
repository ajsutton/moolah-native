# Step 11 — Reports — Detailed Implementation Plan

**Date:** 2026-04-08

## Executive Summary

The Reports feature provides income and expense breakdowns by category for any date range. It reuses the existing `AnalysisRepository` infrastructure (built in Step 10) and displays hierarchical category data with parent/subcategory nesting, totals, and drill-through navigation.

This document specifies the complete Reports feature set based on the moolah web app implementation, identifies what can be reused from Step 10 (Analysis Dashboard), and provides a test-driven implementation roadmap.

---

## Complete Feature Set (moolah web app)

### 1. Data Source

**Server Endpoint:** `GET /api/analysis/categoryBalances/`

**Query Parameters:**
- `from` (YYYY-MM-DD): start date (required)
- `to` (YYYY-MM-DD): end date (required)
- `transactionType` (enum): `'income'` or `'expense'` (required)
- `account` (UUID): filter to specific account (optional)
- `earmark` (UUID): filter to specific earmark (optional)
- `category` (UUID[]): filter to specific categories (optional)
- `payee` (string): filter to specific payee (optional)

**Response:** Dictionary mapping `categoryId → totalAmount`
```json
{
  "uuid-1": 15000,
  "uuid-2": 8500,
  "uuid-3": 42000
}
```

**Note:** The endpoint returns flat category-to-amount mappings. The client is responsible for:
1. Grouping subcategories under their root categories
2. Calculating parent totals by summing child amounts
3. Sorting by amount (largest first)

### 2. Web UI Structure

**Route:** `/reports/`

**Layout:**
```
┌────────────────────────────────────────────────────────────┐
│ Break Down by Category                                     │
├────────────────────────────────────────────────────────────┤
│  Date Range: [▼ Last 12 months]  From: [date]  To: [date] │
├──────────────────────────┬─────────────────────────────────┤
│        Income            │          Expenses               │
├──────────────────────────┼─────────────────────────────────┤
│  Parent Category 1       │  Parent Category A              │
│    Subcategory 1.1       │    Subcategory A.1              │
│    Subcategory 1.2       │    Subcategory A.2              │
│  Parent Category 2       │  Parent Category B              │
│    Subcategory 2.1       │    Subcategory B.1              │
│ ─────────────────        │ ─────────────────               │
│  Total: $15,000          │  Total: $42,000                 │
└──────────────────────────┴─────────────────────────────────┘
```

**Date Range Selector:**
- Preset ranges:
  - This Financial Year (July 1 → June 30)
  - Last Financial Year
  - Last month, 3 months, 6 months, 9 months, 12 months
  - Month to date
  - Quarter to date
  - Year to date
  - Custom (shows manual date pickers)
- Defaults to "Last 12 months"

**Category Tables (one for income, one for expenses):**
- Grouped by root category (parent categories with no parent)
- Parent row shows:
  - **Bold** category name
  - **Bold** total (sum of all subcategories)
- Subcategory rows show:
  - Indented category name (clickable → navigates to filtered transaction list)
  - Amount
- Footer shows grand total
- Sorted by amount descending (largest categories first)

**Data Processing Logic** (`expenseByCategoryReportData.js`):
1. For each `(categoryId, amount)` pair:
   - Find root category (`rootLevelId(categoryId, categoriesById)`)
   - Group subcategories under their root
2. Calculate parent totals by summing children
3. Sort parents by total amount (descending)
4. Sort subcategories within each parent by amount (descending)

### 3. Drill-Through Navigation

Clicking a subcategory navigates to the All Transactions view with filters pre-applied:
```
/transactions/?from=YYYY-MM-DD&to=YYYY-MM-DD&category=[uuid]
```

This allows users to see the individual transactions that contributed to a category's total.

---

## What's Already Implemented in moolah-native

### ✅ Analysis Repository (Step 10)

**File:** `Domain/Repositories/AnalysisRepository.swift` (assumed, not yet implemented)

Expected interface:
```swift
protocol AnalysisRepository: Sendable {
  func fetchDailyBalances(
    dateRange: ClosedRange<Date>,
    includeForecast: Bool
  ) async throws -> [DailyBalance]

  func fetchExpenseBreakdown(
    dateRange: ClosedRange<Date>
  ) async throws -> [CategoryBreakdown]

  func fetchIncomeAndExpense(
    dateRange: ClosedRange<Date>
  ) async throws -> [MonthlyIncomeExpense]
}
```

**Gap:** The existing `AnalysisRepository` (from Step 10) does NOT include a method for category balances. We need to add:
```swift
func fetchCategoryBalances(
  dateRange: ClosedRange<Date>,
  transactionType: TransactionType,
  filters: TransactionFilter?
) async throws -> [UUID: Int]
```

### ✅ Category Hierarchy

**File:** `Domain/Models/Category.swift`

The `Categories` lookup structure already supports:
- `roots: [Category]` — top-level categories
- `children(of: UUID) -> [Category]` — subcategories
- `by(id: UUID) -> Category?` — name lookup

This is sufficient for grouping and nesting.

### ✅ Transaction Filters

**File:** `Domain/Models/Transaction.swift` → `TransactionFilter`

Already supports:
- `dateRange: ClosedRange<Date>?`
- `accountId: UUID?`
- `earmarkId: UUID?`
- `categoryIds: [UUID]?`
- `type: TransactionType?`
- `payee: String?`

This can be passed to `fetchCategoryBalances` for filtered reports.

### ✅ Date Range Utilities

**File:** `Shared/Extensions/Date+Extensions.swift` (assumed)

Common utilities like financial year calculation, month start/end, etc.

---

## What's MISSING in moolah-native

### ❌ 1. `fetchCategoryBalances` Method

**Gap:** `AnalysisRepository` does not include a method to fetch category-to-amount mappings.

**Required:**

#### Domain Layer
```swift
// Domain/Repositories/AnalysisRepository.swift
protocol AnalysisRepository: Sendable {
  // Existing methods from Step 10
  func fetchDailyBalances(...) async throws -> [DailyBalance]
  func fetchExpenseBreakdown(...) async throws -> [CategoryBreakdown]
  func fetchIncomeAndExpense(...) async throws -> [MonthlyIncomeExpense]

  // NEW: Category balances for reports
  /// Returns a dictionary mapping category IDs to total amounts.
  /// - Parameters:
  ///   - dateRange: Date range to analyze
  ///   - transactionType: Filter to 'income' or 'expense' transactions
  ///   - filters: Optional additional filters (account, earmark, payee, etc.)
  /// - Returns: Dictionary where keys are category UUIDs and values are totals in cents
  func fetchCategoryBalances(
    dateRange: ClosedRange<Date>,
    transactionType: TransactionType,
    filters: TransactionFilter?
  ) async throws -> [UUID: Int]
}
```

#### InMemoryBackend
```swift
// Backends/InMemory/InMemoryAnalysisRepository.swift
func fetchCategoryBalances(
  dateRange: ClosedRange<Date>,
  transactionType: TransactionType,
  filters: TransactionFilter?
) async throws -> [UUID: Int] {
  // 1. Fetch all transactions from transactionRepository
  let allTransactions = try await transactionRepository.fetchAll()

  // 2. Apply filters
  let filtered = allTransactions.filter { tx in
    // Date range
    guard dateRange.contains(tx.date) else { return false }

    // Transaction type
    guard tx.type == transactionType else { return false }

    // Must have category
    guard tx.categoryId != nil else { return false }

    // Exclude scheduled transactions
    guard tx.recurPeriod == nil else { return false }

    // Exclude transfers (unless filtering by account)
    if filters?.accountId == nil && tx.type == .transfer {
      return false
    }

    // Apply optional filters
    if let accountId = filters?.accountId, tx.accountId != accountId {
      return false
    }
    if let earmarkId = filters?.earmarkId, tx.earmarkId != earmarkId {
      return false
    }
    if let categoryIds = filters?.categoryIds, !categoryIds.contains(tx.categoryId!) {
      return false
    }
    if let payee = filters?.payee, tx.payee != payee {
      return false
    }

    return true
  }

  // 3. Group by category and sum amounts
  var balances: [UUID: Int] = [:]
  for transaction in filtered {
    let categoryId = transaction.categoryId!
    balances[categoryId, default: 0] += transaction.amount
  }

  return balances
}
```

#### RemoteBackend
```swift
// Backends/Remote/Repositories/RemoteAnalysisRepository.swift
func fetchCategoryBalances(
  dateRange: ClosedRange<Date>,
  transactionType: TransactionType,
  filters: TransactionFilter?
) async throws -> [UUID: Int] {
  var queryItems: [URLQueryItem] = [
    URLQueryItem(name: "from", value: formatDate(dateRange.lowerBound)),
    URLQueryItem(name: "to", value: formatDate(dateRange.upperBound)),
    URLQueryItem(name: "transactionType", value: transactionType.rawValue)
  ]

  // Add optional filters
  if let accountId = filters?.accountId {
    queryItems.append(URLQueryItem(name: "account", value: accountId.uuidString))
  }
  if let earmarkId = filters?.earmarkId {
    queryItems.append(URLQueryItem(name: "earmark", value: earmarkId.uuidString))
  }
  if let categoryIds = filters?.categoryIds {
    queryItems.append(contentsOf: categoryIds.map {
      URLQueryItem(name: "category", value: $0.uuidString)
    })
  }
  if let payee = filters?.payee {
    queryItems.append(URLQueryItem(name: "payee", value: payee))
  }

  let response: [String: Int] = try await apiClient.get(
    "/analysis/categoryBalances",
    queryItems: queryItems
  )

  // Convert string keys to UUIDs
  return response.reduce(into: [:]) { result, pair in
    if let uuid = UUID(uuidString: pair.key) {
      result[uuid] = pair.value
    }
  }
}
```

### ❌ 2. ReportsView UI

**Gap:** No view to display the reports.

**Required:**

#### File: `Features/Reports/Views/ReportsView.swift`
```swift
import SwiftUI

struct ReportsView: View {
  @Environment(BackendProvider.self) private var backend
  @Environment(CategoryStore.self) private var categoryStore

  @State private var dateRange: DateRange = .last12Months
  @State private var customFrom: Date = Calendar.current.date(byAdding: .year, value: -1, to: Date())!
  @State private var customTo: Date = Date()

  @State private var incomeBalances: [UUID: Int] = [:]
  @State private var expenseBalances: [UUID: Int] = [:]
  @State private var isLoading = false
  @State private var error: Error?

  private var effectiveFrom: Date {
    dateRange == .custom ? customFrom : dateRange.startDate
  }

  private var effectiveTo: Date {
    dateRange == .custom ? customTo : dateRange.endDate
  }

  var body: some View {
    VStack(spacing: 0) {
      // Date range selector
      dateRangeSelector

      Divider()

      if isLoading {
        ProgressView("Loading report...")
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if let error {
        ContentUnavailableView {
          Label("Error Loading Report", systemImage: "exclamationmark.triangle")
        } description: {
          Text(error.localizedDescription)
        } actions: {
          Button("Try Again") {
            Task { await loadData() }
          }
        }
      } else {
        // Income and Expense columns
        HStack(spacing: 0) {
          CategoryBalanceTable(
            title: "Income",
            balances: incomeBalances,
            categories: categoryStore.categories,
            dateRange: effectiveFrom...effectiveTo
          )

          Divider()

          CategoryBalanceTable(
            title: "Expenses",
            balances: expenseBalances,
            categories: categoryStore.categories,
            dateRange: effectiveFrom...effectiveTo
          )
        }
      }
    }
    .navigationTitle("Reports")
    .task {
      await loadData()
    }
    .onChange(of: effectiveFrom) { _, _ in
      Task { await loadData() }
    }
    .onChange(of: effectiveTo) { _, _ in
      Task { await loadData() }
    }
  }

  private var dateRangeSelector: some View {
    HStack(spacing: Constants.UI.spacing) {
      Picker("Date Range", selection: $dateRange) {
        ForEach(DateRange.allCases) { range in
          Text(range.displayName).tag(range)
        }
      }
      .pickerStyle(.menu)
      .frame(width: 200)

      if dateRange == .custom {
        DatePicker("From", selection: $customFrom, displayedComponents: .date)
          .labelsHidden()

        DatePicker("To", selection: $customTo, displayedComponents: .date)
          .labelsHidden()
      }

      Spacer()
    }
    .padding()
  }

  private func loadData() async {
    isLoading = true
    error = nil

    do {
      let range = effectiveFrom...effectiveTo
      async let income = backend.analysis.fetchCategoryBalances(
        dateRange: range,
        transactionType: .income,
        filters: nil
      )
      async let expenses = backend.analysis.fetchCategoryBalances(
        dateRange: range,
        transactionType: .expense,
        filters: nil
      )

      (incomeBalances, expenseBalances) = try await (income, expenses)
    } catch {
      self.error = error
    }

    isLoading = false
  }
}
```

#### File: `Features/Reports/Views/CategoryBalanceTable.swift`
```swift
import SwiftUI

struct CategoryBalanceTable: View {
  let title: String
  let balances: [UUID: Int]
  let categories: Categories
  let dateRange: ClosedRange<Date>

  private var reportData: [CategoryGroup] {
    // Group subcategories under roots
    var roots: [UUID: CategoryGroup] = [:]

    for (categoryId, amount) in balances {
      guard let category = categories.by(id: categoryId) else { continue }

      // Find root category
      let rootId = rootCategoryId(for: categoryId)

      // Get or create root group
      var group = roots[rootId] ?? CategoryGroup(
        categoryId: rootId,
        name: categories.by(id: rootId)?.name ?? "Unknown",
        totalAmount: 0,
        children: []
      )

      // Add child
      group.children.append(CategoryChild(
        categoryId: categoryId,
        name: category.name,
        amount: amount
      ))
      group.totalAmount += amount

      roots[rootId] = group
    }

    // Sort roots by total (descending), then children by amount (descending)
    return roots.values
      .map { group in
        var sorted = group
        sorted.children.sort { $0.amount > $1.amount }
        return sorted
      }
      .sorted { $0.totalAmount > $1.totalAmount }
  }

  private var grandTotal: Int {
    balances.values.reduce(0, +)
  }

  var body: some View {
    VStack(spacing: 0) {
      // Header
      HStack {
        Text(title)
          .font(.title2)
          .fontWeight(.semibold)
        Spacer()
      }
      .padding()

      Divider()

      // Table
      List {
        ForEach(reportData) { group in
          Section {
            ForEach(group.children) { child in
              NavigationLink(value: CategoryDrillDown(
                categoryId: child.categoryId,
                dateRange: dateRange
              )) {
                HStack {
                  Text(child.name)
                    .font(.body)
                  Spacer()
                  Text(formatCurrency(child.amount))
                    .monospacedDigit()
                }
              }
            }
          } header: {
            HStack {
              Text(group.name)
                .font(.headline)
              Spacer()
              Text(formatCurrency(group.totalAmount))
                .font(.headline)
                .monospacedDigit()
            }
          }
        }
      }
      .listStyle(.plain)

      // Footer
      Divider()
      HStack {
        Text("Total")
          .font(.headline)
        Spacer()
        Text(formatCurrency(grandTotal))
          .font(.headline)
          .monospacedDigit()
      }
      .padding()
    }
  }

  private func rootCategoryId(for categoryId: UUID) -> UUID {
    var current = categoryId
    while let category = categories.by(id: current),
          let parentId = category.parentId {
      current = parentId
    }
    return current
  }

  private func formatCurrency(_ amount: Int) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .currency
    formatter.currencyCode = Constants.defaultCurrency
    return formatter.string(from: NSNumber(value: Double(amount) / 100)) ?? "$0.00"
  }
}

struct CategoryGroup: Identifiable {
  let categoryId: UUID
  let name: String
  var totalAmount: Int
  var children: [CategoryChild]

  var id: UUID { categoryId }
}

struct CategoryChild: Identifiable {
  let categoryId: UUID
  let name: String
  let amount: Int

  var id: UUID { categoryId }
}

struct CategoryDrillDown: Hashable {
  let categoryId: UUID
  let dateRange: ClosedRange<Date>
}
```

### ❌ 3. DateRange Enum

**Gap:** No shared enum for common date ranges (Last 12 months, Financial Year, etc.)

**Required:**

#### File: `Shared/Models/DateRange.swift`
```swift
import Foundation

enum DateRange: String, CaseIterable, Identifiable, Sendable {
  case thisFinancialYear = "This Financial Year"
  case lastFinancialYear = "Last Financial Year"
  case lastMonth = "Last month"
  case last3Months = "Last 3 months"
  case last6Months = "Last 6 months"
  case last9Months = "Last 9 months"
  case last12Months = "Last 12 months"
  case monthToDate = "Month to date"
  case quarterToDate = "Quarter to date"
  case yearToDate = "Year to date"
  case custom = "Custom"

  var id: String { rawValue }

  var displayName: String { rawValue }

  var startDate: Date {
    let today = Date()
    let calendar = Calendar.current

    switch self {
    case .thisFinancialYear:
      return financialYear(for: today).start
    case .lastFinancialYear:
      return financialYear(for: calendar.date(byAdding: .year, value: -1, to: today)!).start
    case .lastMonth:
      return calendar.date(byAdding: .month, value: -1, to: today)!
    case .last3Months:
      return calendar.date(byAdding: .month, value: -3, to: today)!
    case .last6Months:
      return calendar.date(byAdding: .month, value: -6, to: today)!
    case .last9Months:
      return calendar.date(byAdding: .month, value: -9, to: today)!
    case .last12Months:
      return calendar.date(byAdding: .month, value: -12, to: today)!
    case .monthToDate:
      return calendar.date(from: calendar.dateComponents([.year, .month], from: today))!
    case .quarterToDate:
      let month = calendar.component(.month, from: today)
      let quarterStart = ((month - 1) / 3) * 3 + 1
      return calendar.date(from: DateComponents(
        year: calendar.component(.year, from: today),
        month: quarterStart,
        day: 1
      ))!
    case .yearToDate:
      return calendar.date(from: calendar.dateComponents([.year], from: today))!
    case .custom:
      return calendar.date(byAdding: .year, value: -1, to: today)! // Default for custom
    }
  }

  var endDate: Date {
    let today = Date()

    switch self {
    case .thisFinancialYear:
      return financialYear(for: today).end
    case .lastFinancialYear:
      let lastYear = Calendar.current.date(byAdding: .year, value: -1, to: today)!
      return financialYear(for: lastYear).end
    default:
      return today
    }
  }

  private func financialYear(for date: Date) -> (start: Date, end: Date) {
    let calendar = Calendar.current
    let year = calendar.component(.year, from: date)
    let month = calendar.component(.month, from: date)

    // Financial year: July 1 → June 30
    let fyYear = month >= 7 ? year : year - 1
    let start = calendar.date(from: DateComponents(year: fyYear, month: 7, day: 1))!
    let end = calendar.date(from: DateComponents(year: fyYear + 1, month: 6, day: 30))!

    return (start, end)
  }
}
```

### ❌ 4. Navigation Integration

**Gap:** No navigation path from Reports to filtered transaction list.

**Required:**

Update `NavigationState` (or equivalent) to support deep linking to transaction list with filters:
```swift
// App/NavigationState.swift
enum NavigationDestination: Hashable {
  case accountDetail(UUID)
  case categoryDetail(UUID)
  case transactionList(filter: TransactionFilter)
  case reportDrillDown(CategoryDrillDown)
}
```

Update `ReportsView` to handle navigation:
```swift
.navigationDestination(for: CategoryDrillDown.self) { drillDown in
  TransactionListView(filter: TransactionFilter(
    dateRange: drillDown.dateRange,
    categoryIds: [drillDown.categoryId]
  ))
}
```

---

## Data Requirements Summary

### Reuses from Step 10 (Analysis)
- `AnalysisRepository` protocol (extended with new method)
- `InMemoryAnalysisRepository` and `RemoteAnalysisRepository` classes
- Backend infrastructure (`BackendProvider`, `APIClient`)
- Date utilities

### New Additions
- `fetchCategoryBalances` method on `AnalysisRepository`
- `DateRange` enum (shared with Analysis dashboard)
- `ReportsView` and `CategoryBalanceTable` UI components
- Navigation handling for drill-down to transactions

---

## UI Components Specification

### 1. ReportsView (Main Container)

**Layout:**
- Top toolbar: Date range picker (Picker + optional DatePickers)
- Content: Two-column layout (Income | Expenses)
- Loading state: Centered `ProgressView`
- Error state: `ContentUnavailableView` with retry button

**Accessibility:**
- VoiceOver labels for date pickers
- Keyboard navigation: Tab between date fields, Enter to submit
- Date pickers support system calendar interface

**Platform Adaptations:**
- macOS: Two columns side-by-side
- iPad: Two columns side-by-side in landscape, stacked in portrait
- iPhone: Stacked vertically (Income table, then Expenses table)

### 2. CategoryBalanceTable (Column)

**Layout:**
- Header: Title (Income/Expenses)
- Body: `List` with sections
  - Section header: **Parent Category** + **Total** (bold, larger font)
  - Section rows: Subcategory name (indented) + amount
  - Each row is a `NavigationLink` to filtered transaction list
- Footer: Grand total (bold)

**Styling:**
- Parent totals: `.headline` font, bold
- Subcategory amounts: `.body` font, right-aligned, monospaced digits
- Indentation: Subcategories visually indented (SwiftUI handles this in sections)
- Currency formatting: `NumberFormatter` with `Constants.defaultCurrency`

**Sorting:**
- Parent categories: Sorted by total amount descending (largest first)
- Subcategories within parent: Sorted by amount descending

**Empty State:**
- If no data: Show "No transactions found for this period" (inline in table)

**Accessibility:**
- VoiceOver: "Category name, dollar amount" for each row
- Keyboard: Arrow keys to navigate, Enter to drill down

### 3. Date Range Selector

**Behavior:**
- Picker shows preset ranges + "Custom"
- When "Custom" selected: Show two `DatePicker` fields (From, To)
- When preset selected: Hide date pickers, use preset dates
- Defaults to "Last 12 months"

**Platform Adaptations:**
- macOS: Inline pickers in toolbar
- iOS: Picker as menu, date pickers as sheets

---

## Testing Strategy

### 1. Unit Tests

#### File: `MoolahTests/Domain/AnalysisRepositoryContractTests.swift`

**New Tests for `fetchCategoryBalances`:**
```swift
@Test("Category balances returns flat mapping")
func categoryBalancesFlatMapping() async throws {
  // Given: Transactions with various categories
  let cat1 = Category(name: "Groceries")
  let cat2 = Category(name: "Restaurants")
  let tx1 = Transaction(amount: -5000, categoryId: cat1.id, type: .expense)
  let tx2 = Transaction(amount: -3000, categoryId: cat2.id, type: .expense)
  let tx3 = Transaction(amount: -2000, categoryId: cat1.id, type: .expense)

  // When: Fetch category balances
  let balances = try await analysisRepo.fetchCategoryBalances(
    dateRange: dateRange,
    transactionType: .expense,
    filters: nil
  )

  // Then: Totals are correct
  #expect(balances[cat1.id] == -7000) // 5000 + 2000
  #expect(balances[cat2.id] == -3000)
}

@Test("Category balances excludes scheduled transactions")
func categoryBalancesExcludesScheduled() async throws {
  // Given: One scheduled, one completed
  let cat = Category(name: "Rent")
  let scheduled = Transaction(amount: -100000, categoryId: cat.id, recurPeriod: .month)
  let completed = Transaction(amount: -100000, categoryId: cat.id, recurPeriod: nil)

  // When: Fetch balances
  let balances = try await analysisRepo.fetchCategoryBalances(...)

  // Then: Only completed transaction counted
  #expect(balances[cat.id] == -100000)
}

@Test("Category balances filters by transaction type")
func categoryBalancesFiltersByType() async throws {
  // Given: Income and expense transactions
  let cat = Category(name: "Salary")
  let income = Transaction(amount: 500000, categoryId: cat.id, type: .income)
  let expense = Transaction(amount: -5000, categoryId: cat.id, type: .expense)

  // When: Fetch income balances
  let incomeBalances = try await analysisRepo.fetchCategoryBalances(
    dateRange: dateRange,
    transactionType: .income,
    filters: nil
  )

  // Then: Only income counted
  #expect(incomeBalances[cat.id] == 500000)
}

@Test("Category balances respects date range")
func categoryBalancesRespectsDateRange() async throws {
  let cat = Category(name: "Gas")
  let today = Date()
  let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: today)!
  let lastMonth = Calendar.current.date(byAdding: .month, value: -1, to: today)!

  let tx1 = Transaction(amount: -5000, categoryId: cat.id, date: yesterday)
  let tx2 = Transaction(amount: -3000, categoryId: cat.id, date: lastMonth)

  // When: Fetch for yesterday...today
  let balances = try await analysisRepo.fetchCategoryBalances(
    dateRange: yesterday...today,
    transactionType: .expense,
    filters: nil
  )

  // Then: Only yesterday's transaction counted
  #expect(balances[cat.id] == -5000)
}

@Test("Category balances applies additional filters")
func categoryBalancesAppliesFilters() async throws {
  let cat = Category(name: "Groceries")
  let account1 = Account(name: "Checking")
  let account2 = Account(name: "Credit Card")

  let tx1 = Transaction(amount: -5000, accountId: account1.id, categoryId: cat.id)
  let tx2 = Transaction(amount: -3000, accountId: account2.id, categoryId: cat.id)

  // When: Filter by account1
  let balances = try await analysisRepo.fetchCategoryBalances(
    dateRange: dateRange,
    transactionType: .expense,
    filters: TransactionFilter(accountId: account1.id)
  )

  // Then: Only account1 transaction counted
  #expect(balances[cat.id] == -5000)
}

@Test("Category balances excludes transactions without category")
func categoryBalancesRequiresCategory() async throws {
  let cat = Category(name: "Misc")
  let tx1 = Transaction(amount: -5000, categoryId: cat.id)
  let tx2 = Transaction(amount: -3000, categoryId: nil) // No category

  let balances = try await analysisRepo.fetchCategoryBalances(...)

  #expect(balances.count == 1)
  #expect(balances[cat.id] == -5000)
}
```

### 2. UI Tests

#### File: `MoolahTests/Features/Reports/ReportsViewTests.swift`

```swift
@Test("Reports view displays income and expense columns")
func displaysColumns() async throws {
  // Given: Sample data
  let incomeBalances = [catSalary.id: 500000]
  let expenseBalances = [catGroceries.id: -5000]

  // When: View renders
  let view = ReportsView(incomeBalances: incomeBalances, expenseBalances: expenseBalances)

  // Then: Both columns visible
  #expect(view.contains(text: "Income"))
  #expect(view.contains(text: "Expenses"))
}

@Test("Subcategories grouped under root category")
func subcategoryGrouping() async throws {
  // Given: Root category "Food" with subcategories "Groceries", "Restaurants"
  let food = Category(name: "Food")
  let groceries = Category(name: "Groceries", parentId: food.id)
  let restaurants = Category(name: "Restaurants", parentId: food.id)

  let balances = [
    groceries.id: -5000,
    restaurants.id: -3000
  ]

  // When: Render table
  let table = CategoryBalanceTable(
    title: "Expenses",
    balances: balances,
    categories: Categories(from: [food, groceries, restaurants])
  )

  // Then: Parent shows total, children listed
  #expect(table.contains(text: "Food")) // Parent
  #expect(table.contains(text: "$80.00")) // Total: 5000 + 3000
  #expect(table.contains(text: "Groceries")) // Child
  #expect(table.contains(text: "$50.00"))
  #expect(table.contains(text: "Restaurants")) // Child
  #expect(table.contains(text: "$30.00"))
}

@Test("Categories sorted by amount descending")
func sortByAmount() async throws {
  let cat1 = Category(name: "A") // $10
  let cat2 = Category(name: "B") // $50
  let cat3 = Category(name: "C") // $30

  let balances = [cat1.id: 1000, cat2.id: 5000, cat3.id: 3000]

  let table = CategoryBalanceTable(...)

  // Then: Order is B, C, A
  let order = table.categoryOrder
  #expect(order == [cat2.id, cat3.id, cat1.id])
}

@Test("Grand total matches sum of all categories")
func grandTotalCalculation() async throws {
  let balances = [
    cat1.id: -5000,
    cat2.id: -3000,
    cat3.id: -2000
  ]

  let table = CategoryBalanceTable(...)

  #expect(table.grandTotal == -10000)
  #expect(table.contains(text: "Total"))
  #expect(table.contains(text: "$100.00"))
}

@Test("Date range picker updates data")
func dateRangeUpdatesData() async throws {
  // Given: View with default range
  let view = ReportsView()
  await view.load()

  // When: Change date range
  view.dateRange = .lastMonth

  // Then: Data reloaded with new range
  #expect(view.isLoading == true)
  await view.waitForLoad()
  #expect(view.effectiveFrom == DateRange.lastMonth.startDate)
}

@Test("Custom date range shows date pickers")
func customDateRangeShowsPickers() async throws {
  let view = ReportsView()

  // When: Select custom
  view.dateRange = .custom

  // Then: Date pickers visible
  #expect(view.contains(DatePicker.self))
}

@Test("Empty state when no transactions")
func emptyState() async throws {
  let table = CategoryBalanceTable(
    title: "Income",
    balances: [:],
    categories: Categories(from: [])
  )

  #expect(table.contains(text: "No transactions found"))
}

@Test("Loading state displays progress indicator")
func loadingState() async throws {
  let view = ReportsView()
  view.isLoading = true

  #expect(view.contains(ProgressView.self))
}

@Test("Error state displays retry button")
func errorState() async throws {
  let view = ReportsView()
  view.error = NSError(domain: "test", code: -1)

  #expect(view.contains(text: "Error Loading Report"))
  #expect(view.contains(Button("Try Again")))
}
```

### 3. Edge Cases

```swift
@Test("Handles categories with no transactions")
func emptyCategory() async throws {
  // Category exists but no transactions in date range
  let balances = try await analysisRepo.fetchCategoryBalances(...)
  #expect(balances.isEmpty)
}

@Test("Handles orphaned categories (parent deleted)")
func orphanedCategories() async throws {
  // Subcategory's parent no longer exists
  let orphan = Category(name: "Orphan", parentId: UUID()) // Parent doesn't exist
  let balances = [orphan.id: -5000]

  let table = CategoryBalanceTable(...)

  // Should group under its own ID as root
  #expect(table.reportData.contains(where: { $0.categoryId == orphan.id }))
}

@Test("Handles very large amounts")
func largeAmounts() async throws {
  let cat = Category(name: "Salary")
  let tx = Transaction(amount: Int.max, categoryId: cat.id)

  let balances = try await analysisRepo.fetchCategoryBalances(...)

  // Should not overflow
  #expect(balances[cat.id] == Int.max)
}

@Test("Handles negative date ranges gracefully")
func negativeDateRange() async throws {
  // From > To (invalid)
  let today = Date()
  let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: today)!

  do {
    _ = try await analysisRepo.fetchCategoryBalances(
      dateRange: today...yesterday, // Invalid range
      transactionType: .expense,
      filters: nil
    )
    Issue.record("Should throw error for invalid range")
  } catch {
    // Expected
  }
}
```

---

## Acceptance Criteria

### Must Have (Step 11 Complete)
- [ ] `AnalysisRepository.fetchCategoryBalances` implemented in both backends
- [ ] Contract tests pass for both `InMemoryAnalysisRepository` and `RemoteAnalysisRepository`
- [ ] `ReportsView` displays two columns: Income and Expenses
- [ ] Date range selector defaults to "Last 12 months"
- [ ] Date range selector includes all preset ranges (Financial Year, Last N months, etc.)
- [ ] Date range selector shows date pickers when "Custom" selected
- [ ] Category tables group subcategories under root categories
- [ ] Parent categories show total (sum of subcategories) in bold
- [ ] Subcategories are clickable (navigate to filtered transaction list)
- [ ] Categories sorted by amount descending (largest first)
- [ ] Grand total displayed in footer
- [ ] Grand total matches sum of all category amounts
- [ ] Loading state shows `ProgressView`
- [ ] Error state shows retry button
- [ ] Empty state shows "No transactions found" when no data
- [ ] VoiceOver announces category names and amounts correctly
- [ ] Keyboard navigation works (Tab, Enter)
- [ ] Reports render correctly on both macOS and iOS
- [ ] UI follows UI_GUIDE.md (semantic colors, monospaced digits, proper spacing)

### Should Have (Nice to Have)
- [ ] Export report as CSV or PDF (deferred to Step 14)
- [ ] Filter by account or earmark within Reports view (deferred)
- [ ] Percentage of total displayed next to each category (deferred)
- [ ] Visual chart (pie/bar) in addition to tables (deferred to Analysis Dashboard)

### Won't Have (Out of Scope)
- [ ] Multi-currency reports (assumes single currency)
- [ ] Budget vs. actual comparison (separate feature)
- [ ] Year-over-year comparison (separate feature)

---

## Implementation Steps (TDD Order)

### Phase 1: Domain Layer (2 hours)

1. **Add `fetchCategoryBalances` to `AnalysisRepository` protocol**
   - File: `Domain/Repositories/AnalysisRepository.swift`
   - Write signature, documentation
   - Estimated: 15 minutes

2. **Write contract tests for `fetchCategoryBalances`**
   - File: `MoolahTests/Domain/AnalysisRepositoryContractTests.swift`
   - All test cases from Testing Strategy § 1
   - Estimated: 45 minutes

3. **Implement `InMemoryAnalysisRepository.fetchCategoryBalances`**
   - File: `Backends/InMemory/InMemoryAnalysisRepository.swift`
   - Run tests until all pass
   - Estimated: 30 minutes

4. **Implement `RemoteAnalysisRepository.fetchCategoryBalances`**
   - File: `Backends/Remote/Repositories/RemoteAnalysisRepository.swift`
   - Create fixture JSON for tests
   - File: `MoolahTests/Support/Fixtures/categoryBalances.json`
   - Run tests until all pass
   - Estimated: 30 minutes

### Phase 2: Shared Models (1 hour)

5. **Create `DateRange` enum**
   - File: `Shared/Models/DateRange.swift`
   - All cases, computed properties for start/end dates
   - Estimated: 30 minutes

6. **Write tests for `DateRange` calculations**
   - File: `MoolahTests/Shared/DateRangeTests.swift`
   - Test each preset range (start/end dates)
   - Test financial year calculation (July 1 → June 30)
   - Estimated: 30 minutes

### Phase 3: UI Components (4 hours)

7. **Create `CategoryBalanceTable` view**
   - File: `Features/Reports/Views/CategoryBalanceTable.swift`
   - Grouping logic (subcategories under roots)
   - Sorting logic (by amount descending)
   - Grand total calculation
   - Estimated: 1.5 hours

8. **Write UI tests for `CategoryBalanceTable`**
   - File: `MoolahTests/Features/Reports/CategoryBalanceTableTests.swift`
   - Grouping, sorting, totals (from Testing Strategy § 2)
   - Estimated: 1 hour

9. **Create `ReportsView` container**
   - File: `Features/Reports/Views/ReportsView.swift`
   - Date range selector
   - Two-column layout (Income | Expenses)
   - Loading/error states
   - Data fetching logic
   - Estimated: 1.5 hours

### Phase 4: Navigation & Integration (1.5 hours)

10. **Add navigation destination for report drill-down**
    - File: `App/NavigationState.swift` (or equivalent)
    - Define `CategoryDrillDown` type
    - Handle navigation to filtered `TransactionListView`
    - Estimated: 30 minutes

11. **Add "Reports" to main navigation**
    - File: `App/MainNavigationView.swift` (or equivalent)
    - Add sidebar item with chart icon (`chart.bar.fill`)
    - Update navigation routing
    - Estimated: 15 minutes

12. **Write integration tests**
    - File: `MoolahTests/Features/Reports/ReportsViewIntegrationTests.swift`
    - End-to-end: Load reports, change date range, drill down to transactions
    - Test both backends (InMemory and Remote)
    - Estimated: 45 minutes

### Phase 5: UI Review & Polish (1 hour)

13. **Run `ui-review` agent on `ReportsView` and `CategoryBalanceTable`**
    - Verify UI_GUIDE.md compliance
    - Check accessibility (VoiceOver labels, keyboard navigation)
    - Verify platform adaptations (macOS vs iOS layout)
    - Estimated: 30 minutes

14. **Fix any issues identified by UI review**
    - Apply recommendations from agent
    - Re-test accessibility
    - Estimated: 30 minutes

### Phase 6: Documentation & Cleanup (30 minutes)

15. **Update NATIVE_APP_PLAN.md to mark Step 11 complete**
    - Check off completed items
    - Note any deferred features
    - Estimated: 10 minutes

16. **Add code documentation**
    - Document `fetchCategoryBalances` (usage, parameters, edge cases)
    - Document `DateRange` enum (financial year logic)
    - Estimated: 20 minutes

---

## Total Estimated Effort

| Phase | Estimated Time |
|-------|----------------|
| Phase 1: Domain Layer | 2 hours |
| Phase 2: Shared Models | 1 hour |
| Phase 3: UI Components | 4 hours |
| Phase 4: Navigation & Integration | 1.5 hours |
| Phase 5: UI Review & Polish | 1 hour |
| Phase 6: Documentation & Cleanup | 0.5 hours |
| **Total** | **10 hours** |

---

## Appendices

### A. Server API Reference

| Endpoint | Method | Query Params | Response |
|----------|--------|--------------|----------|
| `/api/analysis/categoryBalances/` | GET | `from`, `to`, `transactionType`, `account?`, `earmark?`, `category[]?`, `payee?` | `{ "uuid": amount }` |

**Example Request:**
```
GET /api/analysis/categoryBalances/?from=2025-01-01&to=2025-12-31&transactionType=expense
```

**Example Response:**
```json
{
  "e3c5a8b1-4d2f-4c1e-9b0a-1f3e5c7d9a2b": -45000,
  "a7f2c4e6-8b3d-4a1c-9e5f-7d2b4c6a8e1f": -32000,
  "f1e3c5a7-9b2d-4f6e-8a0c-2d4f6a8c0e2a": -18000
}
```

### B. Web App File References

| Feature | File Path |
|---------|-----------|
| Reports view | `moolah/src/components/reports/Reports.vue` |
| Category table | `moolah/src/components/reports/ExpensesByCategoryReport.vue` |
| Grouping logic | `moolah/src/components/reports/expenseByCategoryReportData.js` |
| API client | `moolah/src/api/client.js` → `categoryBalances()` |
| Server endpoint | `moolah-server/src/handlers/analysis/categoryBalances.js` |
| Database query | `moolah-server/src/db/transactionDao.js` → `balanceByCategory()` |

### C. Native App File Structure

```
Features/Reports/
├── Views/
│   ├── ReportsView.swift              # Main container
│   └── CategoryBalanceTable.swift     # Income/Expense column
└── Tests/
    ├── ReportsViewTests.swift
    └── CategoryBalanceTableTests.swift

Shared/Models/
└── DateRange.swift                    # Preset date ranges

Domain/Repositories/
└── AnalysisRepository.swift           # fetchCategoryBalances method

Backends/InMemory/
└── InMemoryAnalysisRepository.swift   # In-memory implementation

Backends/Remote/Repositories/
└── RemoteAnalysisRepository.swift     # REST API implementation

MoolahTests/Support/Fixtures/
└── categoryBalances.json              # Sample server response
```

---

**End of Implementation Plan**
