import Foundation
import SwiftData
import Testing

@testable import Moolah

@Suite("InvestmentRepository Contract")
struct InvestmentRepositoryContractTests {

  private func makeDate(year: Int, month: Int, day: Int) -> Date {
    Calendar.current.date(from: DateComponents(year: year, month: month, day: day))!
  }

  // MARK: - fetchValues

  @Test("Fetch values returns sorted by date descending")
  func testFetchValuesSortedByDate() async throws {
    let dates = [
      makeDate(year: 2024, month: 1, day: 15),
      makeDate(year: 2024, month: 3, day: 15),
      makeDate(year: 2024, month: 2, day: 15),
    ]

    let repo = makeCloudKitInvestmentRepository(dates: dates)
    let accountId = await getAccountId(from: repo)
    let page = try await repo.fetchValues(accountId: accountId, page: 0, pageSize: 50)

    #expect(page.values.count == 3)
    // Descending order: March, February, January
    #expect(page.values[0].date == dates[1])
    #expect(page.values[1].date == dates[2])
    #expect(page.values[2].date == dates[0])
  }

  @Test("Fetch values pagination works correctly")
  func testPagination() async throws {
    let dates = (0..<5).map { i in
      Calendar.current.date(byAdding: .day, value: -i, to: makeDate(year: 2024, month: 6, day: 15))!
    }

    let repo = makeCloudKitInvestmentRepository(dates: dates)
    let accountId = await getAccountId(from: repo)

    let page0 = try await repo.fetchValues(accountId: accountId, page: 0, pageSize: 2)
    #expect(page0.values.count == 2)
    #expect(page0.hasMore == true)

    let page1 = try await repo.fetchValues(accountId: accountId, page: 1, pageSize: 2)
    #expect(page1.values.count == 2)
    #expect(page1.hasMore == true)

    let page2 = try await repo.fetchValues(accountId: accountId, page: 2, pageSize: 2)
    #expect(page2.values.count == 1)
    #expect(page2.hasMore == false)

    // No overlap between pages
    let page0Dates = Set(page0.values.map(\.date))
    let page1Dates = Set(page1.values.map(\.date))
    #expect(page0Dates.isDisjoint(with: page1Dates))
  }

  @Test("Fetch empty account returns empty page")
  func testFetchEmptyAccount() async throws {
    let repo = makeCloudKitInvestmentRepository()
    let page = try await repo.fetchValues(accountId: UUID(), page: 0, pageSize: 50)
    #expect(page.values.isEmpty)
    #expect(page.hasMore == false)
  }

  @Test("Fetch values only returns values for requested account")
  func testFetchFiltersByAccount() async throws {
    let date = makeDate(year: 2024, month: 3, day: 15)
    let account1 = UUID()
    let account2 = UUID()

    let ckRepo = makeCloudKitInvestmentRepository()
    try await ckRepo.setValue(
      accountId: account1, date: date,
      value: MonetaryAmount(cents: 100_000, currency: .defaultTestCurrency))
    try await ckRepo.setValue(
      accountId: account2, date: date,
      value: MonetaryAmount(cents: 200_000, currency: .defaultTestCurrency))

    let ckPage = try await ckRepo.fetchValues(accountId: account1, page: 0, pageSize: 50)
    #expect(ckPage.values.count == 1)
    #expect(ckPage.values[0].value.cents == 100_000)
  }

  // MARK: - setValue

  @Test("Set value creates new entry")
  func testSetValueCreatesNew() async throws {
    let repo = makeCloudKitInvestmentRepository()
    let date = makeDate(year: 2024, month: 3, day: 15)
    let amount = MonetaryAmount(cents: 125_000_00, currency: Currency.defaultTestCurrency)

    let accountId = UUID()
    try await repo.setValue(accountId: accountId, date: date, value: amount)

    let page = try await repo.fetchValues(accountId: accountId, page: 0, pageSize: 50)
    #expect(page.values.count == 1)
    #expect(page.values[0].date == date)
    #expect(page.values[0].value.cents == 125_000_00)
  }

  @Test("Set value upserts existing entry for same date")
  func testSetValueUpserts() async throws {
    let date = makeDate(year: 2024, month: 3, day: 15)
    let accountId = UUID()

    let repo = makeCloudKitInvestmentRepository(dates: [date], accountId: accountId)
    let newAmount = MonetaryAmount(cents: 200_000, currency: Currency.defaultTestCurrency)

    try await repo.setValue(accountId: accountId, date: date, value: newAmount)

    let page = try await repo.fetchValues(accountId: accountId, page: 0, pageSize: 50)
    #expect(page.values.count == 1)
    #expect(page.values[0].value.cents == 200_000)
  }

  // MARK: - removeValue

  @Test("Remove value deletes entry")
  func testRemoveValue() async throws {
    let date = makeDate(year: 2024, month: 3, day: 15)
    let accountId = UUID()

    let repo = makeCloudKitInvestmentRepository(dates: [date], accountId: accountId)
    try await repo.removeValue(accountId: accountId, date: date)

    let page = try await repo.fetchValues(accountId: accountId, page: 0, pageSize: 50)
    #expect(page.values.isEmpty)
  }

  @Test("Remove non-existent value throws notFound")
  func testRemoveNonExistent() async throws {
    let repo = makeCloudKitInvestmentRepository()
    await #expect(throws: BackendError.self) {
      try await repo.removeValue(accountId: UUID(), date: Date())
    }
  }

  // MARK: - Edge cases

  @Test("Fetch beyond last page returns empty")
  func testFetchBeyondLastPage() async throws {
    let date = makeDate(year: 2024, month: 1, day: 1)
    let accountId = UUID()

    let repo = makeCloudKitInvestmentRepository(dates: [date], accountId: accountId)
    let page = try await repo.fetchValues(accountId: accountId, page: 1, pageSize: 50)
    #expect(page.values.isEmpty)
    #expect(page.hasMore == false)
  }

  // MARK: - fetchDailyBalances

  @Test(
    "Fetch daily balances computes cumulative balance from transactions sorted by date ascending")
  func testFetchDailyBalancesSorted() async throws {
    let date1 = makeDate(year: 2024, month: 1, day: 15)
    let date2 = makeDate(year: 2024, month: 2, day: 15)
    let date3 = makeDate(year: 2024, month: 3, day: 15)
    let accountId = UUID()

    let (repo, container) = makeCloudKitInvestmentRepositoryWithContainer()
    // Seed income transactions on three different dates
    TestBackend.seed(
      transactions: [
        Transaction(
          id: UUID(), type: .income, date: date3, accountId: accountId,
          amount: MonetaryAmount(cents: 100_000, currency: .defaultTestCurrency)),
        Transaction(
          id: UUID(), type: .income, date: date1, accountId: accountId,
          amount: MonetaryAmount(cents: 50_000, currency: .defaultTestCurrency)),
        Transaction(
          id: UUID(), type: .income, date: date2, accountId: accountId,
          amount: MonetaryAmount(cents: 75_000, currency: .defaultTestCurrency)),
      ], in: container)

    let result = try await repo.fetchDailyBalances(accountId: accountId)
    #expect(result.count == 3)
    // Ascending order with cumulative balances: 50k, 125k, 225k
    #expect(result[0].date == date1)
    #expect(result[0].balance.cents == 50_000)
    #expect(result[1].date == date2)
    #expect(result[1].balance.cents == 125_000)
    #expect(result[2].date == date3)
    #expect(result[2].balance.cents == 225_000)
  }

  @Test("Fetch daily balances for empty account returns empty array")
  func testFetchDailyBalancesEmpty() async throws {
    let (repo, _) = makeCloudKitInvestmentRepositoryWithContainer()
    let result = try await repo.fetchDailyBalances(accountId: UUID())
    #expect(result.isEmpty)
  }

  @Test("Fetch daily balances only returns balances for requested account")
  func testFetchDailyBalancesFiltersByAccount() async throws {
    let account1 = UUID()
    let account2 = UUID()
    let date = makeDate(year: 2024, month: 1, day: 1)

    let (repo, container) = makeCloudKitInvestmentRepositoryWithContainer()
    TestBackend.seed(
      transactions: [
        Transaction(
          id: UUID(), type: .income, date: date, accountId: account1,
          amount: MonetaryAmount(cents: 100_000, currency: .defaultTestCurrency)),
        Transaction(
          id: UUID(), type: .income, date: date, accountId: account2,
          amount: MonetaryAmount(cents: 200_000, currency: .defaultTestCurrency)),
      ], in: container)

    let result = try await repo.fetchDailyBalances(accountId: account1)
    #expect(result.count == 1)
    #expect(result[0].balance.cents == 100_000)
  }

  @Test("Fetch daily balances includes transfers to this account")
  func testFetchDailyBalancesWithTransfers() async throws {
    let investmentAccount = UUID()
    let checkingAccount = UUID()
    let date1 = makeDate(year: 2024, month: 1, day: 15)
    let date2 = makeDate(year: 2024, month: 2, day: 15)

    let (repo, container) = makeCloudKitInvestmentRepositoryWithContainer()
    TestBackend.seed(
      transactions: [
        // Transfer $500 from checking to investment
        Transaction(
          id: UUID(), type: .transfer, date: date1,
          accountId: checkingAccount, toAccountId: investmentAccount,
          amount: MonetaryAmount(cents: -50_000, currency: .defaultTestCurrency)),
        // Transfer $300 from checking to investment
        Transaction(
          id: UUID(), type: .transfer, date: date2,
          accountId: checkingAccount, toAccountId: investmentAccount,
          amount: MonetaryAmount(cents: -30_000, currency: .defaultTestCurrency)),
      ], in: container)

    let result = try await repo.fetchDailyBalances(accountId: investmentAccount)
    #expect(result.count == 2)
    #expect(result[0].balance.cents == 50_000)
    #expect(result[1].balance.cents == 80_000)
  }

  @Test("Fetch daily balances excludes scheduled transactions")
  func testFetchDailyBalancesExcludesScheduled() async throws {
    let accountId = UUID()
    let date = makeDate(year: 2024, month: 1, day: 15)

    let (repo, container) = makeCloudKitInvestmentRepositoryWithContainer()
    TestBackend.seed(
      transactions: [
        Transaction(
          id: UUID(), type: .income, date: date, accountId: accountId,
          amount: MonetaryAmount(cents: 100_000, currency: .defaultTestCurrency)),
        // Scheduled transaction should be excluded
        Transaction(
          id: UUID(), type: .income, date: date, accountId: accountId,
          amount: MonetaryAmount(cents: 50_000, currency: .defaultTestCurrency),
          recurPeriod: .month, recurEvery: 1),
      ], in: container)

    let result = try await repo.fetchDailyBalances(accountId: accountId)
    #expect(result.count == 1)
    #expect(result[0].balance.cents == 100_000)
  }

  @Test("Fetch daily balances handles positive-amount transfer from account correctly")
  func testFetchDailyBalancesPositiveTransferFrom() async throws {
    let investmentAccount = UUID()
    let otherAccount = UUID()
    let date1 = makeDate(year: 2024, month: 1, day: 15)
    let date2 = makeDate(year: 2024, month: 2, day: 15)

    let (repo, container) = makeCloudKitInvestmentRepositoryWithContainer()
    TestBackend.seed(
      transactions: [
        // Transfer $1000 into investment (negative amount = money leaving checking)
        Transaction(
          id: UUID(), type: .transfer, date: date1,
          accountId: otherAccount, toAccountId: investmentAccount,
          amount: MonetaryAmount(cents: -100_000, currency: .defaultTestCurrency)),
        // Positive-amount transfer FROM investment (e.g. dividend credit)
        // amount is positive from accountId's perspective = money flowing in
        Transaction(
          id: UUID(), type: .transfer, date: date2,
          accountId: investmentAccount, toAccountId: otherAccount,
          amount: MonetaryAmount(cents: 50_000, currency: .defaultTestCurrency)),
      ], in: container)

    let result = try await repo.fetchDailyBalances(accountId: investmentAccount)
    #expect(result.count == 2)
    // Day 1: +$1000
    #expect(result[0].balance.cents == 100_000)
    // Day 2: +$1000 + $500 = $1500 (positive transfer adds to balance)
    #expect(result[1].balance.cents == 150_000)
  }

  @Test("Fetch daily balances collapses multiple transactions on same day")
  func testFetchDailyBalancesSameDayCollapse() async throws {
    let accountId = UUID()
    let date = makeDate(year: 2024, month: 3, day: 1)

    let (repo, container) = makeCloudKitInvestmentRepositoryWithContainer()
    TestBackend.seed(
      transactions: [
        Transaction(
          id: UUID(), type: .income, date: date, accountId: accountId,
          amount: MonetaryAmount(cents: 100_000, currency: .defaultTestCurrency)),
        Transaction(
          id: UUID(), type: .income, date: date, accountId: accountId,
          amount: MonetaryAmount(cents: 50_000, currency: .defaultTestCurrency)),
      ], in: container)

    let result = try await repo.fetchDailyBalances(accountId: accountId)
    #expect(result.count == 1)
    #expect(result[0].balance.cents == 150_000)
  }
}

// MARK: - Factory Helpers

/// Returns a stable accountId used across repos for seeded-data tests.
private let sharedAccountId = UUID()

/// Helper to extract the account ID from a seeded CloudKit repo.
/// For loop-based tests where accountId was seeded separately.
private func getAccountId(from repo: any InvestmentRepository) async -> UUID {
  // This is only called on repos built with makeCloudKitInvestmentRepository
  // which uses sharedAccountId — we return it directly.
  return sharedAccountId
}

private func makeCloudKitInvestmentRepository(
  dates: [Date] = [],
  accountId: UUID = sharedAccountId,
  cents: Int = 100_000,
  currency: Currency = .defaultTestCurrency
) -> CloudKitInvestmentRepository {
  let container = try! TestModelContainer.create()
  let repo = CloudKitInvestmentRepository(
    modelContainer: container, currency: currency)

  if !dates.isEmpty {
    let context = ModelContext(container)
    for date in dates {
      let record = InvestmentValueRecord(
        accountId: accountId,
        date: date,
        value: cents,
        currencyCode: currency.code
      )
      context.insert(record)
    }
    try! context.save()
  }

  return repo
}

private func makeCloudKitInvestmentRepositoryWithContainer(
  currency: Currency = .defaultTestCurrency
) -> (CloudKitInvestmentRepository, ModelContainer) {
  let container = try! TestModelContainer.create()
  let repo = CloudKitInvestmentRepository(
    modelContainer: container, currency: currency)
  return (repo, container)
}
