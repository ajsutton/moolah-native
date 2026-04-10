import SwiftUI

struct IncomeExpenseTableCard: View {
  let data: [MonthlyIncomeExpense]

  private static let initialVisibleCount = 6
  private static let loadMoreCount = 6

  @State private var includeEarmarks = false
  @State private var visibleCount = IncomeExpenseTableCard.initialVisibleCount

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      VStack(alignment: .leading, spacing: 8) {
        Text("Monthly Income & Expense")
          .font(.title2)
          .fontWeight(.semibold)

        Toggle("Include Earmarks", isOn: $includeEarmarks)
          .toggleStyle(.switch)
          .font(.caption)
          .fixedSize()
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
    .onChange(of: data.count) { _, _ in
      visibleCount = Self.initialVisibleCount
    }
  }

  private var emptyState: some View {
    Text("No income/expense data")
      .foregroundStyle(.secondary)
      .frame(maxWidth: .infinity, alignment: .center)
      .padding(.vertical, 40)
  }

  private var visibleData: [MonthlyIncomeExpense] {
    Array(data.prefix(visibleCount))
  }

  private var tableView: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      VStack(spacing: 0) {
        // Header row
        HStack(spacing: 12) {
          Text("Month")
            .frame(width: 120, alignment: .leading)
          Text("Income")
            .frame(minWidth: 100, alignment: .trailing)
          Text("Expense")
            .frame(minWidth: 100, alignment: .trailing)
          Text("Savings")
            .frame(minWidth: 100, alignment: .trailing)
          Text("Total Savings")
            .frame(minWidth: 110, alignment: .trailing)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)

        Divider()

        // Data rows (lazy, participates in outer ScrollView)
        LazyVStack(spacing: 0) {
          ForEach(visibleData) { item in
            VStack(spacing: 0) {
              HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                  Text(monthLabel(for: item))
                    .font(.body)
                  Text(monthsAgoLabel(for: item))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .frame(width: 120, alignment: .leading)

                Text(income(for: item).formatted)
                  .monospacedDigit()
                  .foregroundStyle(.green)
                  .frame(minWidth: 100, alignment: .trailing)

                Text(expense(for: item).formatted)
                  .monospacedDigit()
                  .foregroundStyle(.red)
                  .frame(minWidth: 100, alignment: .trailing)

                let savings = profit(for: item)
                Text(savings.formatted)
                  .monospacedDigit()
                  .foregroundStyle(savings.cents >= 0 ? .green : .red)
                  .frame(minWidth: 100, alignment: .trailing)

                let totalSavings = cumulativeSavings(upTo: item)
                Text(totalSavings.formatted)
                  .monospacedDigit()
                  .foregroundStyle(totalSavings.cents >= 0 ? .green : .red)
                  .frame(minWidth: 110, alignment: .trailing)
              }
              .padding(.horizontal, 12)
              .padding(.vertical, 8)

              Divider()
            }
            .onAppear {
              if item.id == visibleData.last?.id, visibleCount < data.count {
                visibleCount += Self.loadMoreCount
              }
            }
          }
        }
      }
      .frame(minWidth: 530)
    }
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
    Self.cumulativeSavings(
      upTo: item, in: data, includeEarmarks: includeEarmarks)
  }

  /// Cumulative savings from the first row through the given item.
  /// Data is sorted most-recent-first, so the first row's total equals its own
  /// savings and each subsequent row adds to the running total.
  nonisolated static func cumulativeSavings(
    upTo item: MonthlyIncomeExpense,
    in data: [MonthlyIncomeExpense],
    includeEarmarks: Bool
  ) -> MonetaryAmount {
    guard let index = data.firstIndex(where: { $0.id == item.id }) else {
      return .zero(currency: data.first?.income.currency ?? .AUD)
    }
    return data[...index].reduce(MonetaryAmount.zero(currency: item.income.currency)) {
      total, month in
      total + (includeEarmarks ? month.totalProfit : month.profit)
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
      income: MonetaryAmount(cents: 500000, currency: .AUD),
      expense: MonetaryAmount(cents: 300000, currency: .AUD),
      profit: MonetaryAmount(cents: 200000, currency: .AUD),
      earmarkedIncome: MonetaryAmount(cents: 50000, currency: .AUD),
      earmarkedExpense: MonetaryAmount(cents: 20000, currency: .AUD),
      earmarkedProfit: MonetaryAmount(cents: 30000, currency: .AUD)
    ),
    MonthlyIncomeExpense(
      month: "202603",
      start: Date().addingTimeInterval(-86400 * 60),
      end: Date().addingTimeInterval(-86400 * 31),
      income: MonetaryAmount(cents: 480000, currency: .AUD),
      expense: MonetaryAmount(cents: 320000, currency: .AUD),
      profit: MonetaryAmount(cents: 160000, currency: .AUD),
      earmarkedIncome: MonetaryAmount(cents: 40000, currency: .AUD),
      earmarkedExpense: MonetaryAmount(cents: 25000, currency: .AUD),
      earmarkedProfit: MonetaryAmount(cents: 15000, currency: .AUD)
    ),
  ]

  return IncomeExpenseTableCard(data: data)
    .frame(width: 600, height: 500)
    .padding()
}
