import Foundation
import SwiftData
import Testing

@testable import Moolah

@Suite("EarmarkRepository Contract")
struct EarmarkRepositoryContractTests {
  @Test(
    "creates earmark",
    arguments: [
      InMemoryEarmarkRepository() as any EarmarkRepository,
      makeCloudKitEarmarkRepository() as any EarmarkRepository,
    ])
  func testCreatesEarmark(repository: any EarmarkRepository) async throws {
    let newEarmark = Earmark(name: "Emergency Fund")

    let created = try await repository.create(newEarmark)

    #expect(created.id == newEarmark.id)
    #expect(created.name == "Emergency Fund")

    let all = try await repository.fetchAll()
    #expect(all.count == 1)
    #expect(all[0].name == "Emergency Fund")
  }

  @Test(
    "updates earmark",
    arguments: [
      InMemoryEarmarkRepository(initialEarmarks: [
        Earmark(name: "Emergency Fund")
      ]) as any EarmarkRepository,
      makeCloudKitEarmarkRepository(initialEarmarks: [
        Earmark(name: "Emergency Fund")
      ]) as any EarmarkRepository,
    ])
  func testUpdatesEarmark(repository: any EarmarkRepository) async throws {
    let earmarks = try await repository.fetchAll()
    var toUpdate = earmarks[0]
    toUpdate.name = "Rainy Day Fund"
    toUpdate.savingsGoal = MonetaryAmount(cents: 500000, currency: Currency.defaultTestCurrency)

    let updated = try await repository.update(toUpdate)

    #expect(updated.name == "Rainy Day Fund")
    #expect(updated.savingsGoal?.cents == 500000)
  }

  @Test(
    "fetches empty budget for new earmark",
    arguments: [
      InMemoryEarmarkRepository(initialEarmarks: [
        Earmark(name: "Emergency Fund")
      ]) as any EarmarkRepository,
      makeCloudKitEarmarkRepository(initialEarmarks: [
        Earmark(name: "Emergency Fund")
      ]) as any EarmarkRepository,
    ])
  func testFetchesEmptyBudget(repository: any EarmarkRepository) async throws {
    let earmarks = try await repository.fetchAll()
    let budget = try await repository.fetchBudget(earmarkId: earmarks[0].id)

    #expect(budget.isEmpty)
  }

  @Test(
    "updates and fetches budget",
    arguments: [
      InMemoryEarmarkRepository(initialEarmarks: [
        Earmark(name: "Emergency Fund")
      ]) as any EarmarkRepository,
      makeCloudKitEarmarkRepository(initialEarmarks: [
        Earmark(name: "Emergency Fund")
      ]) as any EarmarkRepository,
    ])
  func testUpdatesFetchesBudget(repository: any EarmarkRepository) async throws {
    let earmarks = try await repository.fetchAll()
    let earmarkId = earmarks[0].id

    let category1 = UUID()
    let category2 = UUID()

    try await repository.setBudget(earmarkId: earmarkId, categoryId: category1, amount: 10000)
    try await repository.setBudget(earmarkId: earmarkId, categoryId: category2, amount: 20000)

    let fetchedBudget = try await repository.fetchBudget(earmarkId: earmarkId)
    #expect(fetchedBudget.count == 2)
    #expect(fetchedBudget.contains { $0.categoryId == category1 && $0.amount.cents == 10000 })
    #expect(fetchedBudget.contains { $0.categoryId == category2 && $0.amount.cents == 20000 })
  }

  @Test(
    "throws on update non-existent",
    arguments: [
      InMemoryEarmarkRepository() as any EarmarkRepository,
      makeCloudKitEarmarkRepository() as any EarmarkRepository,
    ])
  func testThrowsOnUpdateNonExistent(repository: any EarmarkRepository) async throws {
    let nonExistent = Earmark(name: "DoesNotExist")

    await #expect(throws: BackendError.serverError(404)) {
      _ = try await repository.update(nonExistent)
    }
  }

  @Test(
    "throws on budget update for non-existent earmark",
    arguments: [
      InMemoryEarmarkRepository() as any EarmarkRepository,
      makeCloudKitEarmarkRepository() as any EarmarkRepository,
    ])
  func testThrowsOnBudgetUpdateNonExistent(repository: any EarmarkRepository) async throws {
    await #expect(throws: BackendError.serverError(404)) {
      try await repository.setBudget(earmarkId: UUID(), categoryId: UUID(), amount: 10000)
    }
  }

  @Test(
    "setBudget twice updates existing entry, not creates duplicate",
    arguments: [
      InMemoryEarmarkRepository(initialEarmarks: [
        Earmark(name: "Savings")
      ]) as any EarmarkRepository,
      makeCloudKitEarmarkRepository(initialEarmarks: [
        Earmark(name: "Savings")
      ]) as any EarmarkRepository,
    ])
  func testBudgetUpsertSemantics(repository: any EarmarkRepository) async throws {
    let earmarks = try await repository.fetchAll()
    let earmarkId = earmarks[0].id
    let categoryId = UUID()

    // Set budget first time
    try await repository.setBudget(earmarkId: earmarkId, categoryId: categoryId, amount: 10000)

    // Set budget again with different amount (should update, not duplicate)
    try await repository.setBudget(earmarkId: earmarkId, categoryId: categoryId, amount: 25000)

    let budget = try await repository.fetchBudget(earmarkId: earmarkId)

    // Should have exactly one entry for this category, not two
    let entries = budget.filter { $0.categoryId == categoryId }
    #expect(entries.count == 1, "setBudget should update, not create duplicate")
    #expect(entries[0].amount.cents == 25000, "Amount should reflect the latest setBudget call")
  }
}

private func makeCloudKitEarmarkRepository(
  initialEarmarks: [Earmark] = [],
  currency: Currency = .defaultTestCurrency
) -> CloudKitEarmarkRepository {
  let container = try! TestModelContainer.create()
  let profileId = UUID()
  let repo = CloudKitEarmarkRepository(
    modelContainer: container, profileId: profileId, currency: currency)

  if !initialEarmarks.isEmpty {
    let context = ModelContext(container)
    for earmark in initialEarmarks {
      context.insert(EarmarkRecord.from(earmark, profileId: profileId, currencyCode: currency.code))
    }
    try! context.save()
  }

  return repo
}
