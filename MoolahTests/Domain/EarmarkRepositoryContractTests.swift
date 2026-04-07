import Foundation
import Testing

@testable import Moolah

@Suite("EarmarkRepository Contract")
struct EarmarkRepositoryContractTests {
  @Test(
    "InMemoryEarmarkRepository - creates earmark",
    arguments: [
      InMemoryEarmarkRepository()
    ])
  func testCreatesEarmark(repository: InMemoryEarmarkRepository) async throws {
    let newEarmark = Earmark(
      name: "Emergency Fund",
      balance: MonetaryAmount(cents: 100000, currency: Currency.defaultCurrency)
    )

    let created = try await repository.create(newEarmark)

    #expect(created.id == newEarmark.id)
    #expect(created.name == "Emergency Fund")
    #expect(created.balance.cents == 100000)

    let all = try await repository.fetchAll()
    #expect(all.count == 1)
  }

  @Test(
    "InMemoryEarmarkRepository - updates earmark",
    arguments: [
      InMemoryEarmarkRepository(initialEarmarks: [
        Earmark(name: "Emergency Fund")
      ])
    ])
  func testUpdatesEarmark(repository: InMemoryEarmarkRepository) async throws {
    let earmarks = try await repository.fetchAll()
    var toUpdate = earmarks[0]
    toUpdate.name = "Rainy Day Fund"
    toUpdate.savingsGoal = MonetaryAmount(cents: 500000, currency: Currency.defaultCurrency)

    let updated = try await repository.update(toUpdate)

    #expect(updated.name == "Rainy Day Fund")
    #expect(updated.savingsGoal?.cents == 500000)
  }

  @Test(
    "InMemoryEarmarkRepository - fetches empty budget for new earmark",
    arguments: [
      InMemoryEarmarkRepository(initialEarmarks: [
        Earmark(name: "Emergency Fund")
      ])
    ])
  func testFetchesEmptyBudget(repository: InMemoryEarmarkRepository) async throws {
    let earmarks = try await repository.fetchAll()
    let budget = try await repository.fetchBudget(earmarkId: earmarks[0].id)

    #expect(budget.isEmpty)
  }

  @Test(
    "InMemoryEarmarkRepository - updates and fetches budget",
    arguments: [
      InMemoryEarmarkRepository(initialEarmarks: [
        Earmark(name: "Emergency Fund")
      ])
    ])
  func testUpdatesFetchesBudget(repository: InMemoryEarmarkRepository) async throws {
    let earmarks = try await repository.fetchAll()
    let earmarkId = earmarks[0].id

    let category1 = UUID()
    let category2 = UUID()
    let budgetItems = [
      EarmarkBudgetItem(
        categoryId: category1,
        amount: MonetaryAmount(cents: 10000, currency: Currency.defaultCurrency)
      ),
      EarmarkBudgetItem(
        categoryId: category2,
        amount: MonetaryAmount(cents: 20000, currency: Currency.defaultCurrency)
      ),
    ]

    try await repository.updateBudget(earmarkId: earmarkId, items: budgetItems)

    let fetchedBudget = try await repository.fetchBudget(earmarkId: earmarkId)
    #expect(fetchedBudget.count == 2)
    #expect(fetchedBudget.contains { $0.categoryId == category1 && $0.amount.cents == 10000 })
    #expect(fetchedBudget.contains { $0.categoryId == category2 && $0.amount.cents == 20000 })
  }

  @Test(
    "InMemoryEarmarkRepository - throws on update non-existent",
    arguments: [
      InMemoryEarmarkRepository()
    ])
  func testThrowsOnUpdateNonExistent(repository: InMemoryEarmarkRepository) async throws {
    let nonExistent = Earmark(name: "DoesNotExist")

    await #expect(throws: BackendError.serverError(404)) {
      _ = try await repository.update(nonExistent)
    }
  }

  @Test(
    "InMemoryEarmarkRepository - throws on budget update for non-existent earmark",
    arguments: [
      InMemoryEarmarkRepository()
    ])
  func testThrowsOnBudgetUpdateNonExistent(repository: InMemoryEarmarkRepository) async throws {
    await #expect(throws: BackendError.serverError(404)) {
      try await repository.updateBudget(earmarkId: UUID(), items: [])
    }
  }
}
