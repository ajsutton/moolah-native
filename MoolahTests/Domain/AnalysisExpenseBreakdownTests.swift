import Foundation
import SwiftData
import Testing

@testable import Moolah

/// Contract tests for `AnalysisRepository.fetchExpenseBreakdown` — grouping,
/// financial-month boundaries, scheduled-transaction exclusion, uncategorized
/// filtering, and descending-month ordering.
@Suite("AnalysisRepository Contract Tests — Expense Breakdown")
struct AnalysisExpenseBreakdownTests {

  @Test("fetchExpenseBreakdown groups by category and month")
  func expenseBreakdownGrouping() async throws {
    let backend = try CloudKitAnalysisTestBackend()
    let account = Account(
      id: UUID(), name: "Test Account", type: .bank, instrument: .defaultTestInstrument)
    _ = try await backend.accounts.create(account)

    let category = Category(id: UUID(), name: "Groceries")
    _ = try await backend.categories.create(category)

    let thisMonth = Date()
    let lastMonth = try AnalysisTestHelpers.addingMonthsCurrentCalendar(-1, to: thisMonth)
    let halfDollar = try AnalysisTestHelpers.decimal("-0.50")

    _ = try await backend.transactions.create(
      Transaction(
        date: thisMonth, payee: "Store A",
        legs: [
          TransactionLeg(
            accountId: account.id, instrument: .defaultTestInstrument,
            quantity: -1, type: .expense, categoryId: category.id)
        ]))

    _ = try await backend.transactions.create(
      Transaction(
        date: lastMonth, payee: "Store B",
        legs: [
          TransactionLeg(
            accountId: account.id, instrument: .defaultTestInstrument,
            quantity: halfDollar, type: .expense, categoryId: category.id)
        ]))

    let breakdown = try await backend.analysis.fetchExpenseBreakdown(monthEnd: 25, after: nil)

    let uniqueMonths = Set(breakdown.map(\.month))
    #expect(uniqueMonths.count >= 1, "Should have at least one month")
  }

  @Test("fetchExpenseBreakdown excludes scheduled transactions")
  func expenseBreakdownExcludesScheduled() async throws {
    let backend = try CloudKitAnalysisTestBackend()
    let account = Account(
      id: UUID(), name: "Test Account", type: .bank, instrument: .defaultTestInstrument)
    _ = try await backend.accounts.create(account)

    _ = try await backend.transactions.create(
      Transaction(
        date: Date(), payee: "Monthly Bill",
        recurPeriod: .month, recurEvery: 1,
        legs: [
          TransactionLeg(
            accountId: account.id, instrument: .defaultTestInstrument,
            quantity: -1, type: .expense)
        ]))

    let breakdown = try await backend.analysis.fetchExpenseBreakdown(monthEnd: 25, after: nil)

    #expect(breakdown.isEmpty, "Scheduled transactions should not appear in expense breakdown")
  }

  @Test("fetchExpenseBreakdown assigns transactions to correct financial month based on monthEnd")
  func expenseBreakdownMonthBoundary() async throws {
    let backend = try CloudKitAnalysisTestBackend()
    let account = Account(
      id: UUID(), name: "Test Account", type: .bank, instrument: .defaultTestInstrument)
    _ = try await backend.accounts.create(account)

    let category = Category(id: UUID(), name: "Groceries")
    _ = try await backend.categories.create(category)

    // UTC-anchored at noon so SQL `DATE(t.date)` lands on the intended
    // calendar day in any local timezone — the GRDB analysis path
    // groups by UTC date (see §3.4.2 of the GRDB slice plan).
    let onBoundary = try AnalysisTestHelpers.utcDate(year: 2025, month: 3, day: 25)
    let afterBoundary = try AnalysisTestHelpers.utcDate(year: 2025, month: 3, day: 26)

    _ = try await backend.transactions.create(
      Transaction(
        date: onBoundary, payee: "On boundary",
        legs: [
          TransactionLeg(
            accountId: account.id, instrument: .defaultTestInstrument,
            quantity: -10, type: .expense, categoryId: category.id)
        ]))

    _ = try await backend.transactions.create(
      Transaction(
        date: afterBoundary, payee: "After boundary",
        legs: [
          TransactionLeg(
            accountId: account.id, instrument: .defaultTestInstrument,
            quantity: -20, type: .expense, categoryId: category.id)
        ]))

    let breakdown = try await backend.analysis.fetchExpenseBreakdown(monthEnd: 25, after: nil)

    let marchEntries = breakdown.filter { $0.month == "202503" }
    let aprilEntries = breakdown.filter { $0.month == "202504" }

    #expect(marchEntries.count == 1, "Day 25 should belong to March financial month")
    #expect(aprilEntries.count == 1, "Day 26 should belong to April financial month")
    #expect(marchEntries[0].totalExpenses.quantity == -10)
    #expect(aprilEntries[0].totalExpenses.quantity == -20)
  }

  @Test("fetchExpenseBreakdown returns months in descending order")
  func expenseBreakdownSortOrder() async throws {
    let backend = try CloudKitAnalysisTestBackend()
    let account = Account(
      id: UUID(), name: "Test Account", type: .bank, instrument: .defaultTestInstrument)
    _ = try await backend.accounts.create(account)

    let category = Category(id: UUID(), name: "Food")
    _ = try await backend.categories.create(category)

    let month1 = try AnalysisTestHelpers.date(year: 2025, month: 1, day: 15)
    let month2 = try AnalysisTestHelpers.date(year: 2025, month: 2, day: 15)
    let month3 = try AnalysisTestHelpers.date(year: 2025, month: 3, day: 15)

    for date in [month1, month2, month3] {
      _ = try await backend.transactions.create(
        Transaction(
          date: date, payee: "Store",
          legs: [
            TransactionLeg(
              accountId: account.id, instrument: .defaultTestInstrument,
              quantity: -1, type: .expense, categoryId: category.id)
          ]))
    }

    let breakdown = try await backend.analysis.fetchExpenseBreakdown(monthEnd: 25, after: nil)

    let months = breakdown.map(\.month)
    let uniqueMonths = months.reduce(into: [String]()) { result, month in
      if !result.contains(month) { result.append(month) }
    }

    for index in 0..<(uniqueMonths.count - 1) {
      #expect(
        uniqueMonths[index] > uniqueMonths[index + 1],
        "Expense breakdown months should be in descending order"
      )
    }
  }

  @Test("fetchExpenseBreakdown excludes uncategorized expenses")
  func expenseBreakdownExcludesUncategorized() async throws {
    let backend = try CloudKitAnalysisTestBackend()
    let account = Account(
      id: UUID(), name: "Test Account", type: .bank, instrument: .defaultTestInstrument)
    _ = try await backend.accounts.create(account)

    let cat = Category(id: UUID(), name: "Food")
    _ = try await backend.categories.create(cat)

    // Categorized expense
    _ = try await backend.transactions.create(
      Transaction(
        date: Date(), payee: "Grocery Store",
        legs: [
          TransactionLeg(
            accountId: account.id, instrument: .defaultTestInstrument,
            quantity: -10, type: .expense, categoryId: cat.id)
        ]))

    // Uncategorized expense — excluded by server: category_id IS NOT NULL
    _ = try await backend.transactions.create(
      Transaction(
        date: Date(), payee: "Uncategorized Store",
        legs: [
          TransactionLeg(
            accountId: account.id, instrument: .defaultTestInstrument,
            quantity: -5, type: .expense)
        ]))

    let breakdown = try await backend.analysis.fetchExpenseBreakdown(monthEnd: 25, after: nil)

    #expect(breakdown.count == 1)
    #expect(breakdown[0].categoryId == cat.id)
    #expect(breakdown[0].totalExpenses.quantity == -10)
  }
}
