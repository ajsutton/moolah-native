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
          onUpdate: { updated in
            Task { await transactionStore.update(updated) }
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
    // Create a non-scheduled copy with today's date
    let paidTransaction = Transaction(
      id: UUID(),
      type: scheduledTransaction.type,
      date: Date(),
      accountId: scheduledTransaction.accountId,
      toAccountId: scheduledTransaction.toAccountId,
      amount: scheduledTransaction.amount,
      payee: scheduledTransaction.payee,
      notes: scheduledTransaction.notes,
      categoryId: scheduledTransaction.categoryId,
      earmarkId: scheduledTransaction.earmarkId,
      recurPeriod: nil,
      recurEvery: nil
    )

    _ = await transactionStore.create(paidTransaction)
  }
}

private struct UpcomingTransactionRow: View {
  let transaction: Transaction
  let accounts: Accounts
  let categories: Categories
  let earmarks: Earmarks
  let isOverdue: Bool
  let onPay: () -> Void

  var body: some View {
    HStack {
      VStack(alignment: .leading, spacing: 4) {
        Text(transaction.payee ?? "Untitled")
          .font(.headline)
          .foregroundStyle(isOverdue ? .red : .primary)

        HStack(spacing: 8) {
          Text(transaction.date, style: .date)
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()

          if let recurrence = recurrenceDescription {
            Text("•")
              .foregroundStyle(.secondary)
            Text(recurrence)
              .font(.caption)
              .foregroundStyle(.secondary)
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

      MonetaryAmountView(amount: transaction.amount, font: .headline)

      Button("Pay") {
        onPay()
      }
      .buttonStyle(.borderedProminent)
      .controlSize(.small)
      .accessibilityLabel("Pay \(transaction.payee ?? "transaction")")
    }
    .contentShape(Rectangle())
  }

  private var recurrenceDescription: String? {
    guard let period = transaction.recurPeriod,
      let every = transaction.recurEvery
    else {
      return nil
    }

    let periodName: String
    switch period {
    case "DAY":
      periodName = every == 1 ? "day" : "days"
    case "WEEK":
      periodName = every == 1 ? "week" : "weeks"
    case "MONTH":
      periodName = every == 1 ? "month" : "months"
    case "YEAR":
      periodName = every == 1 ? "year" : "years"
    default:
      return nil
    }

    return every == 1 ? "Every \(periodName)" : "Every \(every) \(periodName)"
  }
}

#Preview {
  let accountId = UUID()
  let categoryId = UUID()

  let accounts = Accounts(from: [
    Account(
      id: accountId, name: "Checking", type: .bank,
      balance: MonetaryAmount(cents: 244977, currency: Currency.defaultCurrency)
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
      amount: MonetaryAmount(cents: -200000, currency: Currency.defaultCurrency),
      payee: "Rent",
      categoryId: categoryId,
      recurPeriod: "MONTH",
      recurEvery: 1
    ),
    Transaction(
      type: .expense,
      date: upcoming,
      accountId: accountId,
      amount: MonetaryAmount(cents: -15000, currency: Currency.defaultCurrency),
      payee: "Internet",
      categoryId: categoryId,
      recurPeriod: "MONTH",
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
