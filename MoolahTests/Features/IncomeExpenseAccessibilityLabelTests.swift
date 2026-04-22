import Foundation
import Testing

@testable import Moolah

@Suite("IncomeExpenseTableCard — accessibilityLabel")
struct IncomeExpenseAccessibilityLabelTests {

  private let instrument: Instrument = .defaultTestInstrument

  private func amount(_ quantity: Decimal) -> InstrumentAmount {
    InstrumentAmount(quantity: quantity, instrument: instrument)
  }

  private func monthData(
    month: String,
    start: Date = Date(timeIntervalSince1970: 1_704_067_200),  // 2024-01-01
    income: Decimal,
    expense: Decimal,
    earmarkedIncome: Decimal = 0,
    earmarkedExpense: Decimal = 0
  ) -> MonthlyIncomeExpense {
    MonthlyIncomeExpense(
      month: month,
      start: start,
      end: start,
      income: amount(income),
      expense: amount(expense),
      profit: amount(income - expense),
      earmarkedIncome: amount(earmarkedIncome),
      earmarkedExpense: amount(earmarkedExpense),
      earmarkedProfit: amount(earmarkedIncome - earmarkedExpense)
    )
  }

  @Test("combines month, income, expense, savings, and total savings")
  func combinesAllColumns() {
    let data = [
      monthData(month: "202401", income: Decimal(5000), expense: Decimal(3000))
    ]

    let label = IncomeExpenseTableCard.accessibilityLabel(
      for: data[0], in: data, includeEarmarks: false)

    // Must mention every column so VoiceOver reads the whole row.
    #expect(label.contains("Income"))
    #expect(label.contains("Expense"))
    #expect(label.contains("Savings"))
    #expect(label.contains("Total savings"))
    // Month label is included (formatted "MMM yyyy").
    #expect(label.contains(IncomeExpenseTableCard.monthLabel(for: data[0])))
    // Formatted amounts are included.
    #expect(label.contains(data[0].income.formatted))
    #expect(label.contains(data[0].expense.formatted))
    #expect(label.contains(data[0].profit.formatted))
  }

  @Test("includeEarmarks switches to earmark-inclusive totals")
  func usesEarmarkTotalsWhenIncluded() {
    let data = [
      monthData(
        month: "202401", income: Decimal(5000), expense: Decimal(3000),
        earmarkedIncome: Decimal(1000), earmarkedExpense: Decimal(500))
    ]

    let withEarmarks = IncomeExpenseTableCard.accessibilityLabel(
      for: data[0], in: data, includeEarmarks: true)
    let withoutEarmarks = IncomeExpenseTableCard.accessibilityLabel(
      for: data[0], in: data, includeEarmarks: false)

    // Earmark-inclusive label should show totalIncome/totalExpense, not the plain values.
    #expect(withEarmarks.contains(data[0].totalIncome.formatted))
    #expect(withEarmarks.contains(data[0].totalExpense.formatted))
    #expect(withoutEarmarks.contains(data[0].income.formatted))
    #expect(withoutEarmarks.contains(data[0].expense.formatted))
    #expect(withEarmarks != withoutEarmarks)
  }

  @Test("total savings reflects cumulative position")
  func totalSavingsIsCumulative() {
    let data = [
      monthData(month: "202402", income: Decimal(5000), expense: Decimal(3000)),
      monthData(month: "202401", income: Decimal(4000), expense: Decimal(3500)),
    ]

    // Row at index 1 should include cumulative total 2000 + 500 = 2500.
    let cumulative = IncomeExpenseTableCard.cumulativeSavings(
      upTo: data[1], in: data, includeEarmarks: false)
    let label = IncomeExpenseTableCard.accessibilityLabel(
      for: data[1], in: data, includeEarmarks: false)

    #expect(label.contains(cumulative.formatted))
  }
}
