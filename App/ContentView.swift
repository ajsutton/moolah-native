import SwiftUI

/// Placeholder main content shown after sign-in. Replaced step-by-step with real screens.
struct ContentView: View {
  @Environment(AuthStore.self) private var authStore
  @Environment(AccountStore.self) private var accountStore
  @Environment(TransactionStore.self) private var transactionStore
  @Environment(CategoryStore.self) private var categoryStore
  @Environment(EarmarkStore.self) private var earmarkStore
  @State private var selection: SidebarSelection?

  var body: some View {
    NavigationSplitView {
      SidebarView(
        accountStore: accountStore, earmarkStore: earmarkStore, selection: $selection
      )
      .task {
        await accountStore.load()
        await categoryStore.load()
        await earmarkStore.load()
      }
      .toolbar {
        ToolbarItem(placement: .automatic) {
          if case .signedIn(let user) = authStore.state {
            UserMenuView(user: user)
              .environment(authStore)
          }
        }
      }
    } detail: {
      switch selection {
      case .account(let id):
        if let account = accountStore.accounts.by(id: id) {
          TransactionListView(
            title: account.name,
            filter: TransactionFilter(accountId: account.id),
            accounts: accountStore.accounts,
            categories: categoryStore.categories,
            earmarks: earmarkStore.earmarks,
            transactionStore: transactionStore)
        }
      case .earmark(let id):
        if let earmark = earmarkStore.earmarks.by(id: id) {
          EarmarkDetailView(
            earmark: earmark,
            accounts: accountStore.accounts,
            categories: categoryStore.categories,
            earmarks: earmarkStore.earmarks,
            transactionStore: transactionStore)
        }
      case .allTransactions:
        AllTransactionsView(
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
      case .earmarks:
        EarmarksView(
          earmarkStore: earmarkStore,
          accounts: accountStore.accounts,
          categories: categoryStore.categories,
          transactionStore: transactionStore)
      case nil:
        Text("Select an account")
      }
    }
  }
}
