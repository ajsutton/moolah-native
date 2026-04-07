import SwiftUI

struct TransactionListView: View {
  let account: Account
  let accounts: Accounts
  let transactionStore: TransactionStore

  var body: some View {
    List {
      ForEach(transactionStore.transactions) { entry in
        TransactionRowView(transaction: entry.transaction, accounts: accounts, balance: entry.balance)
          .onAppear {
            if entry.id == transactionStore.transactions.last?.id {
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
  let savingsId = UUID()
  let account = Account(id: accountId, name: "Checking", type: .bank, balance: 244977)
  let accounts = Accounts(from: [
    account,
    Account(id: savingsId, name: "Savings", type: .bank, balance: 500000),
  ])
  let repository = InMemoryTransactionRepository(initialTransactions: [
    Transaction(
      type: .expense, date: Date(), accountId: accountId, amount: -5023, payee: "Woolworths"),
    Transaction(
      type: .income, date: Date().addingTimeInterval(-86400), accountId: accountId, amount: 350000,
      payee: "Employer"),
    Transaction(
      type: .transfer, date: Date().addingTimeInterval(-172800), accountId: accountId,
      toAccountId: savingsId, amount: -100000, payee: ""),
  ])
  let store = TransactionStore(repository: repository)

  NavigationStack {
    TransactionListView(account: account, accounts: accounts, transactionStore: store)
  }
}
