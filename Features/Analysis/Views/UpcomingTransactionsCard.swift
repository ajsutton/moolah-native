import SwiftUI

struct UpcomingTransactionsCard: View {
  let accounts: Accounts
  let categories: Categories
  let earmarks: Earmarks
  let transactionStore: TransactionStore
  @Binding var selectedTransaction: Transaction?

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Upcoming & Overdue")
        .font(.title2)
        .fontWeight(.semibold)

      if shortTermTransactions.isEmpty {
        emptyState
      } else {
        transactionList
      }
    }
    .padding()
    .background(.background)
    .cornerRadius(12)
    #if os(macOS)
      .frame(maxHeight: .infinity, alignment: .top)
    #endif
  }

  private var emptyState: some View {
    ContentUnavailableView(
      "No Upcoming Transactions",
      systemImage: "calendar",
      description: Text("No overdue or scheduled transactions due in the next 14 days.")
    )
    .frame(maxHeight: 200)
  }

  private var transactionList: some View {
    listContent
  }

  private var listContent: some View {
    List(selection: $selectedTransaction) {
      ForEach(shortTermTransactions) { txn in
        SimpleTransactionRow(
          transaction: txn.transaction,
          accounts: accounts,
          earmarks: earmarks,
          displayAmount: txn.displayAmount,
          isOverdue: isOverdue(txn.transaction),
          isDueToday: isDueToday(txn.transaction)
        ) {
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
    #if os(macOS)
      .frame(minHeight: 200)
    #else
      .frame(height: 200)
    #endif
    .accessibilityLabel("List of upcoming and overdue transactions")
  }

  private var shortTermTransactions: [TransactionWithBalance] {
    transactionStore.scheduledShortTermTransactions()
  }

  private func isOverdue(_ transaction: Transaction) -> Bool {
    transaction.date < Calendar.current.startOfDay(for: Date())
  }

  private func isDueToday(_ transaction: Transaction) -> Bool {
    Calendar.current.isDateInToday(transaction.date)
  }

  private func payTransaction(_ scheduledTransaction: Transaction) async {
    _ = await transactionStore.payScheduledTransaction(scheduledTransaction)
  }
}

private struct SimpleTransactionRow: View {
  let transaction: Transaction
  let accounts: Accounts
  let earmarks: Earmarks
  let displayAmount: InstrumentAmount?
  let isOverdue: Bool
  let isDueToday: Bool
  let onPay: () async -> Void

  @State private var isPaying = false

  var body: some View {
    HStack(spacing: 12) {
      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 4) {
          if isOverdue {
            Image(systemName: "exclamationmark.triangle.fill")
              .foregroundStyle(.red)
              .imageScale(.small)
              .accessibilityLabel("Overdue")
          }
          Text(displayPayee)
            .font(.body)
            .fontWeight(.medium)
            .foregroundStyle(isOverdue ? .red : .primary)
        }

        HStack(spacing: 8) {
          Text(transaction.date, format: .dateTime.month().day())
            .font(.caption)
            .foregroundStyle(isDueToday ? .orange : .secondary)
            .fontWeight(isDueToday ? .semibold : .regular)
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

      if let displayAmount {
        InstrumentAmountView(amount: displayAmount, font: .body)
      } else {
        Text("—")
          .font(.body)
          .monospacedDigit()
          .foregroundStyle(.secondary)
      }

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
      #if os(macOS)
        .buttonStyle(.bordered)
      #else
        .buttonStyle(.borderedProminent)
      #endif
      .controlSize(.small)
      .disabled(isPaying)
      .accessibilityLabel("Pay \(displayPayee)")
    }
    .padding(.vertical, 4)
  }

  private var displayPayee: String {
    let label = transaction.displayPayee(
      viewingAccountId: nil, accounts: accounts, earmarks: earmarks)
    return label.isEmpty ? "Unknown" : label
  }
}

#Preview {
  let (backend, _) = PreviewBackend.create()
  let store = TransactionStore(
    repository: backend.transactions,
    conversionService: backend.conversionService,
    targetInstrument: .AUD
  )

  UpcomingTransactionsCard(
    accounts: Accounts(from: []),
    categories: Categories(from: []),
    earmarks: Earmarks(from: []),
    transactionStore: store,
    selectedTransaction: .constant(nil)
  )
  .frame(width: 400)
  .padding()
  .task {
    let account = Account(
      id: UUID(),
      name: "Test Account",
      type: .bank,
      instrument: .AUD
    )
    _ = try? await backend.accounts.create(
      account,
      openingBalance: InstrumentAmount(quantity: 1000, instrument: .AUD)
    )

    _ = try? await backend.transactions.create(
      Transaction(
        id: UUID(),
        date: Date().addingTimeInterval(86400 * 2),
        payee: "Utility Bill",
        recurPeriod: .month,
        recurEvery: 1,
        legs: [
          TransactionLeg(accountId: account.id, instrument: .AUD, quantity: -50, type: .expense)
        ]
      ))

    _ = try? await backend.transactions.create(
      Transaction(
        id: UUID(),
        date: Date().addingTimeInterval(86400 * 7),
        payee: "Paycheck",
        recurPeriod: .week,
        recurEvery: 2,
        legs: [
          TransactionLeg(accountId: account.id, instrument: .AUD, quantity: 2000, type: .income)
        ]
      ))

    await store.load(filter: TransactionFilter(scheduled: true))
  }
}
