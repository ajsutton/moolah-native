import SwiftUI

/// Placeholder main content shown after sign-in. Replaced step-by-step with real screens.
struct ContentView: View {
  @Environment(AuthStore.self) private var authStore
  @Environment(AccountStore.self) private var accountStore
  @Environment(TransactionStore.self) private var transactionStore
  @Environment(CategoryStore.self) private var categoryStore
  @Environment(EarmarkStore.self) private var earmarkStore
  @Environment(AnalysisStore.self) private var analysisStore
  @Environment(InvestmentStore.self) private var investmentStore
  @Environment(TradeStore.self) private var tradeStore
  @State private var selection: SidebarSelection? = .analysis

  @State private var showCreateEarmarkSheet = false

  var body: some View {
    NavigationSplitView {
      SidebarView(selection: $selection)
        .task {
          async let a: Void = accountStore.load()
          async let c: Void = categoryStore.load()
          async let e: Void = earmarkStore.load()
          _ = await (a, c, e)
        }
        .toolbar {
          #if os(iOS)
            ToolbarItem(placement: .automatic) {
              if case .signedIn(let user) = authStore.state {
                UserMenuView(user: user)
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
              transactionStore: transactionStore,
              tradeStore: tradeStore)
          } else {
            TransactionListView(
              title: account.name,
              filter: TransactionFilter(accountId: account.id),
              accounts: accountStore.accounts,
              categories: categoryStore.categories,
              earmarks: earmarkStore.earmarks,
              transactionStore: transactionStore,
              positions: accountStore.positions(for: account.id))
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
          analysisRepository: analysisStore.repository,
          categories: categoryStore.categories,
          accounts: accountStore.accounts,
          earmarks: earmarkStore.earmarks,
          transactionStore: transactionStore)
      case .analysis:
        AnalysisView(store: analysisStore)
      case nil:
        Text("Select an account")
      }
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
        instrument: accountStore.currentTotal.instrument,
        onCreate: { newEarmark in
          Task {
            _ = await earmarkStore.create(newEarmark)
            showCreateEarmarkSheet = false
          }
        }
      )
    }
  }
}
