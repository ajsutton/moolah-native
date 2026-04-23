import Foundation
import SwiftData
import Testing

@testable import Moolah

/// Contract tests for investment-value override behaviour and bestFit linear
/// regression over `dailyBalance` history.
@Suite("AnalysisRepository Contract Tests — Investment Value")
struct AnalysisInvestmentValueTests {

  @Test("fetchDailyBalances computes investmentValue from investment values")
  func dailyBalancesInvestmentValue() async throws {
    let backend = try CloudKitAnalysisTestBackend()
    let investmentAccount = Account(
      id: UUID(), name: "Portfolio", type: .investment, instrument: .defaultTestInstrument)
    _ = try await backend.accounts.create(investmentAccount)

    let bankAccount = Account(
      id: UUID(), name: "Bank", type: .bank, instrument: .defaultTestInstrument)
    _ = try await backend.accounts.create(bankAccount)

    let day1 = try AnalysisTestHelpers.date(year: 2025, month: 3, day: 1)
    _ = try await backend.transactions.create(
      Transaction(
        date: day1, payee: "Invest",
        legs: [
          TransactionLeg(
            accountId: bankAccount.id, instrument: .defaultTestInstrument,
            quantity: -500, type: .transfer),
          TransactionLeg(
            accountId: investmentAccount.id, instrument: .defaultTestInstrument,
            quantity: 500, type: .transfer),
        ]))

    let day2 = try AnalysisTestHelpers.date(year: 2025, month: 3, day: 2)
    try await backend.investments.setValue(
      accountId: investmentAccount.id,
      date: day2,
      value: InstrumentAmount(quantity: 550, instrument: .defaultTestInstrument))

    _ = try await backend.transactions.create(
      Transaction(
        date: day2, payee: "Interest",
        legs: [
          TransactionLeg(
            accountId: bankAccount.id, instrument: .defaultTestInstrument,
            quantity: 10, type: .income)
        ]))

    let balances = try await backend.analysis.fetchDailyBalances(after: nil, forecastUntil: nil)

    let day2Start = AnalysisTestHelpers.calendar.startOfDay(for: day2)
    let day2Balance = try #require(balances.first { $0.date == day2Start })
    let day2InvestmentValue = try #require(day2Balance.investmentValue)
    #expect(
      day2InvestmentValue == InstrumentAmount(quantity: 550, instrument: .defaultTestInstrument),
      "investmentValue should reflect the recorded market value")
    #expect(
      day2Balance.netWorth == day2Balance.balance + day2InvestmentValue,
      "netWorth should be balance + investmentValue")
  }

  @Test("fetchDailyBalances computes bestFit linear regression")
  func dailyBalancesBestFit() async throws {
    let backend = try CloudKitAnalysisTestBackend()
    let account = Account(
      id: UUID(), name: "Test Account", type: .bank, instrument: .defaultTestInstrument)
    _ = try await backend.accounts.create(account)

    let day1 = try AnalysisTestHelpers.date(year: 2025, month: 3, day: 1)
    let day2 = try AnalysisTestHelpers.date(year: 2025, month: 3, day: 2)
    let day3 = try AnalysisTestHelpers.date(year: 2025, month: 3, day: 3)
    let tolerance = try AnalysisTestHelpers.decimal("0.01")

    for date in [day1, day2, day3] {
      _ = try await backend.transactions.create(
        Transaction(
          date: date, payee: "Daily",
          legs: [
            TransactionLeg(
              accountId: account.id, instrument: .defaultTestInstrument,
              quantity: 10, type: .income)
          ]))
    }

    let balances = try await backend.analysis.fetchDailyBalances(after: nil, forecastUntil: nil)

    for balance in balances {
      #expect(balance.bestFit != nil, "bestFit should be computed for each daily balance")
    }

    let day1Start = AnalysisTestHelpers.calendar.startOfDay(for: day1)
    let day3Start = AnalysisTestHelpers.calendar.startOfDay(for: day3)
    let day1Balance = try #require(balances.first { $0.date == day1Start })
    let day3Balance = try #require(balances.first { $0.date == day3Start })
    let day1Fit = try #require(day1Balance.bestFit)
    let day3Fit = try #require(day3Balance.bestFit)

    #expect(abs(day1Fit.quantity - 10) <= tolerance)
    #expect(abs(day3Fit.quantity - 30) <= tolerance)
  }

  @Test("fetchDailyBalances returns nil bestFit with fewer than 2 data points")
  func dailyBalancesBestFitSinglePoint() async throws {
    let backend = try CloudKitAnalysisTestBackend()
    let account = Account(
      id: UUID(), name: "Test Account", type: .bank, instrument: .defaultTestInstrument)
    _ = try await backend.accounts.create(account)

    _ = try await backend.transactions.create(
      Transaction(
        date: Date(), payee: "Single",
        legs: [
          TransactionLeg(
            accountId: account.id, instrument: .defaultTestInstrument,
            quantity: 10, type: .income)
        ]))

    let balances = try await backend.analysis.fetchDailyBalances(after: nil, forecastUntil: nil)
    #expect(balances.count == 1)
    #expect(balances[0].bestFit == nil, "bestFit should be nil with only 1 data point")
  }
}
