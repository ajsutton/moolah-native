import SwiftUI

struct AnalysisView: View {
  @Environment(AccountStore.self) private var accountStore
  @Environment(CategoryStore.self) private var categoryStore
  @Environment(EarmarkStore.self) private var earmarkStore
  @Environment(TransactionStore.self) private var transactionStore
  @Environment(\.scenePhase) private var scenePhase

  @Bindable var store: AnalysisStore

  var body: some View {
    ScrollView {
      if store.isLoading && store.dailyBalances.isEmpty {
        ProgressView("Loading analysis...")
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .frame(minHeight: 400)
      } else if let error = store.error {
        ContentUnavailableView {
          Label("Error Loading Analysis", systemImage: "exclamationmark.triangle")
        } description: {
          Text(error.localizedDescription)
        } actions: {
          Button("Try Again") {
            Task { await store.loadAll() }
          }
        }
      } else {
        contentView(store: store)
      }
    }
    .profileNavigationTitle("Analysis")
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Menu {
          Section("History") {
            HistoryPicker(selection: $store.historyMonths)
          }

          Section("Forecast") {
            ForecastPicker(selection: $store.forecastMonths)
          }
        } label: {
          Label("Filters", systemImage: "slider.horizontal.3")
        }
      }
    }
    .task {
      await transactionStore.load(filter: TransactionFilter(scheduled: true))
      await store.loadAll()
    }
    .onChange(of: store.historyMonths) { _, _ in
      Task { await store.loadAll() }
    }
    .onChange(of: store.forecastMonths) { _, _ in
      Task { await store.loadAll() }
    }
    .onChange(of: scenePhase) { _, newPhase in
      if newPhase == .active {
        Task { await store.loadAll() }
      }
    }
  }

  @ViewBuilder
  private func contentView(store: AnalysisStore) -> some View {
    VStack(spacing: 20) {
      // Net Worth Graph (full width)
      NetWorthGraphCard(balances: store.dailyBalances)

      // Upcoming Transactions & Monthly Income/Expense
      #if os(macOS)
        HStack(alignment: .top, spacing: 20) {
          UpcomingTransactionsCard(
            accounts: accountStore.accounts,
            categories: categoryStore.categories,
            earmarks: earmarkStore.earmarks,
            transactionStore: transactionStore
          )
          IncomeExpenseTableCard(data: store.incomeAndExpense)
        }
      #else
        UpcomingTransactionsCard(
          accounts: accountStore.accounts,
          categories: categoryStore.categories,
          earmarks: earmarkStore.earmarks,
          transactionStore: transactionStore
        )
        IncomeExpenseTableCard(data: store.incomeAndExpense)
      #endif

      // Expense Breakdown (full width)
      ExpenseBreakdownCard(
        breakdown: store.expenseBreakdown,
        categories: categoryStore.categories
      )

      // Categories Over Time (full width)
      CategoriesOverTimeCard(
        entries: store.categoriesOverTime(categories: categoryStore.categories),
        categories: categoryStore.categories,
        currency: store.dailyBalances.first?.balance.currency ?? .AUD,
        showActualValues: $store.showActualValues
      )
    }
    .padding()
  }
}

struct HistoryPicker: View {
  @Binding var selection: Int

  var body: some View {
    Picker("History Period", selection: $selection) {
      Text("1 Month").tag(1)
      Text("3 Months").tag(3)
      Text("6 Months").tag(6)
      Text("1 Year").tag(12)
      Text("2 Years").tag(24)
      Text("3 Years").tag(36)
      Text("All").tag(0)
    }
  }
}

struct ForecastPicker: View {
  @Binding var selection: Int

  var body: some View {
    Picker("Forecast Period", selection: $selection) {
      Text("None").tag(0)
      Text("1 Month").tag(1)
      Text("3 Months").tag(3)
      Text("6 Months").tag(6)
    }
  }
}

#Preview {
  let backend = InMemoryBackend()
  let accountStore = AccountStore(repository: backend.accounts)
  let categoryStore = CategoryStore(repository: backend.categories)
  let earmarkStore = EarmarkStore(repository: backend.earmarks)
  let transactionStore = TransactionStore(repository: backend.transactions)
  let analysisStore = AnalysisStore(repository: backend.analysis)

  NavigationStack {
    AnalysisView(store: analysisStore)
      .environment(accountStore)
      .environment(categoryStore)
      .environment(earmarkStore)
      .environment(transactionStore)
      .task {
        // Add some preview data
        let account = Account(
          id: UUID(),
          name: "Checking",
          type: .bank,
          balance: MonetaryAmount(cents: 0, currency: .AUD)
        )
        _ = try? await backend.accounts.create(account)

        let category = Category(
          id: UUID(),
          name: "Groceries"
        )
        _ = try? await backend.categories.create(category)

        // Add some transactions
        for i in 0..<30 {
          _ = try? await backend.transactions.create(
            Transaction(
              id: UUID(),
              type: i % 2 == 0 ? .income : .expense,
              date: Date().addingTimeInterval(-86400 * Double(i)),
              accountId: account.id,
              amount: MonetaryAmount(
                cents: i % 2 == 0 ? Int.random(in: 10000...50000) : -Int.random(in: 5000...20000),
                currency: .AUD
              ),
              payee: "Transaction \(i)",
              categoryId: i % 3 == 0 ? category.id : nil
            ))
        }

        await categoryStore.load()
      }
  }
}
