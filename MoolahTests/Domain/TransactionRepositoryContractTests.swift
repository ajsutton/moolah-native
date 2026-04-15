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
    let repository = makeCloudKitTransactionRepository()
    let calendar = Calendar.current
    let fromAccountId = UUID()
    let toAccountId = UUID()
    let categoryId = UUID()
    let earmarkId = UUID()
    let date = calendar.date(from: DateComponents(year: 2024, month: 3, day: 12))!

    let original = Transaction(
      date: date,
      payee: "Original Payee",
      notes: "Some notes",
      recurPeriod: .month,
      recurEvery: 2,
      legs: [
        TransactionLeg(
          accountId: fromAccountId, instrument: .defaultTestInstrument,
          quantity: Decimal(string: "-750.00")!, type: .transfer,
          categoryId: categoryId, earmarkId: earmarkId),
        TransactionLeg(
          accountId: toAccountId, instrument: .defaultTestInstrument,
          quantity: Decimal(string: "750.00")!, type: .transfer),
      ]
    )

    let created = try await repository.create(original)

    var updated = created
    updated.payee = "Updated Payee"

    let result = try await repository.update(updated)

    // Verify all fields match the updated transaction
    #expect(result.id == created.id)
    #expect(result.type == .transfer)
    #expect(result.date == date)
    #expect(result.legs.count == 2)
    #expect(result.legs[0].accountId == fromAccountId)
    #expect(result.legs[1].accountId == toAccountId)
    #expect(result.legs[0].quantity == Decimal(string: "-750.00")!)
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
    #expect(fetched.legs.count == 2)
    #expect(fetched.legs[0].accountId == fromAccountId)
    #expect(fetched.legs[1].accountId == toAccountId)
    #expect(fetched.legs[0].quantity == Decimal(string: "-750.00")!)
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
    let accountFilter = TransactionFilter(accountId: paginationTestAccountId)
    let page0 = try await repository.fetch(
      filter: accountFilter,
      page: 0,
      pageSize: 2
    )

    let page1 = try await repository.fetch(
      filter: accountFilter,
      page: 1,
      pageSize: 2
    )

    // priorBalance for page 0 should be sum of transactions on page 1+
    let page1Sum = page1.transactions.reduce(
      InstrumentAmount.zero(instrument: .defaultTestInstrument)
    ) {
      $0 + $1.primaryAmount
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
    #expect(page.priorBalance.isZero)
  }

  @Test("transfer creates with two legs")
  func testTransferCreatesTwoLegs() async throws {
    let repository = makeCloudKitTransactionRepository()
    let fromAccount = UUID()
    let toAccount = UUID()
    let transfer = Transaction(
      date: Date(),
      payee: "Transfer",
      legs: [
        TransactionLeg(
          accountId: fromAccount, instrument: .defaultTestInstrument,
          quantity: Decimal(string: "-5.00")!, type: .transfer),
        TransactionLeg(
          accountId: toAccount, instrument: .defaultTestInstrument,
          quantity: Decimal(string: "5.00")!, type: .transfer),
      ]
    )

    let created = try await repository.create(transfer)
    #expect(created.legs.count == 2)
    #expect(created.isTransfer)
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

// MARK: - Test Data Helpers

private func makeLeg(
  accountId: UUID,
  quantity: Decimal,
  type: TransactionType,
  categoryId: UUID? = nil,
  earmarkId: UUID? = nil
) -> TransactionLeg {
  TransactionLeg(
    accountId: accountId,
    instrument: .defaultTestInstrument,
    quantity: quantity,
    type: type,
    categoryId: categoryId,
    earmarkId: earmarkId
  )
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
      date: calendar.date(from: DateComponents(year: 2024, month: 6, day: 15))!,
      payee: "Woolworths",
      legs: [
        makeLeg(
          accountId: accountId, quantity: Decimal(string: "-50.23")!, type: .expense,
          categoryId: groceryCategoryId)
      ]
    ),
    // Transport expense in July
    Transaction(
      date: calendar.date(from: DateComponents(year: 2024, month: 7, day: 10))!,
      payee: "Metro Transport",
      legs: [
        makeLeg(
          accountId: accountId, quantity: Decimal(string: "-35.00")!, type: .expense,
          categoryId: transportCategoryId)
      ]
    ),
    // Income in May
    Transaction(
      date: calendar.date(from: DateComponents(year: 2024, month: 5, day: 30))!,
      payee: "Employer Pty Ltd",
      legs: [makeLeg(accountId: accountId, quantity: Decimal(string: "3500.00")!, type: .income)]
    ),
    // Grocery expense in April (older, different payee)
    Transaction(
      date: calendar.date(from: DateComponents(year: 2024, month: 4, day: 20))!,
      payee: "Coles",
      legs: [
        makeLeg(
          accountId: accountId, quantity: Decimal(string: "-42.00")!, type: .expense,
          categoryId: groceryCategoryId)
      ]
    ),
    // Earmarked expense in June
    Transaction(
      date: calendar.date(from: DateComponents(year: 2024, month: 6, day: 20))!,
      payee: "Electronics Store",
      legs: [
        makeLeg(
          accountId: accountId, quantity: Decimal(string: "-100.00")!, type: .expense,
          categoryId: transportCategoryId, earmarkId: earmarkId)
      ]
    ),
  ]

  return transactions
}

private let paginationTestAccountId = UUID()

private func makePaginationTestTransactions() -> [Transaction] {
  let accountId = paginationTestAccountId
  let calendar = Calendar.current
  return [
    Transaction(
      date: calendar.date(from: DateComponents(year: 2024, month: 1, day: 1))!,
      payee: "Jan Income",
      legs: [makeLeg(accountId: accountId, quantity: Decimal(string: "10.00")!, type: .income)]
    ),
    Transaction(
      date: calendar.date(from: DateComponents(year: 2024, month: 2, day: 1))!,
      payee: "Feb Expense",
      legs: [makeLeg(accountId: accountId, quantity: Decimal(string: "-3.00")!, type: .expense)]
    ),
    Transaction(
      date: calendar.date(from: DateComponents(year: 2024, month: 3, day: 1))!,
      payee: "Mar Income",
      legs: [makeLeg(accountId: accountId, quantity: Decimal(string: "20.00")!, type: .income)]
    ),
    Transaction(
      date: calendar.date(from: DateComponents(year: 2024, month: 4, day: 1))!,
      payee: "Apr Expense",
      legs: [makeLeg(accountId: accountId, quantity: Decimal(string: "-5.00")!, type: .expense)]
    ),
  ]
}

private func makeScheduledTestTransactions() -> [Transaction] {
  let accountId = UUID()
  let calendar = Calendar.current
  return [
    // Non-scheduled expense
    Transaction(
      date: calendar.date(from: DateComponents(year: 2024, month: 6, day: 15))!,
      payee: "Store",
      legs: [makeLeg(accountId: accountId, quantity: Decimal(string: "-50.00")!, type: .expense)]
    ),
    // Non-scheduled income
    Transaction(
      date: calendar.date(from: DateComponents(year: 2024, month: 6, day: 1))!,
      payee: "Salary",
      legs: [makeLeg(accountId: accountId, quantity: Decimal(string: "1000.00")!, type: .income)]
    ),
    // Scheduled (recurring) transaction
    Transaction(
      date: calendar.date(from: DateComponents(year: 2024, month: 7, day: 1))!,
      payee: "Netflix",
      recurPeriod: .month,
      recurEvery: 1,
      legs: [makeLeg(accountId: accountId, quantity: Decimal(string: "-20.00")!, type: .expense)]
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
      date: calendar.date(from: DateComponents(year: 2024, month: 6, day: 15))!,
      payee: "Transfer",
      legs: [
        makeLeg(accountId: sourceAccountId, quantity: Decimal(string: "-100.00")!, type: .transfer),
        makeLeg(accountId: destAccountId, quantity: Decimal(string: "100.00")!, type: .transfer),
      ]
    ),
    // Expense on source account only
    Transaction(
      date: calendar.date(from: DateComponents(year: 2024, month: 6, day: 10))!,
      payee: "Coffee",
      legs: [
        makeLeg(accountId: sourceAccountId, quantity: Decimal(string: "-50.00")!, type: .expense)
      ]
    ),
  ]
}

private func makePayeeSuggestionTestTransactions() -> [Transaction] {
  let accountId = UUID()
  let calendar = Calendar.current
  return [
    Transaction(
      date: calendar.date(from: DateComponents(year: 2024, month: 6, day: 1))!,
      payee: "Woolworths",
      legs: [makeLeg(accountId: accountId, quantity: Decimal(string: "-10.00")!, type: .expense)]
    ),
    Transaction(
      date: calendar.date(from: DateComponents(year: 2024, month: 6, day: 2))!,
      payee: "Coles",
      legs: [makeLeg(accountId: accountId, quantity: Decimal(string: "-20.00")!, type: .expense)]
    ),
    Transaction(
      date: calendar.date(from: DateComponents(year: 2024, month: 6, day: 3))!,
      payee: "Coles",
      legs: [makeLeg(accountId: accountId, quantity: Decimal(string: "-30.00")!, type: .expense)]
    ),
    Transaction(
      date: calendar.date(from: DateComponents(year: 2024, month: 6, day: 4))!,
      payee: "Coles",
      legs: [makeLeg(accountId: accountId, quantity: Decimal(string: "-15.00")!, type: .expense)]
    ),
    Transaction(
      date: calendar.date(from: DateComponents(year: 2024, month: 6, day: 5))!,
      payee: "Coffee Shop",
      legs: [makeLeg(accountId: accountId, quantity: Decimal(string: "-5.00")!, type: .expense)]
    ),
  ]
}

private func makeCloudKitTransactionRepository(
  initialTransactions: [Transaction] = [],
  instrument: Instrument = .defaultTestInstrument
) -> CloudKitTransactionRepository {
  let container = try! TestModelContainer.create()
  let repo = CloudKitTransactionRepository(
    modelContainer: container, instrument: instrument)

  if !initialTransactions.isEmpty {
    let context = ModelContext(container)
    for txn in initialTransactions {
      context.insert(TransactionRecord.from(txn))
      for (index, leg) in txn.legs.enumerated() {
        context.insert(TransactionLegRecord.from(leg, transactionId: txn.id, sortOrder: index))
      }
    }
    try! context.save()
  }

  return repo
}
