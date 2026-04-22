import SwiftUI

struct AnalysisView: View {
  @Environment(AccountStore.self) private var accountStore
  @Environment(CategoryStore.self) private var categoryStore
  @Environment(EarmarkStore.self) private var earmarkStore
  @Environment(TransactionStore.self) private var transactionStore
  @Environment(ProfileSession.self) private var session
  @Environment(\.scenePhase) private var scenePhase

  @Bindable var store: AnalysisStore
  @State private var selectedUpcomingTransaction: Transaction?

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
    .transactionInspector(
      selectedTransaction: $selectedUpcomingTransaction,
      accounts: accountStore.accounts,
      categories: categoryStore.categories,
      earmarks: earmarkStore.earmarks,
      transactionStore: transactionStore,
      showRecurrence: true,
      supportsComplexTransactions: session.profile.supportsComplexTransactions
    )
    .profileNavigationTitle("Analysis")
    .focusedSceneValue(\.newTransactionAction, createNewScheduledTransaction)
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

      ToolbarItem(placement: .primaryAction) {
        Button {
          createNewScheduledTransaction()
        } label: {
          Label("Add Scheduled Transaction", systemImage: "plus")
        }
      }
    }
    .task {
      async let transactions: Void = transactionStore.load(
        filter: TransactionFilter(scheduled: true))
      async let analysis: Void = store.loadAll()
      _ = await (transactions, analysis)
    }
    .onChange(of: store.historyMonths) { _, _ in
      Task { await store.loadAll() }
    }
    .onChange(of: store.forecastMonths) { _, _ in
      Task { await store.loadAll() }
    }
    .onChange(of: scenePhase) { oldPhase, newPhase in
      // Only refresh when returning from the background (not from brief inactive
      // states like share sheets, system dialogs, or Command-Tab). Use a staleness
      // threshold to avoid disruptive reloads when the app has just been loaded.
      if oldPhase == .background && newPhase == .active {
        Task { await store.refreshIfStale(minimumInterval: 60) }
      }
    }
  }

  private func createNewScheduledTransaction() {
    let accounts = accountStore.accounts
    let instrument = accounts.ordered.first?.instrument ?? .AUD
    let fallbackAccountId = accounts.ordered.first?.id

    // Persist the placeholder directly so the returned transaction carries
    // the same UUID. The inspector's `.id(selected.id)` stays stable and
    // the detail view's focus state survives the create (see
    // `plans/2026-04-21-transaction-detail-focus-design.md`).
    let placeholder: Transaction? = fallbackAccountId.map { id in
      Transaction(
        date: Date(),
        payee: "",
        recurPeriod: .month,
        recurEvery: 1,
        legs: [TransactionLeg(accountId: id, instrument: instrument, quantity: 0, type: .expense)]
      )
    }
    selectedUpcomingTransaction = placeholder
    guard let placeholder else { return }
    Task {
      _ = await transactionStore.create(placeholder)
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
            transactionStore: transactionStore,
            selectedTransaction: $selectedUpcomingTransaction
          )
          IncomeExpenseTableCard(data: store.incomeAndExpense)
        }
      #else
        UpcomingTransactionsCard(
          accounts: accountStore.accounts,
          categories: categoryStore.categories,
          earmarks: earmarkStore.earmarks,
          transactionStore: transactionStore,
          selectedTransaction: $selectedUpcomingTransaction
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
        instrument: store.dailyBalances.first?.balance.instrument ?? .AUD,
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
  let (backend, _) = PreviewBackend.create()
  let accountStore = AccountStore(
    repository: backend.accounts,
    conversionService: backend.conversionService,
    targetInstrument: .AUD)
  let categoryStore = CategoryStore(repository: backend.categories)
  let earmarkStore = EarmarkStore(
    repository: backend.earmarks,
    conversionService: backend.conversionService,
    targetInstrument: .AUD)
  let transactionStore = TransactionStore(
    repository: backend.transactions,
    conversionService: backend.conversionService,
    targetInstrument: .AUD
  )
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
          instrument: .AUD
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
              date: Date().addingTimeInterval(-86400 * Double(i)),
              payee: "Transaction \(i)",
              legs: [
                TransactionLeg(
                  accountId: account.id,
                  instrument: .AUD,
                  quantity: i.isMultiple(of: 2)
                    ? Decimal(Int.random(in: 100...500)) : -Decimal(Int.random(in: 50...200)),
                  type: i.isMultiple(of: 2) ? .income : .expense,
                  categoryId: i.isMultiple(of: 3) ? category.id : nil
                )
              ]
            ))
        }

        await categoryStore.load()
      }
  }
}
