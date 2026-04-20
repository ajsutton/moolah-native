import SwiftUI

/// Placeholder main content shown after sign-in. Replaced step-by-step with real screens.
struct ContentView: View {
  @Environment(AuthStore.self) private var authStore
  @Environment(ProfileSession.self) private var session
  @Environment(AccountStore.self) private var accountStore
  @Environment(TransactionStore.self) private var transactionStore
  @Environment(CategoryStore.self) private var categoryStore
  @Environment(EarmarkStore.self) private var earmarkStore
  @Environment(AnalysisStore.self) private var analysisStore
  @Environment(InvestmentStore.self) private var investmentStore
  @Environment(TradeStore.self) private var tradeStore
  @Environment(ReportingStore.self) private var reportingStore
  #if os(macOS)
    @State private var selection: SidebarSelection? = .analysis
  #else
    @State private var selection: SidebarSelection?
  #endif

  @Environment(\.pendingNavigation) private var pendingNavigationBinding
  @State private var showCreateEarmarkSheet = false

  var body: some View {
    NavigationSplitView {
      SidebarView(selection: $selection)
        .navigationSplitViewColumnWidth(min: 200, ideal: 280)
        .task {
          async let a: Void = accountStore.load()
          async let c: Void = categoryStore.load()
          async let e: Void = earmarkStore.load()
          _ = await (a, c, e)
        }
        .toolbar {
          #if os(iOS)
            ToolbarItem(placement: .automatic) {
              if case .signedIn = authStore.state {
                UserMenuView()
                  .environment(authStore)
              }
            }
          #endif
        }
    } detail: {
      switch selection {
      case .account(let id):
        if let account = accountStore.accounts.by(id: id) {
          if account.type == .investment {
            InvestmentAccountView(
              account: account,
              accounts: accountStore.accounts,
              categories: categoryStore.categories,
              earmarks: earmarkStore.earmarks,
              investmentStore: investmentStore,
              transactionStore: transactionStore)
          } else {
            TransactionListView(
              title: account.name,
              filter: TransactionFilter(accountId: account.id),
              accounts: accountStore.accounts,
              categories: categoryStore.categories,
              earmarks: earmarkStore.earmarks,
              transactionStore: transactionStore,
              positions: accountStore.positions(for: account.id),
              positionsHostCurrency: account.instrument,
              positionsTitle: account.name,
              conversionService: session.backend.conversionService)
          }
        }
      case .earmark(let id):
        if let earmark = earmarkStore.earmarks.by(id: id) {
          EarmarkDetailView(
            earmark: earmark,
            accounts: accountStore.accounts,
            categories: categoryStore.categories,
            earmarks: earmarkStore.earmarks,
            transactionStore: transactionStore,
            analysisRepository: analysisStore.repository)
        }
      case .allTransactions:
        TransactionListView(
          title: "All Transactions",
          filter: TransactionFilter(),
          accounts: accountStore.accounts,
          categories: categoryStore.categories,
          earmarks: earmarkStore.earmarks,
          transactionStore: transactionStore)
      case .upcomingTransactions:
        UpcomingView(
          accounts: accountStore.accounts,
          categories: categoryStore.categories,
          earmarks: earmarkStore.earmarks,
          transactionStore: transactionStore)
      case .categories:
        CategoriesView(categoryStore: categoryStore)
      case .reports:
        ReportsView(
          reportingStore: reportingStore,
          categories: categoryStore.categories,
          accounts: accountStore.accounts,
          earmarks: earmarkStore.earmarks,
          transactionStore: transactionStore)
      case .analysis:
        AnalysisView(store: analysisStore)
      case nil:
        ContentUnavailableView(
          "Select an Account", systemImage: "sidebar.left",
          description: Text("Choose an account from the sidebar to view transactions."))
      }
    }
    .navigationSplitViewStyle(.balanced)
    .safeAreaInset(edge: .top, spacing: 0) {
      SyncStatusBanner()
    }
    .focusedSceneValue(\.newEarmarkAction) {
      showCreateEarmarkSheet = true
    }
    .focusedSceneValue(\.refreshAction) {
      Task {
        async let a: Void = accountStore.load()
        async let c: Void = categoryStore.load()
        async let e: Void = earmarkStore.load()
        _ = await (a, c, e)
      }
    }
    .sheet(isPresented: $showCreateEarmarkSheet) {
      CreateEarmarkSheet(
        instrument: session.profile.instrument,
        supportsComplexTransactions: session.profile.supportsComplexTransactions,
        onCreate: { newEarmark in
          Task {
            _ = await earmarkStore.create(newEarmark)
            showCreateEarmarkSheet = false
          }
        }
      )
    }
    .onChange(of: pendingNavigationBinding?.wrappedValue) { _, newValue in
      if let navigation = newValue {
        applyNavigation(navigation.destination)
        pendingNavigationBinding?.wrappedValue = nil
      }
    }
  }

  private func applyNavigation(_ destination: URLSchemeHandler.Destination) {
    if let sidebarSelection = URLSchemeHandler.toSidebarSelection(destination) {
      selection = sidebarSelection
    }
    if case .analysis(let history, let forecast) = destination {
      if let history { analysisStore.historyMonths = history }
      if let forecast { analysisStore.forecastMonths = forecast }
    }
  }
}
