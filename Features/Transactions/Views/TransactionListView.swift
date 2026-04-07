import SwiftUI

struct TransactionListView: View {
  let title: String
  let filter: TransactionFilter
  let accounts: Accounts
  let categories: Categories
  let transactionStore: TransactionStore

  var body: some View {
    List {
      ForEach(transactionStore.transactions) { entry in
        TransactionRowView(
          transaction: entry.transaction, accounts: accounts,
          categories: categories, balance: entry.balance
        )
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
    .navigationTitle(title)
    .task(id: filter) {
      await transactionStore.load(filter: filter)
    }
    .refreshable {
      await transactionStore.load(filter: filter)
    }
    .overlay {
      if !transactionStore.isLoading && transactionStore.transactions.isEmpty {
        ContentUnavailableView(
          "No Transactions",
          systemImage: "tray",
          description: Text("No transactions found.")
        )
      }
    }
  }
}

#Preview {
  let accountId = UUID()
  let savingsId = UUID()
  let account = Account(
    id: accountId, name: "Checking", type: .bank,
    balance: MonetaryAmount(cents: 244977, currency: Currency.defaultCurrency))
  let accounts = Accounts(from: [
    account,
    Account(
      id: savingsId, name: "Savings", type: .bank,
      balance: MonetaryAmount(cents: 500000, currency: Currency.defaultCurrency)),
  ])
  let repository = InMemoryTransactionRepository(initialTransactions: [
    Transaction(
      type: .expense, date: Date(), accountId: accountId,
      amount: MonetaryAmount(cents: -5023, currency: Currency.defaultCurrency),
      payee: "Woolworths"),
    Transaction(
      type: .income, date: Date().addingTimeInterval(-86400), accountId: accountId,
      amount: MonetaryAmount(cents: 350000, currency: Currency.defaultCurrency),
      payee: "Employer"),
    Transaction(
      type: .transfer, date: Date().addingTimeInterval(-172800), accountId: accountId,
      toAccountId: savingsId,
      amount: MonetaryAmount(cents: -100000, currency: Currency.defaultCurrency), payee: ""),
  ])
  let store = TransactionStore(repository: repository)

  NavigationStack {
    TransactionListView(
      title: account.name, filter: TransactionFilter(accountId: accountId),
      accounts: accounts, categories: Categories(from: []),
      transactionStore: store)
  }
}
