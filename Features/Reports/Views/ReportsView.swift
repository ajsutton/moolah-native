import SwiftUI

/// Main Reports view displaying income and expense breakdown by category.
struct ReportsView: View {
  let analysisRepository: AnalysisRepository
  let categories: Categories

  @State private var dateRange: DateRange = .last12Months
  @State private var customFrom: Date = Calendar.current.date(
    byAdding: .year, value: -1, to: Date())!
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
            categories: categories,
            dateRange: effectiveFrom...effectiveTo
          )

          Divider()

          CategoryBalanceTable(
            title: "Expenses",
            balances: expenseBalances,
            categories: categories,
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
    HStack(spacing: 16) {
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
      async let income = analysisRepository.fetchCategoryBalances(
        dateRange: range,
        transactionType: .income,
        filters: TransactionFilter()
      )
      async let expenses = analysisRepository.fetchCategoryBalances(
        dateRange: range,
        transactionType: .expense,
        filters: TransactionFilter()
      )

      (incomeBalances, expenseBalances) = try await (income, expenses)
    } catch {
      self.error = error
    }

    isLoading = false
  }
}
