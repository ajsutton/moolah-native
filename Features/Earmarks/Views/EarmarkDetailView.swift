import SwiftUI

struct EarmarkDetailView: View {
  let earmark: Earmark
  let accounts: Accounts
  let categories: Categories
  let earmarks: Earmarks
  let transactionStore: TransactionStore

  var body: some View {
    VStack(spacing: 0) {
      overviewPanel
      Divider()
      TransactionListView(
        title: earmark.name,
        filter: TransactionFilter(earmarkId: earmark.id),
        accounts: accounts,
        categories: categories,
        earmarks: earmarks,
        transactionStore: transactionStore
      )
    }
    .navigationTitle(earmark.name)
  }

  private var overviewPanel: some View {
    VStack(spacing: 12) {
      HStack(spacing: 24) {
        summaryItem(label: "Balance", amount: earmark.balance)
        Divider().frame(height: 32)
        summaryItem(label: "Saved", amount: earmark.saved)
        Divider().frame(height: 32)
        summaryItem(label: "Spent", amount: earmark.spent)
      }

      if let goal = earmark.savingsGoal, goal > .zero {
        VStack(spacing: 4) {
          let progress =
            earmark.balance.cents > 0
            ? Double(earmark.balance.cents) / Double(goal.cents)
            : 0.0

          ProgressView(value: min(progress, 1.0)) {
            HStack {
              Text("Savings Goal")
                .font(.caption)
              Spacer()
              MonetaryAmountView(amount: earmark.balance)
                .font(.caption)
              Text("of")
                .font(.caption)
                .foregroundStyle(.secondary)
              MonetaryAmountView(amount: goal)
                .font(.caption)
            }
          }

          savingsDateRow
        }
      }
    }
    .padding()
  }

  private func summaryItem(label: String, amount: MonetaryAmount) -> some View {
    VStack(spacing: 2) {
      Text(label)
        .font(.caption)
        .foregroundStyle(.secondary)
      MonetaryAmountView(amount: amount)
        .font(.headline)
    }
    .frame(maxWidth: .infinity)
  }

  @ViewBuilder
  private var savingsDateRow: some View {
    let hasStart = earmark.savingsStartDate != nil
    let hasEnd = earmark.savingsEndDate != nil

    if hasStart || hasEnd {
      HStack {
        if let start = earmark.savingsStartDate {
          Label(start.formatted(date: .abbreviated, time: .omitted), systemImage: "calendar")
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        if hasStart && hasEnd {
          Image(systemName: "arrow.right")
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }

        if let end = earmark.savingsEndDate {
          Label(end.formatted(date: .abbreviated, time: .omitted), systemImage: "flag")
            .font(.caption)
            .foregroundStyle(.secondary)

          if let remaining = timeRemaining(until: end) {
            Spacer()
            Text(remaining)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }

        if !hasEnd {
          Spacer()
        }
      }
    }
  }

  private func timeRemaining(until endDate: Date) -> String? {
    let now = Date()
    guard endDate > now else { return "Past due" }

    let components = Calendar.current.dateComponents([.day], from: now, to: endDate)
    guard let days = components.day else { return nil }

    if days == 0 { return "Due today" }
    if days == 1 { return "1 day left" }
    if days < 30 { return "\(days) days left" }
    let months = days / 30
    if months == 1 { return "~1 month left" }
    return "~\(months) months left"
  }
}

#Preview {
  let earmarkId = UUID()
  let earmark = Earmark(
    id: earmarkId,
    name: "Holiday Fund",
    balance: MonetaryAmount(cents: 250000, currency: Currency.defaultCurrency),
    saved: MonetaryAmount(cents: 300000, currency: Currency.defaultCurrency),
    spent: MonetaryAmount(cents: -50000, currency: Currency.defaultCurrency),
    savingsGoal: MonetaryAmount(cents: 500000, currency: Currency.defaultCurrency),
    savingsStartDate: Calendar.current.date(from: DateComponents(year: 2026, month: 1, day: 1)),
    savingsEndDate: Calendar.current.date(from: DateComponents(year: 2026, month: 12, day: 31))
  )
  let repository = InMemoryTransactionRepository(initialTransactions: [
    Transaction(
      type: .expense, date: Date(), accountId: UUID(),
      amount: MonetaryAmount(cents: -5023, currency: Currency.defaultCurrency),
      payee: "Flight Booking", earmarkId: earmarkId),
    Transaction(
      type: .income, date: Date().addingTimeInterval(-86400), accountId: UUID(),
      amount: MonetaryAmount(cents: 50000, currency: Currency.defaultCurrency),
      payee: "Savings Transfer", earmarkId: earmarkId),
  ])
  let store = TransactionStore(repository: repository)

  NavigationStack {
    EarmarkDetailView(
      earmark: earmark,
      accounts: Accounts(from: []),
      categories: Categories(from: []),
      earmarks: Earmarks(from: []),
      transactionStore: store
    )
  }
}
