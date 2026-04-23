// swiftlint:disable multiline_arguments

import SwiftUI

/// Main Reports view displaying income and expense breakdown by category.
struct ReportsView: View {
  let reportingStore: ReportingStore
  let categories: Categories
  let accounts: Accounts
  let earmarks: Earmarks
  let transactionStore: TransactionStore

  @Environment(ProfileSession.self) private var session

  @State private var dateRange: DateRange = .last12Months
  @State private var customFrom: Date =
    Calendar.current.date(byAdding: .year, value: -1, to: Date()) ?? Date()
  @State private var customTo = Date()

  /// Resolved date range, computed once when dateRange or custom dates change.
  /// Stored in @State to avoid re-evaluating Date() on every SwiftUI render cycle.
  @State private var resolvedFrom: Date = DateRange.last12Months.startDate()
  @State private var resolvedTo: Date = DateRange.last12Months.endDate()

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        // Date range selector
        dateRangeSelector

        Divider()

        if reportingStore.isLoadingCategoryBalances {
          ProgressView("Loading report...")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = reportingStore.categoryBalancesError {
          ContentUnavailableView {
            Label("Error Loading Report", systemImage: "exclamationmark.triangle")
          } description: {
            Text(error.localizedDescription)
          } actions: {
            Button("Try Again") {
              Task {
                await reportingStore.loadCategoryBalances(dateRange: resolvedFrom...resolvedTo)
              }
            }
          }
        } else {
          // Income and Expense columns: side by side on macOS, stacked on iOS
          #if os(macOS)
            HStack(spacing: 0) {
              CategoryBalanceTable(
                title: "Income",
                balances: reportingStore.incomeBalances,
                categories: categories,
                dateRange: resolvedFrom...resolvedTo,
                profileInstrument: reportingStore.profileCurrency
              )

              Divider()

              CategoryBalanceTable(
                title: "Expenses",
                balances: reportingStore.expenseBalances,
                categories: categories,
                dateRange: resolvedFrom...resolvedTo,
                profileInstrument: reportingStore.profileCurrency
              )
            }
          #else
            VStack(spacing: 0) {
              CategoryBalanceTable(
                title: "Income",
                balances: reportingStore.incomeBalances,
                categories: categories,
                dateRange: resolvedFrom...resolvedTo,
                profileInstrument: reportingStore.profileCurrency
              )

              Divider()

              CategoryBalanceTable(
                title: "Expenses",
                balances: reportingStore.expenseBalances,
                categories: categories,
                dateRange: resolvedFrom...resolvedTo,
                profileInstrument: reportingStore.profileCurrency
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
          transactionStore: transactionStore,
          supportsComplexTransactions: session.profile.supportsComplexTransactions
        )
      }
    }
    .task(id: DateRangeKey(from: resolvedFrom, to: resolvedTo)) {
      await reportingStore.loadCategoryBalances(dateRange: resolvedFrom...resolvedTo)
    }
    .onChange(of: dateRange) { _, newValue in
      guard newValue != .custom else { return }
      resolvedFrom = newValue.startDate()
      resolvedTo = newValue.endDate()
    }
    .onChange(of: customFrom) { _, newValue in
      guard dateRange == .custom else { return }
      resolvedFrom = newValue
    }
    .onChange(of: customTo) { _, newValue in
      guard dateRange == .custom else { return }
      resolvedTo = newValue
    }
  }

  /// Stable identity for the `.task(id:)` trigger — re-running the load
  /// whenever either endpoint changes while letting SwiftUI cancel any
  /// in-flight request when the view disappears.
  private struct DateRangeKey: Hashable {
    let from: Date
    let to: Date
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
}

#Preview {
  let (backend, _) = PreviewBackend.create()
  let transactionStore = TransactionStore(
    repository: backend.transactions,
    conversionService: backend.conversionService,
    targetInstrument: .AUD
  )
  let reportingStore = ReportingStore(
    transactionRepository: backend.transactions,
    analysisRepository: backend.analysis,
    conversionService: backend.conversionService,
    profileCurrency: .AUD
  )
  let salaryId = UUID()
  let groceriesId = UUID()
  let rentId = UUID()
  let categories = Categories(from: [
    Category(id: salaryId, name: "Salary"),
    Category(id: groceriesId, name: "Groceries"),
    Category(id: rentId, name: "Rent"),
  ])
  let account = Account(name: "Checking", type: .bank, instrument: .AUD)
  let session = ProfileSession(profile: Profile(label: "Preview", backendType: .moolah))

  ReportsView(
    reportingStore: reportingStore,
    categories: categories,
    accounts: Accounts(from: [account]),
    earmarks: Earmarks(from: []),
    transactionStore: transactionStore
  )
  .environment(session)
  .frame(width: 900, height: 600)
  .task {
    _ = try? await backend.accounts.create(
      account, openingBalance: InstrumentAmount(quantity: 5_000, instrument: .AUD))
    _ = try? await backend.categories.create(
      Category(id: salaryId, name: "Salary"))
    _ = try? await backend.categories.create(
      Category(id: groceriesId, name: "Groceries"))
    _ = try? await backend.categories.create(
      Category(id: rentId, name: "Rent"))
    _ = try? await backend.transactions.create(
      Transaction(
        date: Date(), payee: "Employer",
        legs: [
          TransactionLeg(
            accountId: account.id, instrument: .AUD, quantity: 4500, type: .income,
            categoryId: salaryId)
        ]))
    _ = try? await backend.transactions.create(
      Transaction(
        date: Date().addingTimeInterval(-86400), payee: "Supermarket",
        legs: [
          TransactionLeg(
            accountId: account.id, instrument: .AUD, quantity: -220, type: .expense,
            categoryId: groceriesId)
        ]))
    _ = try? await backend.transactions.create(
      Transaction(
        date: Date().addingTimeInterval(-2 * 86400), payee: "Landlord",
        legs: [
          TransactionLeg(
            accountId: account.id, instrument: .AUD, quantity: -1800, type: .expense,
            categoryId: rentId)
        ]))
  }
}
