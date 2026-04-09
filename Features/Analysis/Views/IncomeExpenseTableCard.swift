import SwiftUI

struct IncomeExpenseTableCard: View {
  let data: [MonthlyIncomeExpense]

  @State private var includeEarmarks = false

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("Monthly Income & Expense")
          .font(.title2)
          .fontWeight(.semibold)

        Spacer()

        Toggle("Include Earmarks", isOn: $includeEarmarks)
          .toggleStyle(.switch)
          .font(.caption)
      }

      if data.isEmpty {
        emptyState
      } else {
        tableView
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
    Text("No income/expense data")
      .foregroundStyle(.secondary)
      .frame(maxWidth: .infinity, alignment: .center)
      .padding(.vertical, 40)
  }

  private var tableView: some View {
    Table(data) {
      TableColumn("Month") { item in
        VStack(alignment: .leading, spacing: 2) {
          Text(monthLabel(for: item))
            .font(.body)
          Text(monthsAgoLabel(for: item))
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      .width(min: 120)

      TableColumn("Income") { item in
        Text(income(for: item).formatted)
          .monospacedDigit()
          .foregroundStyle(.green)
      }
      .width(min: 80)
      .alignment(.trailing)

      TableColumn("Expense") { item in
        Text(expense(for: item).formatted)
          .monospacedDigit()
          .foregroundStyle(.red)
      }
      .width(min: 80)
      .alignment(.trailing)

      TableColumn("Savings") { item in
        Text(profit(for: item).formatted)
          .monospacedDigit()
          .foregroundStyle(profit(for: item).cents >= 0 ? .green : .red)
      }
      .width(min: 80)
      .alignment(.trailing)

      TableColumn("Total Savings") { item in
        Text(cumulativeSavings(upTo: item).formatted)
          .monospacedDigit()
          .foregroundStyle(.secondary)
      }
      .width(min: 100)
      .alignment(.trailing)
    }
    .frame(height: 400)
    .accessibilityLabel("Monthly income and expense table")
  }

  private func income(for item: MonthlyIncomeExpense) -> MonetaryAmount {
    includeEarmarks ? item.totalIncome : item.income
  }

  private func expense(for item: MonthlyIncomeExpense) -> MonetaryAmount {
    includeEarmarks ? item.totalExpense : item.expense
  }

  private func profit(for item: MonthlyIncomeExpense) -> MonetaryAmount {
    includeEarmarks ? item.totalProfit : item.profit
  }

  private func cumulativeSavings(upTo item: MonthlyIncomeExpense) -> MonetaryAmount {
    guard let index = data.firstIndex(where: { $0.id == item.id }) else {
      return .zero
    }
    // Sum from the current item to the end (data is sorted most recent first)
    return data[index...].reduce(MonetaryAmount.zero) { total, month in
      total + profit(for: month)
    }
  }

  private func monthLabel(for item: MonthlyIncomeExpense) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "MMM yyyy"
    return formatter.string(from: item.start)
  }

  private func monthsAgoLabel(for item: MonthlyIncomeExpense) -> String {
    let months = Calendar.current.dateComponents([.month], from: item.end, to: Date()).month ?? 0
    if months == 0 { return "This month" }
    if months == 1 { return "Last month" }
    return "\(months) months ago"
  }
}

#Preview {
  let data = [
    MonthlyIncomeExpense(
      month: "202604",
      start: Date().addingTimeInterval(-86400 * 30),
      end: Date(),
      income: MonetaryAmount(cents: 500000, currency: .defaultCurrency),
      expense: MonetaryAmount(cents: 300000, currency: .defaultCurrency),
      profit: MonetaryAmount(cents: 200000, currency: .defaultCurrency),
      earmarkedIncome: MonetaryAmount(cents: 50000, currency: .defaultCurrency),
      earmarkedExpense: MonetaryAmount(cents: 20000, currency: .defaultCurrency),
      earmarkedProfit: MonetaryAmount(cents: 30000, currency: .defaultCurrency)
    ),
    MonthlyIncomeExpense(
      month: "202603",
      start: Date().addingTimeInterval(-86400 * 60),
      end: Date().addingTimeInterval(-86400 * 31),
      income: MonetaryAmount(cents: 480000, currency: .defaultCurrency),
      expense: MonetaryAmount(cents: 320000, currency: .defaultCurrency),
      profit: MonetaryAmount(cents: 160000, currency: .defaultCurrency),
      earmarkedIncome: MonetaryAmount(cents: 40000, currency: .defaultCurrency),
      earmarkedExpense: MonetaryAmount(cents: 25000, currency: .defaultCurrency),
      earmarkedProfit: MonetaryAmount(cents: 15000, currency: .defaultCurrency)
    ),
  ]

  return IncomeExpenseTableCard(data: data)
    .frame(width: 600, height: 500)
    .padding()
}
