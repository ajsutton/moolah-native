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
            
            if !accountStore.earmarkAccounts.isEmpty {
                Section("Earmarked Funds") {
                    ForEach(accountStore.earmarkAccounts) { account in
                        NavigationLink(value: account.id) {
                            AccountRowView(account: account)
                        }
                    }
                    
                    totalRow(label: "Earmarked Total", value: accountStore.earmarkedTotal)
                }
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
                LabeledContent("Available Funds", value: Decimal(accountStore.availableFunds) / 100, format: .currency(code: Constants.defaultCurrency))
                    .font(.headline)
                
                LabeledContent("Net Worth", value: Decimal(accountStore.netWorth) / 100, format: .currency(code: Constants.defaultCurrency))
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
    
    private func totalRow(label: String, value: Int) -> some View {
        LabeledContent(label, value: Decimal(value) / 100, format: .currency(code: Constants.defaultCurrency))
            .foregroundStyle(.secondary)
            .font(.callout)
    }
}

#Preview {
    let backend = InMemoryBackend(accounts: InMemoryAccountRepository(initialAccounts: [
        Account(name: "Bank", type: .bank, balance: 100000),
        Account(name: "Asset", type: .asset, balance: 500000),
        Account(name: "Credit Card", type: .creditCard, balance: -50000),
        Account(name: "Investment", type: .investment, balance: 2000000),
    ]))
    let store = AccountStore(repository: backend.accounts)
    
    NavigationSplitView {
        SidebarView(accountStore: store, selection: .constant(nil))
            .task { await store.load() }
    } detail: {
        Text("Detail")
    }
}
