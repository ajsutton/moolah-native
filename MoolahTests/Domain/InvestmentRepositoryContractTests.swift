import Foundation
import SwiftData
import Testing

@testable import Moolah

@Suite("InvestmentRepository Contract")
struct InvestmentRepositoryContractTests {

  private func makeDate(year: Int, month: Int, day: Int) throws -> Date {
    try makeContractTestDate(year: year, month: month, day: day)
  }

  // MARK: - fetchValues

  @Test("Fetch values returns sorted by date descending")
  func testFetchValuesSortedByDate() async throws {
    let dates = [
      try makeDate(year: 2024, month: 1, day: 15),
      try makeDate(year: 2024, month: 3, day: 15),
      try makeDate(year: 2024, month: 2, day: 15),
    ]

    let repo = try makeCloudKitInvestmentRepository(dates: dates)
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
    let base = try makeDate(year: 2024, month: 6, day: 15)
    let dates = try (0..<5).map { i in
      try #require(Calendar.current.date(byAdding: .day, value: -i, to: base))
    }

    let repo = try makeCloudKitInvestmentRepository(dates: dates)
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
    let repo = try makeCloudKitInvestmentRepository()
    let page = try await repo.fetchValues(accountId: UUID(), page: 0, pageSize: 50)
    #expect(page.values.isEmpty)
    #expect(page.hasMore == false)
  }

  @Test("Fetch values only returns values for requested account")
  func testFetchFiltersByAccount() async throws {
    let date = try makeDate(year: 2024, month: 3, day: 15)
    let account1 = UUID()
    let account2 = UUID()

    let ckRepo = try makeCloudKitInvestmentRepository()
    try await ckRepo.setValue(
      accountId: account1, date: date,
      value: InstrumentAmount(quantity: Decimal(1000), instrument: .defaultTestInstrument))
    try await ckRepo.setValue(
      accountId: account2, date: date,
      value: InstrumentAmount(quantity: Decimal(2000), instrument: .defaultTestInstrument))

    let ckPage = try await ckRepo.fetchValues(accountId: account1, page: 0, pageSize: 50)
    #expect(ckPage.values.count == 1)
    #expect(ckPage.values[0].value.quantity == Decimal(1000))
  }

  // MARK: - setValue

  @Test("Set value creates new entry")
  func testSetValueCreatesNew() async throws {
    let repo = try makeCloudKitInvestmentRepository()
    let date = try makeDate(year: 2024, month: 3, day: 15)
    let amount = InstrumentAmount(
      quantity: Decimal(125_000), instrument: .defaultTestInstrument)

    let accountId = UUID()
    try await repo.setValue(accountId: accountId, date: date, value: amount)

    let page = try await repo.fetchValues(accountId: accountId, page: 0, pageSize: 50)
    #expect(page.values.count == 1)
    #expect(page.values[0].date == date)
    #expect(page.values[0].value.quantity == Decimal(125_000))
  }

  @Test("Set value upserts existing entry for same date")
  func testSetValueUpserts() async throws {
    let date = try makeDate(year: 2024, month: 3, day: 15)
    let accountId = UUID()

    let repo = try makeCloudKitInvestmentRepository(dates: [date], accountId: accountId)
    let newAmount = InstrumentAmount(
      quantity: Decimal(2000), instrument: .defaultTestInstrument)

    try await repo.setValue(accountId: accountId, date: date, value: newAmount)

    let page = try await repo.fetchValues(accountId: accountId, page: 0, pageSize: 50)
    #expect(page.values.count == 1)
    #expect(page.values[0].value.quantity == Decimal(2000))
  }

  @Test("Set value upserts when dates have different times on same day")
  func testSetValueUpsertsWithDifferentTimes() async throws {
    let accountId = UUID()
    let repo = try makeCloudKitInvestmentRepository()

    let morning = try #require(
      Calendar.current.date(
        from: DateComponents(year: 2024, month: 3, day: 15, hour: 9, minute: 0)))
    let evening = try #require(
      Calendar.current.date(
        from: DateComponents(year: 2024, month: 3, day: 15, hour: 18, minute: 30)))

    let firstAmount = InstrumentAmount(
      quantity: Decimal(1000), instrument: .defaultTestInstrument)
    let secondAmount = InstrumentAmount(
      quantity: Decimal(2000), instrument: .defaultTestInstrument)

    try await repo.setValue(accountId: accountId, date: morning, value: firstAmount)
    try await repo.setValue(accountId: accountId, date: evening, value: secondAmount)

    let page = try await repo.fetchValues(accountId: accountId, page: 0, pageSize: 50)
    #expect(page.values.count == 1, "Expected upsert but got duplicate entries")
    #expect(page.values[0].value.quantity == Decimal(2000))
  }

  // MARK: - removeValue

  @Test("Remove value deletes entry")
  func testRemoveValue() async throws {
    let date = try makeDate(year: 2024, month: 3, day: 15)
    let accountId = UUID()

    let repo = try makeCloudKitInvestmentRepository(dates: [date], accountId: accountId)
    try await repo.removeValue(accountId: accountId, date: date)

    let page = try await repo.fetchValues(accountId: accountId, page: 0, pageSize: 50)
    #expect(page.values.isEmpty)
  }

  @Test("Remove non-existent value throws notFound")
  func testRemoveNonExistent() async throws {
    let repo = try makeCloudKitInvestmentRepository()
    await #expect(throws: BackendError.self) {
      try await repo.removeValue(accountId: UUID(), date: Date())
    }
  }

  // MARK: - Edge cases

  @Test("Fetch beyond last page returns empty")
  func testFetchBeyondLastPage() async throws {
    let date = try makeDate(year: 2024, month: 1, day: 1)
    let accountId = UUID()

    let repo = try makeCloudKitInvestmentRepository(dates: [date], accountId: accountId)
    let page = try await repo.fetchValues(accountId: accountId, page: 1, pageSize: 50)
    #expect(page.values.isEmpty)
    #expect(page.hasMore == false)
  }

  // MARK: - Multi-instrument investment values

  @Test("Investment values preserve USD instrument through round-trip")
  func testSetAndFetchValueInUSD() async throws {
    let repo = try makeCloudKitInvestmentRepository(instrument: .USD)
    let date = try makeDate(year: 2024, month: 3, day: 15)
    let accountId = UUID()
    let amount = InstrumentAmount(quantity: Decimal(5000), instrument: .USD)
    try await repo.setValue(accountId: accountId, date: date, value: amount)

    let page = try await repo.fetchValues(accountId: accountId, page: 0, pageSize: 10)
    #expect(page.values.count == 1)
    #expect(page.values[0].value.instrument == .USD)
    #expect(page.values[0].value.quantity == Decimal(5000))
  }

  @Test("Setting values on separate repositories with different instruments does not conflate them")
  func testDistinctInstrumentsAcrossRepositories() async throws {
    let audRepo = try makeCloudKitInvestmentRepository(instrument: .AUD)
    let usdRepo = try makeCloudKitInvestmentRepository(instrument: .USD)
    let date = try makeDate(year: 2024, month: 3, day: 15)
    let audAccount = UUID()
    let usdAccount = UUID()

    try await audRepo.setValue(
      accountId: audAccount, date: date,
      value: InstrumentAmount(quantity: Decimal(1000), instrument: .AUD))
    try await usdRepo.setValue(
      accountId: usdAccount, date: date,
      value: InstrumentAmount(quantity: Decimal(650), instrument: .USD))

    let audPage = try await audRepo.fetchValues(accountId: audAccount, page: 0, pageSize: 10)
    let usdPage = try await usdRepo.fetchValues(accountId: usdAccount, page: 0, pageSize: 10)
    #expect(audPage.values.first?.value.instrument == .AUD)
    #expect(usdPage.values.first?.value.instrument == .USD)
  }
}
