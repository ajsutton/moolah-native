import SwiftUI

/// Main Reports view displaying income and expense breakdown by category.
struct ReportsView: View {
  let analysisRepository: AnalysisRepository
  let categories: Categories
  let accounts: Accounts
  let earmarks: Earmarks
  let transactionStore: TransactionStore

  @State private var dateRange: DateRange = .last12Months
  @State private var customFrom: Date = Calendar.current.date(
    byAdding: .year, value: -1, to: Date())!
  @State private var customTo: Date = Date()

  /// Resolved date range, computed once when dateRange or custom dates change.
  /// Stored in @State to avoid re-evaluating Date() on every SwiftUI render cycle.
  @State private var resolvedFrom: Date = DateRange.last12Months.startDate()
  @State private var resolvedTo: Date = DateRange.last12Months.endDate()

  @State private var incomeBalances: [UUID: InstrumentAmount] = [:]
  @State private var expenseBalances: [UUID: InstrumentAmount] = [:]
  @State private var isLoading = false
  @State private var error: Error?

  var body: some View {
    NavigationStack {
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
          // Income and Expense columns: side by side on macOS, stacked on iOS
          #if os(macOS)
            HStack(spacing: 0) {
              CategoryBalanceTable(
                title: "Income",
                balances: incomeBalances,
                categories: categories,
                dateRange: resolvedFrom...resolvedTo
              )

              Divider()

              CategoryBalanceTable(
                title: "Expenses",
                balances: expenseBalances,
                categories: categories,
                dateRange: resolvedFrom...resolvedTo
              )
            }
          #else
            VStack(spacing: 0) {
              CategoryBalanceTable(
                title: "Income",
                balances: incomeBalances,
                categories: categories,
                dateRange: resolvedFrom...resolvedTo
              )

              Divider()

              CategoryBalanceTable(
                title: "Expenses",
                balances: expenseBalances,
                categories: categories,
                dateRange: resolvedFrom...resolvedTo
              )
            }
          #endif
        }
      }
      .profileNavigationTitle("Reports")
      .navigationDestination(for: CategoryDrillDown.self) { drillDown in
        let categoryName = categories.by(id: drillDown.categoryId)?.name ?? "Category"
        TransactionListView(
          title: categoryName,
          filter: TransactionFilter(
            dateRange: drillDown.dateRange,
            categoryIds: [drillDown.categoryId]
          ),
          accounts: accounts,
          categories: categories,
          earmarks: earmarks,
          transactionStore: transactionStore
        )
      }
    }
    .task {
      await loadData()
    }
    .onChange(of: dateRange) { _, newValue in
      if newValue != .custom {
        resolvedFrom = newValue.startDate()
        resolvedTo = newValue.endDate()
      }
      Task { await loadData() }
    }
    .onChange(of: customFrom) { _, newValue in
      guard dateRange == .custom else { return }
      resolvedFrom = newValue
      Task { await loadData() }
    }
    .onChange(of: customTo) { _, newValue in
      guard dateRange == .custom else { return }
      resolvedTo = newValue
      Task { await loadData() }
    }
  }

  private var dateRangeSelector: some View {
    HStack(spacing: 16) {
      Picker("Date Range", selection: $dateRange) {
        ForEach(DateRange.allCases) { range in
          Text(range.displayName).tag(range)
        }
      }
      .pickerStyle(.menu)
      #if os(macOS)
        .frame(width: 200)
      #endif

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
      let range = resolvedFrom...resolvedTo
      let result = try await analysisRepository.fetchCategoryBalancesByType(
        dateRange: range,
        filters: TransactionFilter()
      )
      incomeBalances = result.income
      expenseBalances = result.expense
    } catch {
      self.error = error
    }

    isLoading = false
  }
}
