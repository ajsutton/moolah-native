import SwiftData
import SwiftUI

struct TransactionListView: View {
  let title: String
  let filter: TransactionFilter
  let accounts: Accounts
  let categories: Categories
  let earmarks: Earmarks
  let transactionStore: TransactionStore

  @State private var selectedTransaction: Transaction?

  private var showInspectorBinding: Binding<Bool> {
    Binding(
      get: { selectedTransaction != nil },
      set: { if !$0 { selectedTransaction = nil } }
    )
  }

  @State private var showError = false
  @State private var errorMessage = ""
  @State private var searchText = ""

  var body: some View {
    listView
      #if os(macOS)
        .inspector(isPresented: showInspectorBinding) {
          if let selected = selectedTransaction {
            TransactionDetailView(
              transaction: selected,
              accounts: accounts,
              categories: categories,
              earmarks: earmarks,
              transactionStore: transactionStore,
              onUpdate: { updated in
                Task { await transactionStore.update(updated) }
                selectedTransaction = updated
              },
              onDelete: { id in
                Task { await transactionStore.delete(id: id) }
                selectedTransaction = nil
              }
            )
            .id(selected.id)
          }
        }
      #else
        .sheet(item: $selectedTransaction) { selected in
          NavigationStack {
            TransactionDetailView(
              transaction: selected,
              accounts: accounts,
              categories: categories,
              earmarks: earmarks,
              transactionStore: transactionStore,
              onUpdate: { updated in
                Task { await transactionStore.update(updated) }
                selectedTransaction = updated
              },
              onDelete: { id in
                Task { await transactionStore.delete(id: id) }
                selectedTransaction = nil
              }
            )
            .toolbar {
              ToolbarItem(placement: .confirmationAction) {
                Button("Done") {
                  selectedTransaction = nil
                }
              }
            }
          }
        }
      #endif
      .focusedSceneValue(\.newTransactionAction, createNewTransaction)
      .alert("Error", isPresented: $showError) {
        Button("OK", role: .cancel) {}
      } message: {
        Text(errorMessage)
      }
      .task(id: transactionStore.error?.localizedDescription) {
        if let error = transactionStore.error {
          errorMessage = error.userMessage
          showError = true
        }
      }
  }

  private func createNewTransaction() {
    let currency = accounts.ordered.first?.balance.currency ?? .AUD

    // Create a placeholder for optimistic selection while the store creates it
    let placeholder = Transaction(
      type: .expense,
      date: Date(),
      accountId: filter.accountId ?? accounts.ordered.first?.id,
      amount: MonetaryAmount(cents: 0, currency: currency),
      payee: ""
    )
    selectedTransaction = placeholder

    // Create the transaction in the store and update selection with server-confirmed version
    Task {
      if let created = await transactionStore.createDefault(
        accountId: filter.accountId,
        fallbackAccountId: accounts.ordered.first?.id,
        currency: currency
      ) {
        if selectedTransaction?.id == placeholder.id {
          selectedTransaction = created
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
          if let total = transactionStore.totalCount, total > 0 {
            VStack(spacing: 4) {
              ProgressView(value: Double(transactionStore.loadedCount), total: Double(total))
                .frame(maxWidth: 200)
              Text("Loading \(transactionStore.loadedCount) of \(total)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            }
          } else {
            ProgressView()
          }
          Spacer()
        }
      }
    }
    #if os(macOS)
      .listStyle(.inset)
    #else
      .listStyle(.plain)
    #endif
    .profileNavigationTitle(title)
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
    balance: MonetaryAmount(cents: 244977, currency: Currency.AUD))
  let accounts = Accounts(from: [
    account,
    Account(
      id: savingsId, name: "Savings", type: .bank,
      balance: MonetaryAmount(cents: 500000, currency: Currency.AUD)),
  ])
  let (backend, _) = PreviewBackend.create()
  let store = TransactionStore(repository: backend.transactions)

  NavigationStack {
    TransactionListView(
      title: account.name, filter: TransactionFilter(accountId: accountId),
      accounts: accounts, categories: Categories(from: []),
      earmarks: Earmarks(from: []),
      transactionStore: store)
  }
  .task {
    _ = try? await backend.transactions.create(
      Transaction(
        type: .expense, date: Date(), accountId: accountId,
        amount: MonetaryAmount(cents: -5023, currency: Currency.AUD),
        payee: "Woolworths"))
    _ = try? await backend.transactions.create(
      Transaction(
        type: .income, date: Date().addingTimeInterval(-86400), accountId: accountId,
        amount: MonetaryAmount(cents: 350000, currency: Currency.AUD),
        payee: "Employer"))
    _ = try? await backend.transactions.create(
      Transaction(
        type: .transfer, date: Date().addingTimeInterval(-172800), accountId: accountId,
        toAccountId: savingsId,
        amount: MonetaryAmount(cents: -100000, currency: Currency.AUD), payee: ""))
    await store.load(filter: TransactionFilter(accountId: accountId))
  }
}
