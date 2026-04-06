import SwiftUI

struct TransactionListView: View {
    let account: Account
    let transactionStore: TransactionStore

    var body: some View {
        List {
            ForEach(transactionStore.transactions) { transaction in
                TransactionRowView(transaction: transaction)
                    .onAppear {
                        if transaction.id == transactionStore.transactions.last?.id {
                            Task {
                                await transactionStore.loadMore()
                            }
                        }
                    }
            }

            if transactionStore.isLoading {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
            }
        }
        .navigationTitle(account.name)
        .task(id: account.id) {
            await transactionStore.load(filter: TransactionFilter(accountId: account.id))
        }
        .refreshable {
            await transactionStore.load(filter: TransactionFilter(accountId: account.id))
        }
        .overlay {
            if !transactionStore.isLoading && transactionStore.transactions.isEmpty {
                ContentUnavailableView(
                    "No Transactions",
                    systemImage: "tray",
                    description: Text("This account has no transactions yet.")
                )
            }
        }
    }
}

#Preview {
    let accountId = UUID()
    let account = Account(id: accountId, name: "Checking", type: .bank, balance: 100000)
    let repository = InMemoryTransactionRepository(initialTransactions: [
        Transaction(type: .expense, date: Date(), accountId: accountId, amount: -5023, payee: "Woolworths"),
        Transaction(type: .income, date: Date().addingTimeInterval(-86400), accountId: accountId, amount: 350000, payee: "Employer"),
        Transaction(type: .transfer, date: Date().addingTimeInterval(-172800), accountId: accountId, toAccountId: UUID(), amount: -100000, payee: "To Savings"),
    ])
    let store = TransactionStore(repository: repository)

    NavigationStack {
        TransactionListView(account: account, transactionStore: store)
    }
}
