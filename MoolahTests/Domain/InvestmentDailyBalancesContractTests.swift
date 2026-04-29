import Foundation
import SwiftData
import Testing

@testable import Moolah

@Suite("InvestmentRepository Daily Balances Contract")
struct InvestmentDailyBalancesContractTests {

  private func makeDate(year: Int, month: Int, day: Int) throws -> Date {
    try makeContractTestDate(year: year, month: month, day: day)
  }

  @Test(
    "Fetch daily balances computes cumulative balance from transactions sorted by date ascending")
  func testFetchDailyBalancesSorted() async throws {
    let date1 = try makeDate(year: 2024, month: 1, day: 15)
    let date2 = try makeDate(year: 2024, month: 2, day: 15)
    let date3 = try makeDate(year: 2024, month: 3, day: 15)
    let accountId = UUID()

    let (repo, container) = try makeCloudKitInvestmentRepositoryWithContainer()
    // Seed income transactions on three different dates
    _ = TestBackend.seed(
      transactions: [
        Transaction(
          date: date3,
          legs: [
            TransactionLeg(
              accountId: accountId, instrument: .defaultTestInstrument,
              quantity: Decimal(1000), type: .income)
          ]),
        Transaction(
          date: date1,
          legs: [
            TransactionLeg(
              accountId: accountId, instrument: .defaultTestInstrument,
              quantity: Decimal(500), type: .income)
          ]),
        Transaction(
          date: date2,
          legs: [
            TransactionLeg(
              accountId: accountId, instrument: .defaultTestInstrument,
              quantity: Decimal(750), type: .income)
          ]),
      ], in: container)

    let result = try await repo.fetchDailyBalances(accountId: accountId)
    #expect(result.count == 3)
    // Ascending order with cumulative balances: 500, 1250, 2250
    #expect(result[0].date == date1)
    #expect(result[0].balance.quantity == Decimal(500))
    #expect(result[1].date == date2)
    #expect(result[1].balance.quantity == Decimal(1250))
    #expect(result[2].date == date3)
    #expect(result[2].balance.quantity == Decimal(2250))
  }

  @Test("Fetch daily balances for empty account returns empty array")
  func testFetchDailyBalancesEmpty() async throws {
    let (repo, _) = try makeCloudKitInvestmentRepositoryWithContainer()
    let result = try await repo.fetchDailyBalances(accountId: UUID())
    #expect(result.isEmpty)
  }

  @Test("Fetch daily balances only returns balances for requested account")
  func testFetchDailyBalancesFiltersByAccount() async throws {
    let account1 = UUID()
    let account2 = UUID()
    let date = try makeDate(year: 2024, month: 1, day: 1)

    let (repo, container) = try makeCloudKitInvestmentRepositoryWithContainer()
    _ = TestBackend.seed(
      transactions: [
        Transaction(
          date: date,
          legs: [
            TransactionLeg(
              accountId: account1, instrument: .defaultTestInstrument,
              quantity: Decimal(1000), type: .income)
          ]),
        Transaction(
          date: date,
          legs: [
            TransactionLeg(
              accountId: account2, instrument: .defaultTestInstrument,
              quantity: Decimal(2000), type: .income)
          ]),
      ], in: container)

    let result = try await repo.fetchDailyBalances(accountId: account1)
    #expect(result.count == 1)
    #expect(result[0].balance.quantity == Decimal(1000))
  }

  @Test("Fetch daily balances includes transfers to this account")
  func testFetchDailyBalancesWithTransfers() async throws {
    let investmentAccount = UUID()
    let checkingAccount = UUID()
    let date1 = try makeDate(year: 2024, month: 1, day: 15)
    let date2 = try makeDate(year: 2024, month: 2, day: 15)

    let (repo, container) = try makeCloudKitInvestmentRepositoryWithContainer()
    _ = TestBackend.seed(
      transactions: [
        // Transfer $500 from checking to investment
        Transaction(
          date: date1,
          legs: [
            TransactionLeg(
              accountId: checkingAccount, instrument: .defaultTestInstrument,
              quantity: Decimal(-500), type: .transfer),
            TransactionLeg(
              accountId: investmentAccount, instrument: .defaultTestInstrument,
              quantity: Decimal(500), type: .transfer),
          ]),
        // Transfer $300 from checking to investment
        Transaction(
          date: date2,
          legs: [
            TransactionLeg(
              accountId: checkingAccount, instrument: .defaultTestInstrument,
              quantity: Decimal(-300), type: .transfer),
            TransactionLeg(
              accountId: investmentAccount, instrument: .defaultTestInstrument,
              quantity: Decimal(300), type: .transfer),
          ]),
      ], in: container)

    let result = try await repo.fetchDailyBalances(accountId: investmentAccount)
    #expect(result.count == 2)
    #expect(result[0].balance.quantity == Decimal(500))
    #expect(result[1].balance.quantity == Decimal(800))
  }

  @Test("Fetch daily balances excludes scheduled transactions")
  func testFetchDailyBalancesExcludesScheduled() async throws {
    let accountId = UUID()
    let date = try makeDate(year: 2024, month: 1, day: 15)

    let (repo, container) = try makeCloudKitInvestmentRepositoryWithContainer()
    _ = TestBackend.seed(
      transactions: [
        Transaction(
          date: date,
          legs: [
            TransactionLeg(
              accountId: accountId, instrument: .defaultTestInstrument,
              quantity: Decimal(1000), type: .income)
          ]),
        // Scheduled transaction should be excluded
        Transaction(
          date: date,
          recurPeriod: .month, recurEvery: 1,
          legs: [
            TransactionLeg(
              accountId: accountId, instrument: .defaultTestInstrument,
              quantity: Decimal(500), type: .income)
          ]),
      ], in: container)

    let result = try await repo.fetchDailyBalances(accountId: accountId)
    #expect(result.count == 1)
    #expect(result[0].balance.quantity == Decimal(1000))
  }

  @Test("Fetch daily balances handles positive-amount transfer from account correctly")
  func testFetchDailyBalancesPositiveTransferFrom() async throws {
    let investmentAccount = UUID()
    let otherAccount = UUID()
    let date1 = try makeDate(year: 2024, month: 1, day: 15)
    let date2 = try makeDate(year: 2024, month: 2, day: 15)

    let (repo, container) = try makeCloudKitInvestmentRepositoryWithContainer()
    _ = TestBackend.seed(
      transactions: [
        // Transfer $1000 into investment (negative amount = money leaving other)
        Transaction(
          date: date1,
          legs: [
            TransactionLeg(
              accountId: otherAccount, instrument: .defaultTestInstrument,
              quantity: Decimal(-1000), type: .transfer),
            TransactionLeg(
              accountId: investmentAccount, instrument: .defaultTestInstrument,
              quantity: Decimal(1000), type: .transfer),
          ]),
        // Positive-amount transfer FROM investment (e.g. dividend credit)
        // The investment account leg has positive quantity = money flowing in
        Transaction(
          date: date2,
          legs: [
            TransactionLeg(
              accountId: investmentAccount, instrument: .defaultTestInstrument,
              quantity: Decimal(500), type: .transfer),
            TransactionLeg(
              accountId: otherAccount, instrument: .defaultTestInstrument,
              quantity: Decimal(-500), type: .transfer),
          ]),
      ], in: container)

    let result = try await repo.fetchDailyBalances(accountId: investmentAccount)
    #expect(result.count == 2)
    // Day 1: +$1000
    #expect(result[0].balance.quantity == Decimal(1000))
    // Day 2: +$1000 + $500 = $1500 (positive transfer adds to balance)
    #expect(result[1].balance.quantity == Decimal(1500))
  }

  @Test("Fetch daily balances collapses multiple transactions on same day")
  func testFetchDailyBalancesSameDayCollapse() async throws {
    let accountId = UUID()
    let date = try makeDate(year: 2024, month: 3, day: 1)

    let (repo, container) = try makeCloudKitInvestmentRepositoryWithContainer()
    _ = TestBackend.seed(
      transactions: [
        Transaction(
          date: date,
          legs: [
            TransactionLeg(
              accountId: accountId, instrument: .defaultTestInstrument,
              quantity: Decimal(1000), type: .income)
          ]),
        Transaction(
          date: date,
          legs: [
            TransactionLeg(
              accountId: accountId, instrument: .defaultTestInstrument,
              quantity: Decimal(500), type: .income)
          ]),
      ], in: container)

    let result = try await repo.fetchDailyBalances(accountId: accountId)
    #expect(result.count == 1)
    #expect(result[0].balance.quantity == Decimal(1500))
  }

  @Test(
    "Fetch daily balances groups multi-instrument accounts by (date, instrument)")
  func testFetchDailyBalancesMultiInstrument() async throws {
    let accountId = UUID()
    let date1 = try makeDate(year: 2024, month: 1, day: 15)
    let date2 = try makeDate(year: 2024, month: 2, day: 15)
    let date3 = try makeDate(year: 2024, month: 3, day: 15)
    let aud = Instrument.AUD
    let usd = Instrument.USD

    let (repo, container) = try makeCloudKitInvestmentRepositoryWithContainer(
      instrument: aud)
    _ = TestBackend.seed(
      transactions: [
        // Day 1: 1000 AUD income
        Transaction(
          date: date1,
          legs: [
            TransactionLeg(
              accountId: accountId, instrument: aud,
              quantity: Decimal(1000), type: .income)
          ]),
        // Day 2: 500 USD income — different instrument, same account
        Transaction(
          date: date2,
          legs: [
            TransactionLeg(
              accountId: accountId, instrument: usd,
              quantity: Decimal(500), type: .income)
          ]),
        // Day 3: 250 AUD income — adds to AUD running balance
        Transaction(
          date: date3,
          legs: [
            TransactionLeg(
              accountId: accountId, instrument: aud,
              quantity: Decimal(250), type: .income)
          ]),
      ], in: container)

    let result = try await repo.fetchDailyBalances(accountId: accountId)

    // One entry per (date, instrument). AUD has entries on days 1 and 3,
    // USD has one on day 2.
    #expect(result.count == 3)

    let audDay1 = result.first { $0.date == date1 && $0.balance.instrument == aud }
    let usdDay2 = result.first { $0.date == date2 && $0.balance.instrument == usd }
    let audDay3 = result.first { $0.date == date3 && $0.balance.instrument == aud }

    #expect(audDay1?.balance.quantity == Decimal(1000))
    #expect(usdDay2?.balance.quantity == Decimal(500))
    #expect(audDay3?.balance.quantity == Decimal(1250))

    // No AUD entry on day 2, no USD entry on days 1 or 3.
    #expect(result.contains { $0.date == date2 && $0.balance.instrument == aud } == false)
    #expect(result.contains { $0.date == date1 && $0.balance.instrument == usd } == false)
    #expect(result.contains { $0.date == date3 && $0.balance.instrument == usd } == false)
  }
}
