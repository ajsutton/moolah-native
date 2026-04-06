import SwiftUI

/// Placeholder main content shown after sign-in. Replaced step-by-step with real screens.
struct ContentView: View {
  @Environment(AuthStore.self) private var authStore
  @Environment(AccountStore.self) private var accountStore
  @Environment(TransactionStore.self) private var transactionStore
  @State private var selection: UUID?

  var body: some View {
    NavigationSplitView {
      SidebarView(accountStore: accountStore, selection: $selection)
        .task { await accountStore.load() }
        .toolbar {
          ToolbarItem(placement: .automatic) {
            if case .signedIn(let user) = authStore.state {
              UserMenuView(user: user)
                .environment(authStore)
            }
          }
        }
    } detail: {
      if let selection, let account = accountStore.accounts.by(id: selection) {
        TransactionListView(
          account: account, accounts: accountStore.accounts, transactionStore: transactionStore)
      } else {
        Text("Select an account")
      }
    }
  }
}
