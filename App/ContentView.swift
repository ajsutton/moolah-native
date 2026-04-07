import SwiftUI

/// Placeholder main content shown after sign-in. Replaced step-by-step with real screens.
struct ContentView: View {
  @Environment(AuthStore.self) private var authStore
  @Environment(AccountStore.self) private var accountStore
  @Environment(TransactionStore.self) private var transactionStore
  @Environment(CategoryStore.self) private var categoryStore
  @State private var selection: SidebarSelection?

  var body: some View {
    NavigationSplitView {
      SidebarView(accountStore: accountStore, selection: $selection)
        .task {
          await accountStore.load()
          await categoryStore.load()
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
            account: account, accounts: accountStore.accounts,
            categories: categoryStore.categories, transactionStore: transactionStore)
        }
      case .categories:
        CategoryTreeView(categoryStore: categoryStore)
      case nil:
        Text("Select an account")
      }
    }
  }
}
