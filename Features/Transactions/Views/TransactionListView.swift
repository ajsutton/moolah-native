import SwiftUI

struct TransactionListView: View {
  let title: String
  let filter: TransactionFilter
  let accounts: Accounts
  let categories: Categories
  let earmarks: Earmarks
  let transactionStore: TransactionStore

  @State private var showingNewTransaction = false
  @State private var selectedTransaction: Transaction?

  var body: some View {
    HStack(spacing: 0) {
      listView

      if let selected = selectedTransaction {
        Divider()

        TransactionDetailView(
          transaction: selected,
          accounts: accounts,
          categories: categories,
          earmarks: earmarks,
          onUpdate: { updated in
            Task { await transactionStore.update(updated) }
            // Update the selected transaction to reflect changes
            selectedTransaction = updated
          },
          onDelete: { id in
            Task { await transactionStore.delete(id: id) }
            selectedTransaction = nil
          }
        )
        .frame(width: 350)
      }
    }
  }

  private var listView: some View {
    List(selection: $selectedTransaction) {
      ForEach(transactionStore.transactions) { entry in
        TransactionRowView(
          transaction: entry.transaction, accounts: accounts,
          categories: categories, balance: entry.balance
        )
        .tag(entry.transaction)
        .contentShape(Rectangle())
        .swipeActions(edge: .trailing) {
          Button(role: .destructive) {
            Task {
              await transactionStore.delete(id: entry.transaction.id)
            }
          } label: {
            Label("Delete", systemImage: "trash")
          }
        }
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
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button {
          showingNewTransaction = true
        } label: {
          Label("Add Transaction", systemImage: "plus")
        }
      }
    }
    .sheet(isPresented: $showingNewTransaction) {
      TransactionFormView(
        accounts: accounts,
        categories: categories,
        earmarks: earmarks,
        onSave: { transaction in
          Task { await transactionStore.create(transaction) }
        }
      )
    }
    .task(id: filter) {
      // Clear selection when switching accounts
      selectedTransaction = nil
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
      earmarks: Earmarks(from: []),
      transactionStore: store)
  }
}
