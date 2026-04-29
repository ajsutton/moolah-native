import Foundation
import Testing

@testable import Moolah

/// Contract tests pinning that `.income` and `.expense` legs recorded on
/// **investment** accounts (e.g. dividends, brokerage fees) are included
/// in the monthly `income` / `expense` totals rather than silently
/// dropped.
///
/// Split out of `AnalysisIncomeExpenseTests` as a dedicated suite so the
/// parent file stays under SwiftLint's `type_body_length` budget. The
/// expected behaviour: `.income` / `.expense` legs only guard on
/// `hasAccount` — there is NO investment-account exclusion. A backend
/// that filtered investment-account income/expense legs out of the
/// main totals would silently under-count user income.
@Suite("AnalysisRepository Contract Tests — Income/Expense on Investment Accounts")
struct AnalysisIncomeExpenseInvestmentTests {
  @Test("income legs on investment accounts are included in income total")
  func incomeOnInvestmentAccountIncludedInIncome() async throws {
    let backend = try CloudKitAnalysisTestBackend()
    let investmentAccount = Account(
      id: UUID(), name: "Brokerage", type: .investment, instrument: .defaultTestInstrument)
    _ = try await backend.accounts.create(investmentAccount)

    let today = AnalysisTestHelpers.currentCalendar.startOfDay(for: Date())

    _ = try await backend.transactions.create(
      Transaction(
        date: today, payee: "Dividend",
        legs: [
          TransactionLeg(
            accountId: investmentAccount.id, instrument: .defaultTestInstrument,
            quantity: 50, type: .income)
        ]))

    let data = try await backend.analysis.fetchIncomeAndExpense(monthEnd: 25, after: nil)

    let month = try #require(data.first)
    #expect(
      month.income.quantity == 50,
      "Investment-account income (e.g. dividends) must be included in the income total")
  }

  @Test("expense legs on investment accounts are included in expense total")
  func expenseOnInvestmentAccountIncludedInExpense() async throws {
    let backend = try CloudKitAnalysisTestBackend()
    let investmentAccount = Account(
      id: UUID(), name: "Brokerage", type: .investment, instrument: .defaultTestInstrument)
    _ = try await backend.accounts.create(investmentAccount)

    let today = AnalysisTestHelpers.currentCalendar.startOfDay(for: Date())

    _ = try await backend.transactions.create(
      Transaction(
        date: today, payee: "Brokerage Fee",
        legs: [
          TransactionLeg(
            accountId: investmentAccount.id, instrument: .defaultTestInstrument,
            quantity: -25, type: .expense)
        ]))

    let data = try await backend.analysis.fetchIncomeAndExpense(monthEnd: 25, after: nil)

    let month = try #require(data.first)
    #expect(
      month.expense.quantity == -25,
      "Investment-account expense (e.g. brokerage fees) must be included in the expense total")
  }
}
