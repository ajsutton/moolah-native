import Foundation
import SwiftData
import Testing

@testable import Moolah

@Suite("TransactionRepository — Scheduled / Earmark / Account / Payee")
struct TransactionRepositoryAuxFilterTests {
  // MARK: - Scheduled Filter

  @Test("filters scheduled transactions")
  func testFiltersByScheduled() async throws {
    let repository = try makeContractCloudKitTransactionRepository(
      initialTransactions: try makeScheduledContractTestTransactions())
    let scheduledPage = try await repository.fetch(
      filter: TransactionFilter(scheduled: .scheduledOnly),
      page: 0,
      pageSize: 50
    )
    #expect(scheduledPage.transactions.count == 1)
    #expect(scheduledPage.transactions[0].isScheduled)

    let nonScheduledPage = try await repository.fetch(
      filter: TransactionFilter(scheduled: .nonScheduledOnly),
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
    let repository = try makeContractCloudKitTransactionRepository(
      initialTransactions: try makeContractTestTransactions())
    // The test data has one earmarked transaction
    let allPage = try await repository.fetch(
      filter: TransactionFilter(),
      page: 0,
      pageSize: 50
    )
    let earmarked = allPage.transactions.filter { $0.legs.contains(where: { $0.earmarkId != nil }) }
    #expect(earmarked.count == 1, "Test data should have one earmarked transaction")

    let earmarkLeg = try #require(earmarked[0].legs.first(where: { $0.earmarkId != nil }))
    let earmarkId = try #require(earmarkLeg.earmarkId)
    let filteredPage = try await repository.fetch(
      filter: TransactionFilter(earmarkId: earmarkId),
      page: 0,
      pageSize: 50
    )

    #expect(filteredPage.transactions.count == 1)
    #expect(filteredPage.transactions[0].legs.contains(where: { $0.earmarkId == earmarkId }))
  }

  // MARK: - Account Filter

  @Test("filters by accountId including transfers")
  func testFiltersByAccountIdIncludingTransfers() async throws {
    let repository = try makeContractCloudKitTransactionRepository(
      initialTransactions: try makeTransferContractTestTransactions())
    let sourceAccountId = TransactionContractTestFixtures.transferSourceAccountId
    let destAccountId = TransactionContractTestFixtures.transferDestAccountId

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
    #expect(destPage.transactions[0].legs.allSatisfy { $0.type == .transfer })
  }

  // MARK: - Payee Suggestions

  @Test("fetchPayeeSuggestions returns prefix matches sorted by frequency")
  func testPayeeSuggestions() async throws {
    let repository = try makeContractCloudKitTransactionRepository(
      initialTransactions: try makePayeeSuggestionContractTestTransactions())
    let suggestions = try await repository.fetchPayeeSuggestions(prefix: "Wool")

    #expect(suggestions.count == 1)
    #expect(suggestions[0] == "Woolworths")
  }

  @Test("fetchPayeeSuggestions is case insensitive")
  func testPayeeSuggestionsCaseInsensitive() async throws {
    let repository = try makeContractCloudKitTransactionRepository(
      initialTransactions: try makePayeeSuggestionContractTestTransactions())
    let suggestions = try await repository.fetchPayeeSuggestions(prefix: "wool")

    #expect(suggestions.count == 1)
    #expect(suggestions[0] == "Woolworths")
  }

  @Test("fetchPayeeSuggestions returns empty for empty prefix")
  func testPayeeSuggestionsEmptyPrefix() async throws {
    let repository = try makeContractCloudKitTransactionRepository(
      initialTransactions: try makePayeeSuggestionContractTestTransactions())
    let suggestions = try await repository.fetchPayeeSuggestions(prefix: "")
    #expect(suggestions.isEmpty)
  }

  @Test("fetchPayeeSuggestions sorts by frequency")
  func testPayeeSuggestionsByFrequency() async throws {
    let repository = try makeContractCloudKitTransactionRepository(
      initialTransactions: try makePayeeSuggestionContractTestTransactions())
    // "Coles" appears 3 times, "Coffee Shop" appears 1 time
    let suggestions = try await repository.fetchPayeeSuggestions(prefix: "Co")

    #expect(suggestions.count == 2)
    #expect(suggestions[0] == "Coles", "Most frequent payee should be first")
    #expect(suggestions[1] == "Coffee Shop")
  }

  @Test("fetchPayeeSuggestions excludes the editing transaction's own row")
  func testPayeeSuggestionsExcludesEditingTransaction() async throws {
    // "Woolworths" appears on exactly one transaction in the fixture; passing
    // its id as `excludingTransactionId` drops the only occurrence so the
    // payee disappears from the suggestion list. Without this, the field would
    // suggest the row's own payee back to itself (#538).
    let transactions = try makePayeeSuggestionContractTestTransactions()
    let woolworths = try #require(transactions.first { $0.payee == "Woolworths" })
    let repository = try makeContractCloudKitTransactionRepository(
      initialTransactions: transactions)

    let suggestions = try await repository.fetchPayeeSuggestions(
      prefix: "Wool", excludingTransactionId: woolworths.id)
    #expect(suggestions.isEmpty)
  }

  @Test("fetchPayeeSuggestions excludingTransactionId reduces frequency counts")
  func testPayeeSuggestionsExclusionReducesFrequency() async throws {
    // "Coles" appears 3 times. Excluding one of those rows leaves 2 — still
    // a match, but the frequency count must reflect the exclusion so the
    // ordering stays correct relative to other prefix matches.
    let transactions = try makePayeeSuggestionContractTestTransactions()
    let firstColes = try #require(transactions.first { $0.payee == "Coles" })
    let repository = try makeContractCloudKitTransactionRepository(
      initialTransactions: transactions)

    let suggestions = try await repository.fetchPayeeSuggestions(
      prefix: "Co", excludingTransactionId: firstColes.id)

    #expect(suggestions == ["Coles", "Coffee Shop"])
  }

  @Test("fetchPayeeSuggestions excludingTransactionId for unknown id is a no-op")
  func testPayeeSuggestionsExclusionUnknownIdNoOp() async throws {
    // Acceptance criterion 2: an id that isn't in the repo (e.g. an unsaved
    // draft) leaves the result identical to the no-exclusion path.
    let repository = try makeContractCloudKitTransactionRepository(
      initialTransactions: try makePayeeSuggestionContractTestTransactions())

    let suggestions = try await repository.fetchPayeeSuggestions(
      prefix: "Co", excludingTransactionId: UUID())
    #expect(suggestions == ["Coles", "Coffee Shop"])
  }
}
