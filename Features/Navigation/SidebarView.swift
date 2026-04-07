import SwiftUI

enum SidebarSelection: Hashable {
  case account(UUID)
  case categories
}

struct SidebarView: View {
  let accountStore: AccountStore
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
          MonetaryAmountView(amount: accountStore.availableFunds)
        }
        .font(.headline)

        LabeledContent("Net Worth") {
          MonetaryAmountView(amount: accountStore.netWorth)
        }
        .font(.headline)
        .bold()
      }

      Section {
        NavigationLink(value: SidebarSelection.categories) {
          Label("Categories", systemImage: "tag")
        }
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
    ]))
  let accountStore = AccountStore(repository: backend.accounts)

  NavigationSplitView {
    SidebarView(accountStore: accountStore, selection: .constant(nil))
      .task {
        await accountStore.load()
      }
  } detail: {
    Text("Detail")
  }
}
