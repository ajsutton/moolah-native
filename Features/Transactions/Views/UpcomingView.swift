import SwiftUI

struct UpcomingView: View {
  let accounts: Accounts
  let categories: Categories
  let earmarks: Earmarks
  let transactionStore: TransactionStore

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
          transactionStore: transactionStore,
          showRecurrence: true,
          onUpdate: { updated in
            Task { await transactionStore.update(updated) }
            selectedTransaction = updated
          },
          onDelete: { id in
            Task { await transactionStore.delete(id: id) }
            selectedTransaction = nil
          }
        )
        .frame(width: UIConstants.detailPanelWidth)
      }
    }
  }

  private var listView: some View {
    List(selection: $selectedTransaction) {
      if !overdueTransactions.isEmpty {
        Section("Overdue") {
          ForEach(overdueTransactions) { entry in
            UpcomingTransactionRow(
              transaction: entry.transaction,
              accounts: accounts,
              categories: categories,
              earmarks: earmarks,
              isOverdue: true,
              onPay: {
                Task {
                  await payTransaction(entry.transaction)
                }
              }
            )
            .tag(entry.transaction)
            .contextMenu {
              Button("Pay Now", systemImage: "checkmark.circle") {
                Task { await payTransaction(entry.transaction) }
              }
              Button("Edit", systemImage: "pencil") {
                selectedTransaction = entry.transaction
              }
              Divider()
              Button("Delete", systemImage: "trash", role: .destructive) {
                Task { await transactionStore.delete(id: entry.transaction.id) }
              }
            }
            .swipeActions(edge: .trailing) {
              Button(role: .destructive) {
                Task { await transactionStore.delete(id: entry.transaction.id) }
              } label: {
                Label("Delete", systemImage: "trash")
              }
            }
            .swipeActions(edge: .leading) {
              Button {
                Task { await payTransaction(entry.transaction) }
              } label: {
                Label("Pay", systemImage: "checkmark.circle")
              }
              .tint(.green)
            }
          }
        }
      }

      if !upcomingTransactions.isEmpty {
        Section("Upcoming") {
          ForEach(upcomingTransactions) { entry in
            UpcomingTransactionRow(
              transaction: entry.transaction,
              accounts: accounts,
              categories: categories,
              earmarks: earmarks,
              isOverdue: false,
              onPay: {
                Task {
                  await payTransaction(entry.transaction)
                }
              }
            )
            .tag(entry.transaction)
            .contextMenu {
              Button("Pay Now", systemImage: "checkmark.circle") {
                Task { await payTransaction(entry.transaction) }
              }
              Button("Edit", systemImage: "pencil") {
                selectedTransaction = entry.transaction
              }
              Divider()
              Button("Delete", systemImage: "trash", role: .destructive) {
                Task { await transactionStore.delete(id: entry.transaction.id) }
              }
            }
            .swipeActions(edge: .trailing) {
              Button(role: .destructive) {
                Task { await transactionStore.delete(id: entry.transaction.id) }
              } label: {
                Label("Delete", systemImage: "trash")
              }
            }
            .swipeActions(edge: .leading) {
              Button {
                Task { await payTransaction(entry.transaction) }
              } label: {
                Label("Pay", systemImage: "checkmark.circle")
              }
              .tint(.green)
            }
          }
        }
      }
    }
    .navigationTitle("Upcoming")
    .task {
      await transactionStore.load(filter: TransactionFilter(scheduled: true))
    }
    .refreshable {
      await transactionStore.load(filter: TransactionFilter(scheduled: true))
    }
    .overlay {
      if !transactionStore.isLoading && transactionStore.transactions.isEmpty {
        ContentUnavailableView(
          "No Scheduled Transactions",
          systemImage: "calendar",
          description: Text("Create a recurring transaction to see it here.")
        )
      }
    }
  }

  private var overdueTransactions: [TransactionWithBalance] {
    transactionStore.transactions.filter { isOverdue($0.transaction) }
  }

  private var upcomingTransactions: [TransactionWithBalance] {
    transactionStore.transactions.filter { !isOverdue($0.transaction) }
  }

  private func isOverdue(_ transaction: Transaction) -> Bool {
    transaction.date < Date()
  }

  private func payTransaction(_ scheduledTransaction: Transaction) async {
    let result = await transactionStore.payScheduledTransaction(scheduledTransaction)
    switch result {
    case .paid(let updated):
      selectedTransaction = updated
    case .deleted:
      selectedTransaction = nil
    case .failed:
      break
    }
  }
}

struct UpcomingTransactionRow: View {
  let transaction: Transaction
  let accounts: Accounts
  let categories: Categories
  let earmarks: Earmarks
  let isOverdue: Bool
  let onPay: () -> Void

  var body: some View {
    HStack {
      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 4) {
          if isOverdue {
            Image(systemName: "exclamationmark.triangle.fill")
              .foregroundStyle(.red)
              .imageScale(.small)
              .accessibilityLabel("Overdue")
          }
          Text(displayPayee)
            .font(.headline)
            .foregroundStyle(isOverdue ? .red : .primary)
        }

        HStack(spacing: 4) {
          Text(transaction.date, format: .dateTime.day().month(.abbreviated).year())
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()

          if let recurrence = recurrenceDescription {
            Text("•")
              .foregroundStyle(.secondary)
            Text(recurrence)
              .font(.caption)
              .foregroundStyle(.secondary)
              .accessibilityLabel("Repeats \(recurrence)")
          }

          if let categoryId = transaction.categoryId,
            let category = categories.by(id: categoryId)
          {
            Text("•")
              .foregroundStyle(.secondary)
            Text(category.name)
              .font(.caption)
              .foregroundStyle(.secondary)
          }

          if let earmarkId = transaction.earmarkId,
            let earmark = earmarks.by(id: earmarkId)
          {
            Text("•")
              .foregroundStyle(.secondary)
            Text(earmark.name)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
      }

      Spacer()

      MonetaryAmountView(amount: transaction.amount, font: .body)

      Button("Pay") {
        onPay()
      }
      #if os(iOS)
        .buttonStyle(.borderedProminent)
        .controlSize(.regular)
      #else
        .buttonStyle(.bordered)
        .controlSize(.small)
      #endif
      .accessibilityLabel("Pay \(transaction.payee ?? "transaction")")
    }
    .contentShape(Rectangle())
  }

  private var displayPayee: String {
    if let payee = transaction.payee, !payee.isEmpty {
      return payee
    }
    if let earmarkId = transaction.earmarkId,
      let earmark = earmarks.by(id: earmarkId)
    {
      return "Earmark funds for \(earmark.name)"
    }
    return "Untitled"
  }

  private var recurrenceDescription: String? {
    guard let period = transaction.recurPeriod,
      let every = transaction.recurEvery,
      period != .once
    else {
      return nil
    }
    return period.recurrenceDescription(every: every)
  }
}

#Preview {
  let accountId = UUID()
  let categoryId = UUID()

  let accounts = Accounts(from: [
    Account(
      id: accountId, name: "Checking", type: .bank,
      balance: MonetaryAmount(cents: 244977, currency: Currency.AUD)
    )
  ])

  let categories = Categories(from: [
    Category(id: categoryId, name: "Rent", parentId: nil)
  ])

  let today = Date()
  let calendar = Calendar.current
  let overdue = calendar.date(byAdding: .day, value: -5, to: today)!
  let upcoming = calendar.date(byAdding: .day, value: 5, to: today)!

  let repository = InMemoryTransactionRepository(initialTransactions: [
    Transaction(
      type: .expense,
      date: overdue,
      accountId: accountId,
      amount: MonetaryAmount(cents: -200000, currency: Currency.AUD),
      payee: "Rent",
      categoryId: categoryId,
      recurPeriod: .month,
      recurEvery: 1
    ),
    Transaction(
      type: .expense,
      date: upcoming,
      accountId: accountId,
      amount: MonetaryAmount(cents: -15000, currency: Currency.AUD),
      payee: "Internet",
      categoryId: categoryId,
      recurPeriod: .month,
      recurEvery: 1
    ),
  ])

  let store = TransactionStore(repository: repository)

  NavigationStack {
    UpcomingView(
      accounts: accounts,
      categories: categories,
      earmarks: Earmarks(from: []),
      transactionStore: store
    )
  }
}
