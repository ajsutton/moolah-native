import Foundation
import SwiftData
import Testing

@testable import Moolah

@Suite("TransactionRepository Contract")
struct TransactionRepositoryContractTests {
  @Test("filters by date range")
  func testFiltersByDateRange() async throws {
    let repository = makeCloudKitTransactionRepository(initialTransactions: makeTestTransactions())
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

  @Test("filters by category IDs")
  func testFiltersByCategoryIds() async throws {
    let repository = makeCloudKitTransactionRepository(initialTransactions: makeTestTransactions())
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

  @Test("filters by payee (case-insensitive contains)")
  func testFiltersByPayee() async throws {
    let repository = makeCloudKitTransactionRepository(initialTransactions: makeTestTransactions())
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

  @Test("combines multiple filters")
  func testCombinesMultipleFilters() async throws {
    let repository = makeCloudKitTransactionRepository(initialTransactions: makeTestTransactions())
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

  @Test("returns empty when no matches")
  func testReturnsEmptyWhenNoMatches() async throws {
    let repository = makeCloudKitTransactionRepository(initialTransactions: makeTestTransactions())
    let page = try await repository.fetch(
      filter: TransactionFilter(payee: "NonexistentPayee"),
      page: 0,
      pageSize: 50
    )

    #expect(page.transactions.isEmpty)
  }

  @Test("update preserves all transaction fields")
  func testUpdatePreservesAllFields() async throws {
    let repository = makeCloudKitTransactionRepository(initialTransactions: [])
    let calendar = Calendar.current
    let accountId = UUID()
    let toAccountId = UUID()
    let categoryId = UUID()
    let earmarkId = UUID()
    let date = calendar.date(from: DateComponents(year: 2024, month: 3, day: 12))!

    let original = Transaction(
      type: .transfer,
      date: date,
      accountId: accountId,
      toAccountId: toAccountId,
      amount: MonetaryAmount(cents: 75000, currency: Currency.defaultTestCurrency),
      payee: "Original Payee",
      notes: "Some notes",
      categoryId: categoryId,
      earmarkId: earmarkId,
      recurPeriod: .month,
      recurEvery: 2
    )

    let created = try await repository.create(original)

    var updated = created
    updated.payee = "Updated Payee"

    let result = try await repository.update(updated)

    // Verify all fields match the updated transaction
    #expect(result.id == created.id)
    #expect(result.type == .transfer)
    #expect(result.date == date)
    #expect(result.accountId == accountId)
    #expect(result.toAccountId == toAccountId)
    #expect(result.amount == MonetaryAmount(cents: 75000, currency: Currency.defaultTestCurrency))
    #expect(result.payee == "Updated Payee")
    #expect(result.notes == "Some notes")
    #expect(result.categoryId == categoryId)
    #expect(result.earmarkId == earmarkId)
    #expect(result.recurPeriod == .month)
    #expect(result.recurEvery == 2)

    // Verify persistence by fetching back from repository (scheduled filter needed since
    // the transaction has recurPeriod set, and the default filter excludes scheduled)
    let page = try await repository.fetch(
      filter: TransactionFilter(scheduled: true),
      page: 0,
      pageSize: 50
    )
    let fetched = try #require(page.transactions.first(where: { $0.id == created.id }))

    #expect(fetched.type == .transfer)
    #expect(fetched.date == date)
    #expect(fetched.accountId == accountId)
    #expect(fetched.toAccountId == toAccountId)
    #expect(fetched.amount == MonetaryAmount(cents: 75000, currency: Currency.defaultTestCurrency))
    #expect(fetched.payee == "Updated Payee")
    #expect(fetched.notes == "Some notes")
    #expect(fetched.categoryId == categoryId)
    #expect(fetched.earmarkId == earmarkId)
    #expect(fetched.recurPeriod == .month)
    #expect(fetched.recurEvery == 2)
  }

  @Test("clearing filter reloads all")
  func testClearingFilterReloadsAll() async throws {
    let repository = makeCloudKitTransactionRepository(initialTransactions: makeTestTransactions())
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

  @Test("priorBalance is sum of transactions before the page")
  func testPriorBalanceAcrossPages() async throws {
    let repository = makeCloudKitTransactionRepository(
      initialTransactions: makePaginationTestTransactions())
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

  @Test("empty page returns zero priorBalance")
  func testEmptyPagePriorBalance() async throws {
    let repository = makeCloudKitTransactionRepository(
      initialTransactions: makePaginationTestTransactions())
    let page = try await repository.fetch(
      filter: TransactionFilter(),
      page: 100,
      pageSize: 10
    )

    #expect(page.transactions.isEmpty)
    #expect(page.priorBalance.cents == 0)
  }

  @Test("transfer requires toAccountId")
  func testTransferRequiresToAccountId() async throws {
    let repository = makeCloudKitTransactionRepository()
    let transfer = Transaction(
      type: .transfer,
      date: Date(),
      accountId: UUID(),
      toAccountId: nil,
      amount: MonetaryAmount(cents: -500, currency: .defaultTestCurrency),
      payee: "Transfer"
    )

    await #expect(throws: BackendError.self) {
      _ = try await repository.create(transfer)
    }
  }

  @Test("transfer rejects same-account transfer")
  func testTransferRejectsSameAccount() async throws {
    let repository = makeCloudKitTransactionRepository()
    let accountId = UUID()
    let transfer = Transaction(
      type: .transfer,
      date: Date(),
      accountId: accountId,
      toAccountId: accountId,
      amount: MonetaryAmount(cents: -500, currency: .defaultTestCurrency),
      payee: "Transfer"
    )

    await #expect(throws: BackendError.self) {
      _ = try await repository.create(transfer)
    }
  }

  @Test("transactions are sorted by date descending")
  func testTransactionsSortedByDateDesc() async throws {
    let repository = makeCloudKitTransactionRepository(initialTransactions: makeTestTransactions())
    let page = try await repository.fetch(
      filter: TransactionFilter(),
      page: 0,
      pageSize: 50
    )

    for i in 0..<(page.transactions.count - 1) {
      #expect(
        page.transactions[i].date >= page.transactions[i + 1].date,
        "Transactions should be sorted by date descending"
      )
    }
  }

  // MARK: - Scheduled Filter

  @Test("filters scheduled transactions")
  func testFiltersByScheduled() async throws {
    let repository = makeCloudKitTransactionRepository(
      initialTransactions: makeScheduledTestTransactions())
    let scheduledPage = try await repository.fetch(
      filter: TransactionFilter(scheduled: true),
      page: 0,
      pageSize: 50
    )
    #expect(scheduledPage.transactions.count == 1)
    #expect(scheduledPage.transactions[0].isScheduled)

    let nonScheduledPage = try await repository.fetch(
      filter: TransactionFilter(scheduled: false),
      page: 0,
      pageSize: 50
    )
    #expect(nonScheduledPage.transactions.count == 2)
    for txn in nonScheduledPage.transactions {
      #expect(!txn.isScheduled)
    }
  }

  // MARK: - Earmark Filter

  @Test("filters by earmarkId")
  func testFiltersByEarmarkId() async throws {
    let repository = makeCloudKitTransactionRepository(initialTransactions: makeTestTransactions())
    // The test data has one earmarked transaction
    let allPage = try await repository.fetch(
      filter: TransactionFilter(),
      page: 0,
      pageSize: 50
    )
    let earmarked = allPage.transactions.filter { $0.earmarkId != nil }
    #expect(earmarked.count == 1, "Test data should have one earmarked transaction")

    let earmarkId = earmarked[0].earmarkId!
    let filteredPage = try await repository.fetch(
      filter: TransactionFilter(earmarkId: earmarkId),
      page: 0,
      pageSize: 50
    )

    #expect(filteredPage.transactions.count == 1)
    #expect(filteredPage.transactions[0].earmarkId == earmarkId)
  }

  // MARK: - Account Filter

  @Test("filters by accountId including transfers")
  func testFiltersByAccountIdIncludingTransfers() async throws {
    let repository = makeCloudKitTransactionRepository(
      initialTransactions: makeTransferTestTransactions())
    let sourceAccountId = transferSourceAccountId
    let destAccountId = transferDestAccountId

    // Filter by source account — should include the transfer AND the expense
    let sourcePage = try await repository.fetch(
      filter: TransactionFilter(accountId: sourceAccountId),
      page: 0,
      pageSize: 50
    )
    #expect(sourcePage.transactions.count == 2)

    // Filter by dest account — should include the transfer only
    let destPage = try await repository.fetch(
      filter: TransactionFilter(accountId: destAccountId),
      page: 0,
      pageSize: 50
    )
    #expect(destPage.transactions.count == 1)
    #expect(destPage.transactions[0].type == .transfer)
  }

  // MARK: - Payee Suggestions

  @Test("fetchPayeeSuggestions returns prefix matches sorted by frequency")
  func testPayeeSuggestions() async throws {
    let repository = makeCloudKitTransactionRepository(
      initialTransactions: makePayeeSuggestionTestTransactions())
    let suggestions = try await repository.fetchPayeeSuggestions(prefix: "Wool")

    #expect(suggestions.count == 1)
    #expect(suggestions[0] == "Woolworths")
  }

  @Test("fetchPayeeSuggestions is case insensitive")
  func testPayeeSuggestionsCaseInsensitive() async throws {
    let repository = makeCloudKitTransactionRepository(
      initialTransactions: makePayeeSuggestionTestTransactions())
    let suggestions = try await repository.fetchPayeeSuggestions(prefix: "wool")

    #expect(suggestions.count == 1)
    #expect(suggestions[0] == "Woolworths")
  }

  @Test("fetchPayeeSuggestions returns empty for empty prefix")
  func testPayeeSuggestionsEmptyPrefix() async throws {
    let repository = makeCloudKitTransactionRepository(
      initialTransactions: makePayeeSuggestionTestTransactions())
    let suggestions = try await repository.fetchPayeeSuggestions(prefix: "")
    #expect(suggestions.isEmpty)
  }

  @Test("fetchPayeeSuggestions sorts by frequency")
  func testPayeeSuggestionsByFrequency() async throws {
    let repository = makeCloudKitTransactionRepository(
      initialTransactions: makePayeeSuggestionTestTransactions())
    // "Coles" appears 3 times, "Coffee Shop" appears 1 time
    let suggestions = try await repository.fetchPayeeSuggestions(prefix: "Co")

    #expect(suggestions.count == 2)
    #expect(suggestions[0] == "Coles", "Most frequent payee should be first")
    #expect(suggestions[1] == "Coffee Shop")
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

private func makeScheduledTestTransactions() -> [Transaction] {
  let accountId = UUID()
  let calendar = Calendar.current
  return [
    // Non-scheduled expense
    Transaction(
      type: .expense,
      date: calendar.date(from: DateComponents(year: 2024, month: 6, day: 15))!,
      accountId: accountId,
      amount: MonetaryAmount(cents: -5000, currency: Currency.defaultTestCurrency),
      payee: "Store"
    ),
    // Non-scheduled income
    Transaction(
      type: .income,
      date: calendar.date(from: DateComponents(year: 2024, month: 6, day: 1))!,
      accountId: accountId,
      amount: MonetaryAmount(cents: 100000, currency: Currency.defaultTestCurrency),
      payee: "Salary"
    ),
    // Scheduled (recurring) transaction
    Transaction(
      type: .expense,
      date: calendar.date(from: DateComponents(year: 2024, month: 7, day: 1))!,
      accountId: accountId,
      amount: MonetaryAmount(cents: -2000, currency: Currency.defaultTestCurrency),
      payee: "Netflix",
      recurPeriod: .month,
      recurEvery: 1
    ),
  ]
}

// Stable IDs for transfer test data (shared between seed and assertions)
private let transferSourceAccountId = UUID()
private let transferDestAccountId = UUID()

private func makeTransferTestTransactions() -> [Transaction] {
  let sourceAccountId = transferSourceAccountId
  let destAccountId = transferDestAccountId
  let calendar = Calendar.current
  return [
    // Transfer from source to dest
    Transaction(
      type: .transfer,
      date: calendar.date(from: DateComponents(year: 2024, month: 6, day: 15))!,
      accountId: sourceAccountId,
      toAccountId: destAccountId,
      amount: MonetaryAmount(cents: -10000, currency: Currency.defaultTestCurrency),
      payee: "Transfer"
    ),
    // Expense on source account only
    Transaction(
      type: .expense,
      date: calendar.date(from: DateComponents(year: 2024, month: 6, day: 10))!,
      accountId: sourceAccountId,
      amount: MonetaryAmount(cents: -5000, currency: Currency.defaultTestCurrency),
      payee: "Coffee"
    ),
  ]
}

private func makePayeeSuggestionTestTransactions() -> [Transaction] {
  let accountId = UUID()
  let calendar = Calendar.current
  return [
    Transaction(
      type: .expense,
      date: calendar.date(from: DateComponents(year: 2024, month: 6, day: 1))!,
      accountId: accountId,
      amount: MonetaryAmount(cents: -1000, currency: Currency.defaultTestCurrency),
      payee: "Woolworths"
    ),
    Transaction(
      type: .expense,
      date: calendar.date(from: DateComponents(year: 2024, month: 6, day: 2))!,
      accountId: accountId,
      amount: MonetaryAmount(cents: -2000, currency: Currency.defaultTestCurrency),
      payee: "Coles"
    ),
    Transaction(
      type: .expense,
      date: calendar.date(from: DateComponents(year: 2024, month: 6, day: 3))!,
      accountId: accountId,
      amount: MonetaryAmount(cents: -3000, currency: Currency.defaultTestCurrency),
      payee: "Coles"
    ),
    Transaction(
      type: .expense,
      date: calendar.date(from: DateComponents(year: 2024, month: 6, day: 4))!,
      accountId: accountId,
      amount: MonetaryAmount(cents: -1500, currency: Currency.defaultTestCurrency),
      payee: "Coles"
    ),
    Transaction(
      type: .expense,
      date: calendar.date(from: DateComponents(year: 2024, month: 6, day: 5))!,
      accountId: accountId,
      amount: MonetaryAmount(cents: -500, currency: Currency.defaultTestCurrency),
      payee: "Coffee Shop"
    ),
  ]
}

private func makeCloudKitTransactionRepository(
  initialTransactions: [Transaction] = [],
  currency: Currency = .defaultTestCurrency
) -> CloudKitTransactionRepository {
  let container = try! TestModelContainer.create()
  let repo = CloudKitTransactionRepository(
    modelContainer: container, currency: currency)

  if !initialTransactions.isEmpty {
    let context = ModelContext(container)
    for txn in initialTransactions {
      context.insert(TransactionRecord.from(txn))
    }
    try! context.save()
  }

  return repo
}
