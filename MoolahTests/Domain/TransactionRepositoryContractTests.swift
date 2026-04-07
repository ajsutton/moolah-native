import Foundation
import Testing

@testable import Moolah

@Suite("TransactionRepository Contract")
struct TransactionRepositoryContractTests {
  @Test(
    "InMemoryTransactionRepository - filters by date range",
    arguments: [
      InMemoryTransactionRepository(initialTransactions: makeTestTransactions())
    ])
  func testFiltersByDateRange(repository: InMemoryTransactionRepository) async throws {
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
    "InMemoryTransactionRepository - filters by category IDs",
    arguments: [
      InMemoryTransactionRepository(initialTransactions: makeTestTransactions())
    ])
  func testFiltersByCategoryIds(repository: InMemoryTransactionRepository) async throws {
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
    "InMemoryTransactionRepository - filters by payee (case-insensitive contains)",
    arguments: [
      InMemoryTransactionRepository(initialTransactions: makeTestTransactions())
    ])
  func testFiltersByPayee(repository: InMemoryTransactionRepository) async throws {
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
    "InMemoryTransactionRepository - combines multiple filters",
    arguments: [
      InMemoryTransactionRepository(initialTransactions: makeTestTransactions())
    ])
  func testCombinesMultipleFilters(repository: InMemoryTransactionRepository) async throws {
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
    "InMemoryTransactionRepository - returns empty when no matches",
    arguments: [
      InMemoryTransactionRepository(initialTransactions: makeTestTransactions())
    ])
  func testReturnsEmptyWhenNoMatches(repository: InMemoryTransactionRepository) async throws {
    let page = try await repository.fetch(
      filter: TransactionFilter(payee: "NonexistentPayee"),
      page: 0,
      pageSize: 50
    )

    #expect(page.transactions.isEmpty)
  }

  @Test(
    "InMemoryTransactionRepository - clearing filter reloads all",
    arguments: [
      InMemoryTransactionRepository(initialTransactions: makeTestTransactions())
    ])
  func testClearingFilterReloadsAll(repository: InMemoryTransactionRepository) async throws {
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
      amount: MonetaryAmount(cents: -5023, currency: Currency.defaultCurrency),
      payee: "Woolworths",
      categoryId: groceryCategoryId
    ),
    // Transport expense in July
    Transaction(
      type: .expense,
      date: calendar.date(from: DateComponents(year: 2024, month: 7, day: 10))!,
      accountId: accountId,
      amount: MonetaryAmount(cents: -3500, currency: Currency.defaultCurrency),
      payee: "Metro Transport",
      categoryId: transportCategoryId
    ),
    // Income in May
    Transaction(
      type: .income,
      date: calendar.date(from: DateComponents(year: 2024, month: 5, day: 30))!,
      accountId: accountId,
      amount: MonetaryAmount(cents: 350000, currency: Currency.defaultCurrency),
      payee: "Employer Pty Ltd"
    ),
    // Grocery expense in April (older, different payee)
    Transaction(
      type: .expense,
      date: calendar.date(from: DateComponents(year: 2024, month: 4, day: 20))!,
      accountId: accountId,
      amount: MonetaryAmount(cents: -4200, currency: Currency.defaultCurrency),
      payee: "Coles",
      categoryId: groceryCategoryId
    ),
    // Earmarked expense in June
    Transaction(
      type: .expense,
      date: calendar.date(from: DateComponents(year: 2024, month: 6, day: 20))!,
      accountId: accountId,
      amount: MonetaryAmount(cents: -10000, currency: Currency.defaultCurrency),
      payee: "Electronics Store",
      categoryId: transportCategoryId,
      earmarkId: earmarkId
    ),
  ]

  return transactions
}
