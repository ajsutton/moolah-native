import Foundation
import Testing

@testable import Moolah

@Suite("InvestmentRepository Contract")
struct InvestmentRepositoryContractTests {

  private func makeRepository(
    values: [(Date, Int)] = [],
    accountId: UUID = UUID()
  ) -> (InMemoryInvestmentRepository, UUID) {
    let investmentValues = values.map { (date, cents) in
      InvestmentValue(
        date: date,
        value: MonetaryAmount(cents: cents, currency: Currency.defaultCurrency)
      )
    }
    let repo = InMemoryInvestmentRepository(
      initialValues: [accountId: investmentValues]
    )
    return (repo, accountId)
  }

  private func makeDate(year: Int, month: Int, day: Int) -> Date {
    Calendar.current.date(from: DateComponents(year: year, month: month, day: day))!
  }

  // MARK: - fetchValues

  @Test("Fetch values returns sorted by date descending")
  func testFetchValuesSortedByDate() async throws {
    let accountId = UUID()
    let dates = [
      makeDate(year: 2024, month: 1, day: 15),
      makeDate(year: 2024, month: 3, day: 15),
      makeDate(year: 2024, month: 2, day: 15),
    ]
    let values = dates.map { date in
      InvestmentValue(
        date: date,
        value: MonetaryAmount(cents: 100_000, currency: Currency.defaultCurrency)
      )
    }
    let repo = InMemoryInvestmentRepository(initialValues: [accountId: values])

    let page = try await repo.fetchValues(accountId: accountId, page: 0, pageSize: 50)

    #expect(page.values.count == 3)
    // Descending order: March, February, January
    #expect(page.values[0].date == dates[1])
    #expect(page.values[1].date == dates[2])
    #expect(page.values[2].date == dates[0])
  }

  @Test("Fetch values pagination works correctly")
  func testPagination() async throws {
    let accountId = UUID()
    let values = (0..<5).map { i in
      InvestmentValue(
        date: Calendar.current.date(byAdding: .day, value: -i, to: Date())!,
        value: MonetaryAmount(cents: 100_000 + (i * 1000), currency: Currency.defaultCurrency)
      )
    }
    let repo = InMemoryInvestmentRepository(initialValues: [accountId: values])

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
    let repo = InMemoryInvestmentRepository()
    let page = try await repo.fetchValues(accountId: UUID(), page: 0, pageSize: 50)
    #expect(page.values.isEmpty)
    #expect(page.hasMore == false)
  }

  @Test("Fetch values only returns values for requested account")
  func testFetchFiltersByAccount() async throws {
    let account1 = UUID()
    let account2 = UUID()
    let date = makeDate(year: 2024, month: 3, day: 15)

    let repo = InMemoryInvestmentRepository(initialValues: [
      account1: [
        InvestmentValue(
          date: date,
          value: MonetaryAmount(cents: 100_000, currency: Currency.defaultCurrency))
      ],
      account2: [
        InvestmentValue(
          date: date,
          value: MonetaryAmount(cents: 200_000, currency: Currency.defaultCurrency))
      ],
    ])

    let page = try await repo.fetchValues(accountId: account1, page: 0, pageSize: 50)
    #expect(page.values.count == 1)
    #expect(page.values[0].value.cents == 100_000)
  }

  // MARK: - setValue

  @Test("Set value creates new entry")
  func testSetValueCreatesNew() async throws {
    let repo = InMemoryInvestmentRepository()
    let accountId = UUID()
    let date = makeDate(year: 2024, month: 3, day: 15)
    let amount = MonetaryAmount(cents: 125_000_00, currency: Currency.defaultCurrency)

    try await repo.setValue(accountId: accountId, date: date, value: amount)

    let page = try await repo.fetchValues(accountId: accountId, page: 0, pageSize: 50)
    #expect(page.values.count == 1)
    #expect(page.values[0].date == date)
    #expect(page.values[0].value.cents == 125_000_00)
  }

  @Test("Set value upserts existing entry for same date")
  func testSetValueUpserts() async throws {
    let accountId = UUID()
    let date = makeDate(year: 2024, month: 3, day: 15)
    let (repo, _) = makeRepository(values: [(date, 100_000)], accountId: accountId)

    let newAmount = MonetaryAmount(cents: 200_000, currency: Currency.defaultCurrency)
    try await repo.setValue(accountId: accountId, date: date, value: newAmount)

    let page = try await repo.fetchValues(accountId: accountId, page: 0, pageSize: 50)
    #expect(page.values.count == 1)
    #expect(page.values[0].value.cents == 200_000)
  }

  // MARK: - removeValue

  @Test("Remove value deletes entry")
  func testRemoveValue() async throws {
    let accountId = UUID()
    let date = makeDate(year: 2024, month: 3, day: 15)
    let (repo, _) = makeRepository(values: [(date, 100_000)], accountId: accountId)

    try await repo.removeValue(accountId: accountId, date: date)

    let page = try await repo.fetchValues(accountId: accountId, page: 0, pageSize: 50)
    #expect(page.values.isEmpty)
  }

  @Test("Remove non-existent value throws notFound")
  func testRemoveNonExistent() async throws {
    let repo = InMemoryInvestmentRepository()

    await #expect(throws: BackendError.self) {
      try await repo.removeValue(accountId: UUID(), date: Date())
    }
  }

  // MARK: - Edge cases

  @Test("Fetch beyond last page returns empty")
  func testFetchBeyondLastPage() async throws {
    let accountId = UUID()
    let (repo, _) = makeRepository(
      values: [(makeDate(year: 2024, month: 1, day: 1), 100_000)],
      accountId: accountId
    )

    let page = try await repo.fetchValues(accountId: accountId, page: 1, pageSize: 50)
    #expect(page.values.isEmpty)
    #expect(page.hasMore == false)
  }
}
