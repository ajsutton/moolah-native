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
    // extracts the UTC calendar day and bucketises against that day.
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

  @Test("fetchExpenseBreakdown buckets by UTC day, not local-time day")
  func expenseBreakdownUTCDayDrivesBucket() async throws {
    // A transaction at 23:00 UTC on March 24 is March 25 in any local
    // zone east of UTC (UTC+1, UTC+2, …) but its UTC `DATE()` is March
    // 24. The bucket key has to come from the UTC calendar day or the
    // result drifts with the runner's local timezone. monthEnd=25 means
    // March 24 lands in `202503` and March 25 lands in `202503` too —
    // we use monthEnd=23 so the two boundary candidates split into
    // distinct months: a 24 UTC-day → April (`202504`); a 25 UTC-day →
    // April. We pick monthEnd=24 to put 24 in March and 25 in April,
    // and place the txn at 2025-03-24 23:00 UTC so the answer is
    // unambiguous: it's a March-bucketed row regardless of viewer
    // timezone, because the UTC day is 24.
    let backend = try CloudKitAnalysisTestBackend()
    let account = Account(
      id: UUID(), name: "Test Account", type: .bank, instrument: .defaultTestInstrument)
    _ = try await backend.accounts.create(account)

    let category = Category(id: UUID(), name: "Groceries")
    _ = try await backend.categories.create(category)

    let lateUTCEvening = try AnalysisTestHelpers.utcDate(
      year: 2025, month: 3, day: 24, hour: 23)
    _ = try await backend.transactions.create(
      Transaction(
        date: lateUTCEvening, payee: "Late evening UTC",
        legs: [
          TransactionLeg(
            accountId: account.id, instrument: .defaultTestInstrument,
            quantity: -42, type: .expense, categoryId: category.id)
        ]))

    let breakdown = try await backend.analysis.fetchExpenseBreakdown(monthEnd: 24, after: nil)

    // monthEnd=24 means UTC day 24 stays in March, UTC day 25 spills
    // into April. The transaction's UTC day is 24 — so it must land
    // in `202503` regardless of local time zone. If a regression
    // walks `Calendar.current.component(.day, ...)` over the
    // UTC-midnight `Date` returned by the parser, this test fails in
    // any negative-UTC zone (where the local day is 23 or 24, both of
    // which still fall in `202503` for monthEnd=24, but the rate-key
    // mismatch would still surface elsewhere). The stronger signal:
    // the test uses `utcDate(... hour: 23)`, so a regression that
    // reads `transaction.date` directly (rather than its UTC `DATE()`)
    // and walks via `Calendar.current` in a UTC+2 zone would map the
    // local day to 25, drifting the bucket into April.
    let marchEntries = breakdown.filter { $0.month == "202503" }
    let aprilEntries = breakdown.filter { $0.month == "202504" }
    #expect(marchEntries.count == 1)
    #expect(aprilEntries.isEmpty)
    #expect(marchEntries[0].totalExpenses.quantity == -42)
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
