import SwiftUI

struct UpcomingTransactionsCard: View {
  let accounts: Accounts
  let categories: Categories
  let earmarks: Earmarks
  let transactionStore: TransactionStore

  @State private var selectedTransaction: Transaction?

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Upcoming (Next 14 Days)")
        .font(.title2)
        .fontWeight(.semibold)

      if shortTermTransactions.isEmpty {
        emptyState
      } else {
        transactionList
      }
    }
    .padding()
    #if os(macOS)
      .background(Color(nsColor: .controlBackgroundColor))
    #else
      .background(Color(uiColor: .systemBackground))
    #endif
    .cornerRadius(12)
  }

  private var emptyState: some View {
    ContentUnavailableView(
      "No Upcoming Transactions",
      systemImage: "calendar",
      description: Text("No scheduled transactions due in the next 14 days.")
    )
    .frame(maxHeight: 200)
  }

  private var transactionList: some View {
    List(selection: $selectedTransaction) {
      ForEach(shortTermTransactions) { txn in
        SimpleTransactionRow(transaction: txn.transaction, earmarks: earmarks) {
          await payTransaction(txn.transaction)
        }
        .tag(txn.transaction)
        .contentShape(Rectangle())
      }
    }
    #if os(macOS)
      .listStyle(.inset)
    #else
      .listStyle(.plain)
    #endif
    .frame(height: 200)
    .accessibilityLabel("List of upcoming transactions in the next 14 days")
    .sheet(item: $selectedTransaction) { transaction in
      NavigationStack {
        TransactionDetailView(
          transaction: transaction,
          accounts: accounts,
          categories: categories,
          earmarks: earmarks,
          transactionStore: transactionStore,
          showRecurrence: true,
          onUpdate: { updated in
            Task { await transactionStore.update(updated) }
            selectedTransaction = nil
          },
          onDelete: { id in
            Task { await transactionStore.delete(id: id) }
            selectedTransaction = nil
          }
        )
        .toolbar {
          ToolbarItem(placement: .cancellationAction) {
            Button("Done") {
              selectedTransaction = nil
            }
          }
        }
      }
    }
  }

  private var shortTermTransactions: [TransactionWithBalance] {
    let twoWeeksFromNow = Calendar.current.date(byAdding: .day, value: 14, to: Date()) ?? Date()
    return transactionStore.transactions.filter { $0.transaction.date <= twoWeeksFromNow }
  }

  private func payTransaction(_ scheduledTransaction: Transaction) async {
    _ = await transactionStore.payScheduledTransaction(scheduledTransaction)
  }
}

private struct SimpleTransactionRow: View {
  let transaction: Transaction
  let earmarks: Earmarks
  let onPay: () async -> Void

  @State private var isPaying = false

  var body: some View {
    HStack(spacing: 12) {
      VStack(alignment: .leading, spacing: 4) {
        Text(displayPayee)
          .font(.body)
          .fontWeight(.medium)

        HStack(spacing: 8) {
          Text(transaction.date, format: .dateTime.month().day())
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()

          if let recurPeriod = transaction.recurPeriod,
            let recurEvery = transaction.recurEvery,
            recurPeriod != .once
          {
            Text("•")
              .foregroundStyle(.secondary)
            Text(recurPeriod.recurrenceDescription(every: recurEvery))
              .font(.caption)
              .foregroundStyle(.secondary)
              .accessibilityLabel(
                "Repeats \(recurPeriod.recurrenceDescription(every: recurEvery))")
          }
        }
      }

      Spacer()

      Text(
        transaction.amount.decimalValue,
        format: .currency(code: transaction.amount.currency.code)
      )
      .font(.body)
      .monospacedDigit()
      .foregroundStyle(transaction.amount.cents >= 0 ? .green : .red)

      Button {
        Task {
          isPaying = true
          await onPay()
          isPaying = false
        }
      } label: {
        if isPaying {
          ProgressView()
            .controlSize(.small)
        } else {
          Text("Pay")
        }
      }
      .buttonStyle(.borderedProminent)
      .controlSize(.small)
      .disabled(isPaying)
      .accessibilityLabel("Pay \(displayPayee)")
    }
    .padding(.vertical, 4)
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
    return "Unknown"
  }
}

#Preview {
  let backend = InMemoryBackend()
  let store = TransactionStore(repository: backend.transactions)

  UpcomingTransactionsCard(
    accounts: Accounts(from: []),
    categories: Categories(from: []),
    earmarks: Earmarks(from: []),
    transactionStore: store
  )
  .frame(width: 400)
  .padding()
  .task {
    let account = Account(
      id: UUID(),
      name: "Test Account",
      type: .bank,
      balance: MonetaryAmount(cents: 100000, currency: .AUD)
    )
    _ = try? await backend.accounts.create(account)

    _ = try? await backend.transactions.create(
      Transaction(
        id: UUID(),
        type: .expense,
        date: Date().addingTimeInterval(86400 * 2),
        accountId: account.id,
        amount: MonetaryAmount(cents: -5000, currency: .AUD),
        payee: "Utility Bill",
        recurPeriod: .month,
        recurEvery: 1
      ))

    _ = try? await backend.transactions.create(
      Transaction(
        id: UUID(),
        type: .income,
        date: Date().addingTimeInterval(86400 * 7),
        accountId: account.id,
        amount: MonetaryAmount(cents: 200000, currency: .AUD),
        payee: "Paycheck",
        recurPeriod: .week,
        recurEvery: 2
      ))

    await store.load(filter: TransactionFilter(scheduled: true))
  }
}
