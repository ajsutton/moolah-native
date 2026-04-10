import Foundation
import SwiftData
import Testing

@testable import Moolah

@Suite("TransactionRepository Contract")
struct TransactionRepositoryContractTests {
  @Test(
    "filters by date range",
    arguments: [
      InMemoryTransactionRepository(initialTransactions: makeTestTransactions())
        as any TransactionRepository,
      makeCloudKitTransactionRepository(initialTransactions: makeTestTransactions())
        as any TransactionRepository,
    ])
  func testFiltersByDateRange(repository: any TransactionRepository) async throws {
    let calendar = Calendar.current
    let middleDate = calendar.date(from: DateComponents(year: 2024, month: 6, day: 15))!
    let startDate = calendar.date(byAdding: .day, value: -30, to: middleDate)!
    let endDate = calendar.date(byAdding: .day, value: 30, to: middleDate)!
    let dateRange = startDate...endDate

    let page = try await repository.fetch(
      filter: TransactionFilter(dateRange: dateRange),
      page: 0,
      pageSize: 50
    )

    // Should only include transactions within the date range
    for transaction in page.transactions {
      #expect(dateRange.contains(transaction.date))
    }
  }

  @Test(
    "filters by category IDs",
    arguments: [
      InMemoryTransactionRepository(initialTransactions: makeTestTransactions())
        as any TransactionRepository,
      makeCloudKitTransactionRepository(initialTransactions: makeTestTransactions())
        as any TransactionRepository,
    ])
  func testFiltersByCategoryIds(repository: any TransactionRepository) async throws {
    let transactions = makeTestTransactions()
    let groceryCategory = transactions[0].categoryId!
    let categoryIds: Set<UUID> = [groceryCategory]

    let page = try await repository.fetch(
      filter: TransactionFilter(categoryIds: categoryIds),
      page: 0,
      pageSize: 50
    )

    // Should only include transactions with the specified category
    for transaction in page.transactions {
      #expect(categoryIds.contains(transaction.categoryId!))
    }
  }

  @Test(
    "filters by payee (case-insensitive contains)",
    arguments: [
      InMemoryTransactionRepository(initialTransactions: makeTestTransactions())
        as any TransactionRepository,
      makeCloudKitTransactionRepository(initialTransactions: makeTestTransactions())
        as any TransactionRepository,
    ])
  func testFiltersByPayee(repository: any TransactionRepository) async throws {
    let page = try await repository.fetch(
      filter: TransactionFilter(payee: "wool"),
      page: 0,
      pageSize: 50
    )

    // Should include "Woolworths" (case-insensitive contains match)
    #expect(page.transactions.count > 0)
    for transaction in page.transactions {
      let payee = transaction.payee?.lowercased() ?? ""
      #expect(payee.contains("wool"))
    }
  }

  @Test(
    "combines multiple filters",
    arguments: [
      InMemoryTransactionRepository(initialTransactions: makeTestTransactions())
        as any TransactionRepository,
      makeCloudKitTransactionRepository(initialTransactions: makeTestTransactions())
        as any TransactionRepository,
    ])
  func testCombinesMultipleFilters(repository: any TransactionRepository) async throws {
    let transactions = makeTestTransactions()
    let groceryCategory = transactions[0].categoryId!
    let calendar = Calendar.current
    let middleDate = calendar.date(from: DateComponents(year: 2024, month: 6, day: 15))!
    let startDate = calendar.date(byAdding: .day, value: -30, to: middleDate)!
    let endDate = calendar.date(byAdding: .day, value: 30, to: middleDate)!

    let page = try await repository.fetch(
      filter: TransactionFilter(
        dateRange: startDate...endDate,
        categoryIds: [groceryCategory],
        payee: "wool"
      ),
      page: 0,
      pageSize: 50
    )

    // Should satisfy all filter criteria
    for transaction in page.transactions {
      #expect(transaction.categoryId == groceryCategory)
      #expect((startDate...endDate).contains(transaction.date))
      let payee = transaction.payee?.lowercased() ?? ""
      #expect(payee.contains("wool"))
    }
  }

  @Test(
    "returns empty when no matches",
    arguments: [
      InMemoryTransactionRepository(initialTransactions: makeTestTransactions())
        as any TransactionRepository,
      makeCloudKitTransactionRepository(initialTransactions: makeTestTransactions())
        as any TransactionRepository,
    ])
  func testReturnsEmptyWhenNoMatches(repository: any TransactionRepository) async throws {
    let page = try await repository.fetch(
      filter: TransactionFilter(payee: "NonexistentPayee"),
      page: 0,
      pageSize: 50
    )

    #expect(page.transactions.isEmpty)
  }

  @Test(
    "clearing filter reloads all",
    arguments: [
      InMemoryTransactionRepository(initialTransactions: makeTestTransactions())
        as any TransactionRepository,
      makeCloudKitTransactionRepository(initialTransactions: makeTestTransactions())
        as any TransactionRepository,
    ])
  func testClearingFilterReloadsAll(repository: any TransactionRepository) async throws {
    // First apply a filter
    let filteredPage = try await repository.fetch(
      filter: TransactionFilter(payee: "Woolworths"),
      page: 0,
      pageSize: 50
    )

    // Then clear the filter
    let allPage = try await repository.fetch(
      filter: TransactionFilter(),
      page: 0,
      pageSize: 50
    )

    #expect(allPage.transactions.count >= filteredPage.transactions.count)
  }

  @Test(
    "priorBalance is sum of transactions before the page",
    arguments: [
      InMemoryTransactionRepository(initialTransactions: makePaginationTestTransactions())
        as any TransactionRepository,
      makeCloudKitTransactionRepository(initialTransactions: makePaginationTestTransactions())
        as any TransactionRepository,
    ])
  func testPriorBalanceAcrossPages(repository: any TransactionRepository) async throws {
    let page0 = try await repository.fetch(
      filter: TransactionFilter(),
      page: 0,
      pageSize: 2
    )

    let page1 = try await repository.fetch(
      filter: TransactionFilter(),
      page: 1,
      pageSize: 2
    )

    // priorBalance for page 0 should be sum of transactions on page 1+
    let page1Sum = page1.transactions.reduce(
      MonetaryAmount(cents: 0, currency: .defaultTestCurrency)
    ) {
      $0 + $1.amount
    }
    let page1PriorSum = page1Sum + page1.priorBalance

    #expect(
      page0.priorBalance == page1PriorSum,
      "priorBalance of page 0 should equal sum of all older transactions")
  }

  @Test(
    "empty page returns zero priorBalance",
    arguments: [
      InMemoryTransactionRepository(initialTransactions: makePaginationTestTransactions())
        as any TransactionRepository,
      makeCloudKitTransactionRepository(initialTransactions: makePaginationTestTransactions())
        as any TransactionRepository,
    ])
  func testEmptyPagePriorBalance(repository: any TransactionRepository) async throws {
    let page = try await repository.fetch(
      filter: TransactionFilter(),
      page: 100,
      pageSize: 10
    )

    #expect(page.transactions.isEmpty)
    #expect(page.priorBalance.cents == 0)
  }
}

// Helper function to create test transactions with various attributes
private func makeTestTransactions() -> [Transaction] {
  let accountId = UUID()
  let groceryCategoryId = UUID()
  let transportCategoryId = UUID()
  let earmarkId = UUID()
  let calendar = Calendar.current

  let transactions: [Transaction] = [
    // Grocery expense in June
    Transaction(
      type: .expense,
      date: calendar.date(from: DateComponents(year: 2024, month: 6, day: 15))!,
      accountId: accountId,
      amount: MonetaryAmount(cents: -5023, currency: Currency.defaultTestCurrency),
      payee: "Woolworths",
      categoryId: groceryCategoryId
    ),
    // Transport expense in July
    Transaction(
      type: .expense,
      date: calendar.date(from: DateComponents(year: 2024, month: 7, day: 10))!,
      accountId: accountId,
      amount: MonetaryAmount(cents: -3500, currency: Currency.defaultTestCurrency),
      payee: "Metro Transport",
      categoryId: transportCategoryId
    ),
    // Income in May
    Transaction(
      type: .income,
      date: calendar.date(from: DateComponents(year: 2024, month: 5, day: 30))!,
      accountId: accountId,
      amount: MonetaryAmount(cents: 350000, currency: Currency.defaultTestCurrency),
      payee: "Employer Pty Ltd"
    ),
    // Grocery expense in April (older, different payee)
    Transaction(
      type: .expense,
      date: calendar.date(from: DateComponents(year: 2024, month: 4, day: 20))!,
      accountId: accountId,
      amount: MonetaryAmount(cents: -4200, currency: Currency.defaultTestCurrency),
      payee: "Coles",
      categoryId: groceryCategoryId
    ),
    // Earmarked expense in June
    Transaction(
      type: .expense,
      date: calendar.date(from: DateComponents(year: 2024, month: 6, day: 20))!,
      accountId: accountId,
      amount: MonetaryAmount(cents: -10000, currency: Currency.defaultTestCurrency),
      payee: "Electronics Store",
      categoryId: transportCategoryId,
      earmarkId: earmarkId
    ),
  ]

  return transactions
}

private func makePaginationTestTransactions() -> [Transaction] {
  let accountId = UUID()
  let calendar = Calendar.current
  return [
    Transaction(
      type: .income,
      date: calendar.date(from: DateComponents(year: 2024, month: 1, day: 1))!,
      accountId: accountId,
      amount: MonetaryAmount(cents: 1000, currency: .defaultTestCurrency),
      payee: "Jan Income"
    ),
    Transaction(
      type: .expense,
      date: calendar.date(from: DateComponents(year: 2024, month: 2, day: 1))!,
      accountId: accountId,
      amount: MonetaryAmount(cents: -300, currency: .defaultTestCurrency),
      payee: "Feb Expense"
    ),
    Transaction(
      type: .income,
      date: calendar.date(from: DateComponents(year: 2024, month: 3, day: 1))!,
      accountId: accountId,
      amount: MonetaryAmount(cents: 2000, currency: .defaultTestCurrency),
      payee: "Mar Income"
    ),
    Transaction(
      type: .expense,
      date: calendar.date(from: DateComponents(year: 2024, month: 4, day: 1))!,
      accountId: accountId,
      amount: MonetaryAmount(cents: -500, currency: .defaultTestCurrency),
      payee: "Apr Expense"
    ),
  ]
}

private func makeCloudKitTransactionRepository(
  initialTransactions: [Transaction] = [],
  currency: Currency = .defaultTestCurrency
) -> CloudKitTransactionRepository {
  let container = try! TestModelContainer.create()
  let profileId = UUID()
  let repo = CloudKitTransactionRepository(
    modelContainer: container, profileId: profileId, currency: currency)

  if !initialTransactions.isEmpty {
    let context = ModelContext(container)
    for txn in initialTransactions {
      context.insert(TransactionRecord.from(txn, profileId: profileId))
    }
    try! context.save()
  }

  return repo
}
