import SwiftUI

struct UpcomingTransactionsCard: View {
  let transactionStore: TransactionStore

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
    Text("No upcoming transactions")
      .foregroundStyle(.secondary)
      .frame(maxWidth: .infinity, alignment: .center)
      .padding(.vertical, 20)
  }

  private var transactionList: some View {
    List {
      ForEach(shortTermTransactions) { txn in
        SimpleTransactionRow(transaction: txn.transaction) {
          await payTransaction(txn.transaction)
        }
      }
    }
    .listStyle(.plain)
    .frame(height: 200)
    .accessibilityLabel("List of upcoming transactions in the next 14 days")
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
  let onPay: () async -> Void

  @State private var isPaying = false

  var body: some View {
    HStack(spacing: 12) {
      VStack(alignment: .leading, spacing: 4) {
        Text(transaction.payee ?? "Unknown")
          .font(.body)
          .fontWeight(.medium)

        HStack(spacing: 8) {
          Text(transaction.date, format: .dateTime.month().day())
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()

          if let recurPeriod = transaction.recurPeriod, recurPeriod != .once {
            Text("•")
              .foregroundStyle(.secondary)
            Text(recurPeriod.displayName)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
      }

      Spacer()

      Text(transaction.amount.formatNoSymbol)
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
      .accessibilityLabel("Pay \(transaction.payee ?? "transaction")")
    }
    .padding(.vertical, 4)
  }
}

#Preview {
  let backend = InMemoryBackend()
  let store = TransactionStore(repository: backend.transactions)

  UpcomingTransactionsCard(transactionStore: store)
    .frame(width: 400)
    .padding()
    .task {
      let account = Account(
        id: UUID(),
        name: "Test Account",
        type: .bank,
        balance: MonetaryAmount(cents: 100000, currency: .defaultCurrency)
      )
      try? await backend.accounts.create(account)

      try? await backend.transactions.create(
        Transaction(
          id: UUID(),
          type: .expense,
          date: Date().addingTimeInterval(86400 * 2),
          accountId: account.id,
          amount: MonetaryAmount(cents: -5000, currency: .defaultCurrency),
          payee: "Utility Bill",
          recurPeriod: .month,
          recurEvery: 1
        ))

      try? await backend.transactions.create(
        Transaction(
          id: UUID(),
          type: .income,
          date: Date().addingTimeInterval(86400 * 7),
          accountId: account.id,
          amount: MonetaryAmount(cents: 200000, currency: .defaultCurrency),
          payee: "Paycheck",
          recurPeriod: .week,
          recurEvery: 2
        ))

      await store.load(filter: TransactionFilter(scheduled: true))
    }
}
