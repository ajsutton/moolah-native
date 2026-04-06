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
            }
            
            Section("Earmarked Funds") {
                ForEach(accountStore.earmarkAccounts) { account in
                    NavigationLink(value: account.id) {
                        AccountRowView(account: account)
                    }
                }
            }
            
            Section("Investments") {
                ForEach(accountStore.investmentAccounts) { account in
                    NavigationLink(value: account.id) {
                        AccountRowView(account: account)
                    }
                }
            }
            
            Section("Totals") {
                LabeledContent("Current Total", value: Decimal(accountStore.currentTotal) / 100, format: .currency(code: Constants.defaultCurrency))
                LabeledContent("Earmarked Total", value: Decimal(accountStore.earmarkedTotal) / 100, format: .currency(code: Constants.defaultCurrency))
                LabeledContent("Investment Total", value: Decimal(accountStore.investmentTotal) / 100, format: .currency(code: Constants.defaultCurrency))
                Divider()
                LabeledContent("Net Worth", value: Decimal(accountStore.netWorth) / 100, format: .currency(code: Constants.defaultCurrency))
                    .bold()
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Moolah")
        .refreshable {
            await accountStore.load()
        }
    }
}

#Preview {
    let backend = InMemoryBackend(accounts: InMemoryAccountRepository(initialAccounts: [
        Account(name: "Checking", type: .checking, balance: 100000),
        Account(name: "Savings", type: .savings, balance: 500000),
        Account(name: "Credit Card", type: .creditCard, balance: -50000),
        Account(name: "Investment", type: .investment, balance: 2000000),
        Account(name: "House Fund", type: .earmark, balance: 300000)
    ]))
    let store = AccountStore(repository: backend.accounts)
    
    NavigationSplitView {
        SidebarView(accountStore: store, selection: .constant(nil))
            .task { await store.load() }
    } detail: {
        Text("Detail")
    }
}
