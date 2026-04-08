import SwiftUI

struct TransactionListView: View {
  let title: String
  let filter: TransactionFilter
  let accounts: Accounts
  let categories: Categories
  let earmarks: Earmarks
  let transactionStore: TransactionStore

  @State private var selectedTransaction: Transaction?
  @State private var showError = false
  @State private var errorMessage = ""
  @State private var searchText = ""

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
        .id(selected.id)  // Force recreation when transaction changes
      }
    }
    .focusedSceneValue(\.newTransactionAction, createNewTransaction)
    .alert("Error", isPresented: $showError) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(errorMessage)
    }
    .task(id: transactionStore.error?.localizedDescription) {
      if let error = transactionStore.error {
        errorMessage = formatError(error)
        showError = true
      }
    }
  }

  private func formatError(_ error: Error) -> String {
    // Extract meaningful error messages
    if let backendError = error as? BackendError {
      switch backendError {
      case .serverError(let statusCode):
        return "Server error (\(statusCode)). Please try again."
      case .networkUnavailable:
        return "Network error. Check your connection."
      case .unauthenticated:
        return "Session expired. Please log in again."
      case .validationFailed(let message):
        return message
      case .notFound(let message):
        return message
      }
    }
    return "Operation failed: \(error.localizedDescription)"
  }

  private func createNewTransaction() {
    // Create a new transaction with default values
    let newTransaction = Transaction(
      type: .expense,
      date: Date(),
      accountId: filter.accountId ?? accounts.ordered.first?.id,
      amount: MonetaryAmount(cents: 0, currency: Currency.defaultCurrency),
      payee: ""
    )

    // Optimistically select it to show the detail panel immediately
    selectedTransaction = newTransaction

    // Create the transaction in the store and update selection with server-confirmed version
    Task {
      if let created = await transactionStore.create(newTransaction) {
        // Only update selection if it's still pointing to this transaction
        // (user might have created another transaction in the meantime)
        await MainActor.run {
          if selectedTransaction?.id == newTransaction.id {
            selectedTransaction = created
          }
        }
      }
    }
  }

  private var filteredTransactions: [TransactionWithBalance] {
    if searchText.isEmpty {
      return transactionStore.transactions
    }
    return transactionStore.transactions.filter {
      $0.transaction.payee?.localizedCaseInsensitiveContains(searchText) ?? false
    }
  }

  private var listView: some View {
    List(selection: $selectedTransaction) {
      ForEach(filteredTransactions) { entry in
        TransactionRowView(
          transaction: entry.transaction, accounts: accounts,
          categories: categories, earmarks: earmarks, balance: entry.balance,
          hideEarmark: filter.earmarkId != nil
        )
        .tag(entry.transaction)
        .contentShape(Rectangle())
        .contextMenu {
          Button("Edit", systemImage: "pencil") {
            selectedTransaction = entry.transaction
          }
          Divider()
          Button("Delete", systemImage: "trash", role: .destructive) {
            Task {
              await transactionStore.delete(id: entry.transaction.id)
            }
          }
        }
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
    #if os(macOS)
      .listStyle(.inset)
    #else
      .listStyle(.plain)
    #endif
    .navigationTitle(title)
    .toolbar {
      ToolbarItem(placement: .automatic) {
        Button {
          Task {
            await transactionStore.load(filter: filter)
          }
        } label: {
          Label("Refresh", systemImage: "arrow.clockwise")
        }
        .keyboardShortcut("r", modifiers: .command)
      }

      ToolbarItem(placement: .primaryAction) {
        Button {
          createNewTransaction()
        } label: {
          Label("Add Transaction", systemImage: "plus")
        }
        .keyboardShortcut("n", modifiers: .command)
      }
    }
    .task(id: filter) {
      // Clear selection when switching accounts
      selectedTransaction = nil
      await transactionStore.load(filter: filter)
    }
    .refreshable {
      await transactionStore.load(filter: filter)
    }
    .searchable(text: $searchText, prompt: "Search payee")
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
