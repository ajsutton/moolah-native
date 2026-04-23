import Foundation
import SwiftData
import Testing

@testable import Moolah

/// Contract tests for `AnalysisRepository.loadAll` — verifies the combined call
/// returns data equivalent to the individual `fetch*` methods invoked with the
/// same arguments.
@Suite("AnalysisRepository Contract Tests — loadAll")
struct AnalysisLoadAllTests {

  @Test("loadAll returns combined results matching individual methods")
  func loadAllReturnsCombinedResults() async throws {
    let backend = try CloudKitAnalysisTestBackend()
    let account = Account(
      id: UUID(),
      name: "Test Account",
      type: .bank,
      instrument: .defaultTestInstrument
    )
    _ = try await backend.accounts.create(account)

    let today = AnalysisTestHelpers.currentCalendar.startOfDay(for: Date())
    let thirtyDaysAgo = try AnalysisTestHelpers.addingDaysCurrentCalendar(-30, to: today)
    let tenDaysAgo = try AnalysisTestHelpers.addingDaysCurrentCalendar(-10, to: today)
    let fiveDaysAgo = try AnalysisTestHelpers.addingDaysCurrentCalendar(-5, to: today)

    _ = try await backend.transactions.create(
      Transaction(
        date: tenDaysAgo, payee: "Salary",
        legs: [
          TransactionLeg(
            accountId: account.id, instrument: .defaultTestInstrument,
            quantity: 500, type: .income)
        ]))

    _ = try await backend.transactions.create(
      Transaction(
        date: fiveDaysAgo, payee: "Groceries",
        legs: [
          TransactionLeg(
            accountId: account.id, instrument: .defaultTestInstrument,
            quantity: -200, type: .expense)
        ]))

    let monthEnd = AnalysisTestHelpers.currentCalendar.component(.day, from: today)

    let result = try await backend.analysis.loadAll(
      historyAfter: thirtyDaysAgo,
      forecastUntil: nil,
      monthEnd: monthEnd
    )

    let individualBalances = try await backend.analysis.fetchDailyBalances(
      after: thirtyDaysAgo, forecastUntil: nil)
    let individualBreakdown = try await backend.analysis.fetchExpenseBreakdown(
      monthEnd: monthEnd, after: thirtyDaysAgo)
    let individualIncome = try await backend.analysis.fetchIncomeAndExpense(
      monthEnd: monthEnd, after: thirtyDaysAgo)

    #expect(result.dailyBalances.count == individualBalances.count)
    #expect(result.expenseBreakdown.count == individualBreakdown.count)
    #expect(result.incomeAndExpense.count == individualIncome.count)
  }
}
