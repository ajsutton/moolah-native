import SwiftUI

struct SidebarView: View {
  let accountStore: AccountStore
  @Binding var selection: UUID?

  var body: some View {
    List(selection: $selection) {
      Section("Current Accounts") {
        ForEach(accountStore.currentAccounts) { account in
          NavigationLink(value: account.id) {
            AccountRowView(account: account)
          }
        }

        totalRow(label: "Current Total", value: accountStore.currentTotal)
      }

      Section("Investments") {
        ForEach(accountStore.investmentAccounts) { account in
          NavigationLink(value: account.id) {
            AccountRowView(account: account)
          }
        }

        totalRow(label: "Investment Total", value: accountStore.investmentTotal)
      }

      Section {
        LabeledContent("Available Funds") {
          MonetaryAmountView(amount: accountStore.availableFunds)
        }
        .font(.headline)

        LabeledContent("Net Worth") {
          MonetaryAmountView(amount: accountStore.netWorth)
        }
        .font(.headline)
        .bold()
      }
    }
    .listStyle(.sidebar)
    .navigationTitle("Moolah")
    .refreshable {
      await accountStore.load()
    }
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
      Account(name: "Bank", type: .bank, balance: MonetaryAmount(cents: 100000)),
      Account(name: "Asset", type: .asset, balance: MonetaryAmount(cents: 500000)),
      Account(name: "Credit Card", type: .creditCard, balance: MonetaryAmount(cents: -50000)),
      Account(name: "Investment", type: .investment, balance: MonetaryAmount(cents: 2_000_000)),
    ]))
  let store = AccountStore(repository: backend.accounts)

  NavigationSplitView {
    SidebarView(accountStore: store, selection: .constant(nil))
      .task { await store.load() }
  } detail: {
    Text("Detail")
  }
}
