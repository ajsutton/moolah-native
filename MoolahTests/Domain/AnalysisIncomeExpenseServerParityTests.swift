import Foundation
import SwiftData
import Testing

@testable import Moolah

/// Verifies the CloudKit analysis matches the server SQL semantics:
///   income  = SUM(IF(type='income'  AND account_id IS NOT NULL, amount, 0))
///   expense = SUM(IF(type='expense' AND account_id IS NOT NULL, amount, 0))
/// `openingBalance` is excluded from income/expense reports entirely.
@Suite("AnalysisRepository Contract Tests — Income/Expense Server Parity")
struct AnalysisIncomeExpenseServerParityTests {

  @Test("earmarked income/expense with accountId included in main totals")
  func earmarkedWithAccountIdInMainTotals() async throws {
    let backend = try CloudKitAnalysisTestBackend()
    let account = Account(
      id: UUID(), name: "Checking", type: .bank, instrument: .defaultTestInstrument)
    _ = try await backend.accounts.create(account)

    let earmark = Earmark(id: UUID(), name: "Holiday", instrument: .defaultTestInstrument)
    _ = try await backend.earmarks.create(earmark)

    let today = AnalysisTestHelpers.currentCalendar.startOfDay(for: Date())

    _ = try await backend.transactions.create(
      Transaction(
        date: today, payee: "Salary",
        legs: [
          TransactionLeg(
            accountId: account.id, instrument: .defaultTestInstrument,
            quantity: 100, type: .income)
        ]))

    // Earmarked income WITH accountId: +30 (in BOTH income and earmarkedIncome)
    _ = try await backend.transactions.create(
      Transaction(
        date: today, payee: "Earmarked Income",
        legs: [
          TransactionLeg(
            accountId: account.id, instrument: .defaultTestInstrument,
            quantity: 30, type: .income, earmarkId: earmark.id)
        ]))

    _ = try await backend.transactions.create(
      Transaction(
        date: today, payee: "Groceries",
        legs: [
          TransactionLeg(
            accountId: account.id, instrument: .defaultTestInstrument,
            quantity: -50, type: .expense)
        ]))

    // Earmarked expense WITH accountId: -20 (in BOTH expense and earmarkedExpense)
    _ = try await backend.transactions.create(
      Transaction(
        date: today, payee: "Holiday Spend",
        legs: [
          TransactionLeg(
            accountId: account.id, instrument: .defaultTestInstrument,
            quantity: -20, type: .expense, earmarkId: earmark.id)
        ]))

    let data = try await backend.analysis.fetchIncomeAndExpense(monthEnd: 25, after: nil)

    #expect(!data.isEmpty)
    let month = data[0]

    // Main totals include earmarked legs that have an accountId (matching server)
    #expect(month.income.quantity == 130)  // 100 + 30
    #expect(month.expense.quantity == -70)  // -50 + -20
    #expect(month.profit.quantity == 60)  // 130 + (-70)

    // Earmarked portion tracked separately
    #expect(month.earmarkedIncome.quantity == 30)
    #expect(month.earmarkedExpense.quantity == -20)
    #expect(month.earmarkedProfit.quantity == 10)
  }

  @Test("earmarked expense without accountId excluded from main expense total")
  func earmarkedExpenseNilAccountIdExcluded() async throws {
    let backend = try CloudKitAnalysisTestBackend()
    let account = Account(
      id: UUID(), name: "Checking", type: .bank, instrument: .defaultTestInstrument)
    _ = try await backend.accounts.create(account)

    let earmark = Earmark(id: UUID(), name: "Gift Fund", instrument: .defaultTestInstrument)
    _ = try await backend.earmarks.create(earmark)

    let today = AnalysisTestHelpers.currentCalendar.startOfDay(for: Date())

    _ = try await backend.transactions.create(
      Transaction(
        date: today, payee: "Shopping",
        legs: [
          TransactionLeg(
            accountId: account.id, instrument: .defaultTestInstrument,
            quantity: -80, type: .expense)
        ]))

    _ = try await backend.transactions.create(
      Transaction(
        date: today, payee: "Gift Expense",
        legs: [
          TransactionLeg(
            accountId: nil, instrument: .defaultTestInstrument,
            quantity: -25, type: .expense, earmarkId: earmark.id)
        ]))

    let data = try await backend.analysis.fetchIncomeAndExpense(monthEnd: 25, after: nil)

    #expect(!data.isEmpty)
    let month = data[0]

    // Main expense excludes nil-accountId leg (matching server's account_id IS NOT NULL)
    #expect(month.expense.quantity == -80)
    #expect(month.earmarkedExpense.quantity == -25)
  }

  @Test("openingBalance excluded from income/expense reports")
  func openingBalanceExcluded() async throws {
    let backend = try CloudKitAnalysisTestBackend()
    let account = Account(
      id: UUID(), name: "Checking", type: .bank, instrument: .defaultTestInstrument)
    _ = try await backend.accounts.create(account)

    let today = AnalysisTestHelpers.currentCalendar.startOfDay(for: Date())

    _ = try await backend.transactions.create(
      Transaction(
        date: today, payee: "Opening Balance",
        legs: [
          TransactionLeg(
            accountId: account.id, instrument: .defaultTestInstrument,
            quantity: 500, type: .openingBalance)
        ]))

    _ = try await backend.transactions.create(
      Transaction(
        date: today, payee: "Salary",
        legs: [
          TransactionLeg(
            accountId: account.id, instrument: .defaultTestInstrument,
            quantity: 100, type: .income)
        ]))

    let data = try await backend.analysis.fetchIncomeAndExpense(monthEnd: 25, after: nil)

    #expect(!data.isEmpty)
    let month = data[0]

    // openingBalance is excluded from income (matching server which only counts type='income')
    #expect(month.income.quantity == 100)
    #expect(month.expense.quantity == 0)
    #expect(month.earmarkedIncome.quantity == 0)
  }

  @Test("mixed earmarked with and without accountId matches server semantics")
  func mixedEarmarkedAccountIdSemantics() async throws {
    let backend = try CloudKitAnalysisTestBackend()
    let account = Account(
      id: UUID(), name: "Checking", type: .bank, instrument: .defaultTestInstrument)
    _ = try await backend.accounts.create(account)

    let earmark = Earmark(id: UUID(), name: "Savings", instrument: .defaultTestInstrument)
    _ = try await backend.earmarks.create(earmark)

    let today = AnalysisTestHelpers.currentCalendar.startOfDay(for: Date())
    try await seedMixedEarmarkedLegs(
      backend: backend, account: account, earmark: earmark, date: today)

    let data = try await backend.analysis.fetchIncomeAndExpense(monthEnd: 25, after: nil)

    #expect(!data.isEmpty)
    let month = data[0]

    // Main totals only include legs with accountId
    #expect(month.income.quantity == 200)
    #expect(month.expense.quantity == -80)

    // Earmarked totals include ALL earmarked legs regardless of accountId
    #expect(month.earmarkedIncome.quantity == 250)
    #expect(month.earmarkedExpense.quantity == -110)

    // Profit uses main totals
    #expect(month.profit.quantity == 120)
    #expect(month.earmarkedProfit.quantity == 140)
  }

  // MARK: - Helpers

  private func seedMixedEarmarkedLegs(
    backend: CloudKitAnalysisTestBackend,
    account: Account,
    earmark: Earmark,
    date: Date
  ) async throws {
    _ = try await backend.transactions.create(
      Transaction(
        date: date, payee: "Earmarked Salary",
        legs: [
          TransactionLeg(
            accountId: account.id, instrument: .defaultTestInstrument,
            quantity: 200, type: .income, earmarkId: earmark.id)
        ]))
    _ = try await backend.transactions.create(
      Transaction(
        date: date, payee: "Earmarked Gift",
        legs: [
          TransactionLeg(
            accountId: nil, instrument: .defaultTestInstrument,
            quantity: 50, type: .income, earmarkId: earmark.id)
        ]))
    _ = try await backend.transactions.create(
      Transaction(
        date: date, payee: "Earmarked Purchase",
        legs: [
          TransactionLeg(
            accountId: account.id, instrument: .defaultTestInstrument,
            quantity: -80, type: .expense, earmarkId: earmark.id)
        ]))
    _ = try await backend.transactions.create(
      Transaction(
        date: date, payee: "Earmarked Deduction",
        legs: [
          TransactionLeg(
            accountId: nil, instrument: .defaultTestInstrument,
            quantity: -30, type: .expense, earmarkId: earmark.id)
        ]))
  }
}
