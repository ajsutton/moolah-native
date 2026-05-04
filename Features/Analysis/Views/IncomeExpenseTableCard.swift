import SwiftUI

struct IncomeExpenseTableCard: View {
  let data: [MonthlyIncomeExpense]

  private static let initialVisibleCount = 6
  private static let loadMoreCount = 6

  @State private var includeEarmarks = false
  @State private var visibleCount = IncomeExpenseTableCard.initialVisibleCount

  @ScaledMetric private var monthColumnMinWidth: CGFloat = 120
  @ScaledMetric private var amountColumnMinWidth: CGFloat = 100
  @ScaledMetric private var totalColumnMinWidth: CGFloat = 110

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
    .background(.background)
    .clipShape(.rect(cornerRadius: 12))
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
        headerRow
        Divider()
        dataRows
      }
      .frame(minWidth: 530)
    }
    .accessibilityLabel("Monthly income and expense table")
  }

  private var headerRow: some View {
    HStack(spacing: 12) {
      Text("Month").frame(minWidth: monthColumnMinWidth, alignment: .leading)
      Text("Income").frame(minWidth: amountColumnMinWidth, alignment: .trailing)
      Text("Expense").frame(minWidth: amountColumnMinWidth, alignment: .trailing)
      Text("Savings").frame(minWidth: amountColumnMinWidth, alignment: .trailing)
      Text("Total Savings").frame(minWidth: totalColumnMinWidth, alignment: .trailing)
    }
    .font(.caption)
    .foregroundStyle(.secondary)
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
  }

  private var dataRows: some View {
    // Lazy, participates in outer ScrollView.
    LazyVStack(spacing: 0) {
      ForEach(visibleData) { item in
        dataRow(for: item)
      }
    }
  }

  private func dataRow(for item: MonthlyIncomeExpense) -> some View {
    VStack(spacing: 0) {
      HStack(spacing: 12) {
        VStack(alignment: .leading, spacing: 2) {
          Text(Self.monthLabel(for: item))
            .font(.body)
            .monospacedDigit()
          Text(monthsAgoLabel(for: item))
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
        .frame(minWidth: monthColumnMinWidth, alignment: .leading)
        InstrumentAmountView(amount: income(for: item))
          .frame(minWidth: amountColumnMinWidth, alignment: .trailing)
        InstrumentAmountView(amount: expense(for: item))
          .frame(minWidth: amountColumnMinWidth, alignment: .trailing)
        InstrumentAmountView(amount: profit(for: item))
          .frame(minWidth: amountColumnMinWidth, alignment: .trailing)
        InstrumentAmountView(amount: cumulativeSavings(upTo: item))
          .frame(minWidth: totalColumnMinWidth, alignment: .trailing)
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
      .accessibilityElement(children: .combine)
      .accessibilityLabel(
        Self.accessibilityLabel(for: item, in: data, includeEarmarks: includeEarmarks))
      Divider()
    }
    .onAppear {
      if item.id == visibleData.last?.id, visibleCount < data.count {
        visibleCount += Self.loadMoreCount
      }
    }
  }

  private func income(for item: MonthlyIncomeExpense) -> InstrumentAmount {
    includeEarmarks ? item.totalIncome : item.income
  }

  private func expense(for item: MonthlyIncomeExpense) -> InstrumentAmount {
    includeEarmarks ? item.totalExpense : item.expense
  }

  private func profit(for item: MonthlyIncomeExpense) -> InstrumentAmount {
    includeEarmarks ? item.totalProfit : item.profit
  }

  private func cumulativeSavings(upTo item: MonthlyIncomeExpense) -> InstrumentAmount {
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
  ) -> InstrumentAmount {
    guard let index = data.firstIndex(where: { $0.id == item.id }) else {
      return .zero(instrument: data.first?.income.instrument ?? .AUD)
    }
    let zero = InstrumentAmount.zero(instrument: item.income.instrument)
    return data[...index].reduce(zero) { total, month in
      total + (includeEarmarks ? month.totalProfit : month.profit)
    }
  }

  /// Builds a single combined VoiceOver label for a data row, so VoiceOver reads
  /// the row as one element (`month: income, expense, savings, total savings`)
  /// rather than traversing each `InstrumentAmountView` independently.
  nonisolated static func accessibilityLabel(
    for item: MonthlyIncomeExpense,
    in data: [MonthlyIncomeExpense],
    includeEarmarks: Bool
  ) -> String {
    let month = Self.monthLabel(for: item)
    let income = includeEarmarks ? item.totalIncome : item.income
    let expense = includeEarmarks ? item.totalExpense : item.expense
    let profit = includeEarmarks ? item.totalProfit : item.profit
    let total = Self.cumulativeSavings(upTo: item, in: data, includeEarmarks: includeEarmarks)
    return
      "\(month). Income \(income.formatted). Expense \(expense.formatted). Savings \(profit.formatted). Total savings \(total.formatted)."
  }

  nonisolated static func monthLabel(for item: MonthlyIncomeExpense) -> String {
    item.start.formatted(.dateTime.month(.abbreviated).year())
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
      income: InstrumentAmount(quantity: 5000, instrument: .AUD),
      expense: InstrumentAmount(quantity: 3000, instrument: .AUD),
      profit: InstrumentAmount(quantity: 2000, instrument: .AUD),
      earmarkedIncome: InstrumentAmount(quantity: 500, instrument: .AUD),
      earmarkedExpense: InstrumentAmount(quantity: 200, instrument: .AUD),
      earmarkedProfit: InstrumentAmount(quantity: 300, instrument: .AUD)
    ),
    MonthlyIncomeExpense(
      month: "202603",
      start: Date().addingTimeInterval(-86400 * 60),
      end: Date().addingTimeInterval(-86400 * 31),
      income: InstrumentAmount(quantity: 4800, instrument: .AUD),
      expense: InstrumentAmount(quantity: 3200, instrument: .AUD),
      profit: InstrumentAmount(quantity: 1600, instrument: .AUD),
      earmarkedIncome: InstrumentAmount(quantity: 400, instrument: .AUD),
      earmarkedExpense: InstrumentAmount(quantity: 250, instrument: .AUD),
      earmarkedProfit: InstrumentAmount(quantity: 150, instrument: .AUD)
    ),
  ]

  IncomeExpenseTableCard(data: data)
    .frame(width: 600, height: 500)
    .padding()
}
