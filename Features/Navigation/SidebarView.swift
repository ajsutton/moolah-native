import SwiftUI

enum SidebarSelection: Hashable {
  case account(UUID)
  case earmark(UUID)
  case allTransactions
  case upcomingTransactions
  case categories
  case earmarks
}

struct SidebarView: View {
  let accountStore: AccountStore
  let earmarkStore: EarmarkStore
  @Binding var selection: SidebarSelection?

  var body: some View {
    List(selection: $selection) {
      Section("Current Accounts") {
        ForEach(accountStore.currentAccounts) { account in
          NavigationLink(value: SidebarSelection.account(account.id)) {
            AccountRowView(account: account)
          }
        }

        totalRow(label: "Current Total", value: accountStore.currentTotal)
      }

      if !earmarkStore.visibleEarmarks.isEmpty {
        Section("Earmarks") {
          ForEach(earmarkStore.visibleEarmarks) { earmark in
            NavigationLink(value: SidebarSelection.earmark(earmark.id)) {
              EarmarkRowView(earmark: earmark)
            }
          }

          totalRow(label: "Earmarked Total", value: earmarkStore.totalBalance)
        }
      }

      Section("Investments") {
        ForEach(accountStore.investmentAccounts) { account in
          NavigationLink(value: SidebarSelection.account(account.id)) {
            AccountRowView(account: account)
          }
        }

        totalRow(label: "Investment Total", value: accountStore.investmentTotal)
      }

      Section {
        LabeledContent("Available Funds") {
          MonetaryAmountView(amount: availableFunds)
        }
        .font(.headline)

        LabeledContent("Net Worth") {
          MonetaryAmountView(amount: accountStore.netWorth)
        }
        .font(.headline)
        .bold()
      }

      Section {
        NavigationLink(value: SidebarSelection.allTransactions) {
          Label("All Transactions", systemImage: "list.bullet")
        }

        NavigationLink(value: SidebarSelection.upcomingTransactions) {
          Label("Upcoming", systemImage: "calendar")
        }

        NavigationLink(value: SidebarSelection.categories) {
          Label("Categories", systemImage: "tag")
        }

        NavigationLink(value: SidebarSelection.earmarks) {
          Label("Manage Earmarks", systemImage: "folder")
        }
      }
    }
    .listStyle(.sidebar)
    .navigationTitle("Moolah")
    .refreshable {
      await accountStore.load()
      await earmarkStore.load()
    }
  }

  /// Current account total minus the sum of positive earmark balances.
  private var availableFunds: MonetaryAmount {
    let earmarked = earmarkStore.visibleEarmarks
      .filter { $0.balance.isPositive }
      .reduce(MonetaryAmount.zero) { $0 + $1.balance }
    return accountStore.currentTotal - earmarked
  }

  private func totalRow(label: String, value: MonetaryAmount) -> some View {
    LabeledContent(label) {
      MonetaryAmountView(amount: value, colorOverride: .secondary)
    }
    .foregroundStyle(.secondary)
    .font(.callout)
  }
}

#Preview {
  let backend = InMemoryBackend(
    accounts: InMemoryAccountRepository(initialAccounts: [
      Account(
        name: "Bank", type: .bank,
        balance: MonetaryAmount(cents: 100000, currency: Currency.defaultCurrency)),
      Account(
        name: "Asset", type: .asset,
        balance: MonetaryAmount(cents: 500000, currency: Currency.defaultCurrency)),
      Account(
        name: "Credit Card", type: .creditCard,
        balance: MonetaryAmount(cents: -50000, currency: Currency.defaultCurrency)),
      Account(
        name: "Investment", type: .investment,
        balance: MonetaryAmount(cents: 2_000_000, currency: Currency.defaultCurrency)),
    ]),
    earmarks: InMemoryEarmarkRepository(initialEarmarks: [
      Earmark(
        name: "Holiday Fund",
        balance: MonetaryAmount(cents: 150000, currency: Currency.defaultCurrency)),
      Earmark(
        name: "Emergency Fund",
        balance: MonetaryAmount(cents: 300000, currency: Currency.defaultCurrency)),
    ]))
  let accountStore = AccountStore(repository: backend.accounts)
  let earmarkStore = EarmarkStore(repository: backend.earmarks)

  NavigationSplitView {
    SidebarView(
      accountStore: accountStore, earmarkStore: earmarkStore, selection: .constant(nil)
    )
    .task {
      await accountStore.load()
      await earmarkStore.load()
    }
  } detail: {
    Text("Detail")
  }
}
