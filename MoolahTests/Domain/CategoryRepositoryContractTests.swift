import Foundation
import Testing

@testable import Moolah

@Suite("CategoryRepository Contract")
struct CategoryRepositoryContractTests {
  @Test(
    "InMemoryCategory Repository - creates category",
    arguments: [
      InMemoryCategoryRepository()
    ])
  func testCreatesCategory(repository: InMemoryCategoryRepository) async throws {
    let newCategory = Category(name: "Groceries")

    let created = try await repository.create(newCategory)

    #expect(created.id == newCategory.id)
    #expect(created.name == "Groceries")

    let all = try await repository.fetchAll()
    #expect(all.count == 1)
    #expect(all[0].name == "Groceries")
  }

  @Test(
    "InMemoryCategoryRepository - updates category name",
    arguments: [
      InMemoryCategoryRepository(initialCategories: [
        Category(id: UUID(), name: "Groceries")
      ])
    ])
  func testUpdatesCategory(repository: InMemoryCategoryRepository) async throws {
    let categories = try await repository.fetchAll()
    var toUpdate = categories[0]
    toUpdate.name = "Food & Groceries"

    let updated = try await repository.update(toUpdate)

    #expect(updated.name == "Food & Groceries")

    let all = try await repository.fetchAll()
    #expect(all[0].name == "Food & Groceries")
  }

  @Test(
    "InMemoryCategoryRepository - deletes category without replacement",
    arguments: [
      InMemoryCategoryRepository(initialCategories: [
        Category(id: UUID(), name: "Groceries"),
        Category(id: UUID(), name: "Transport"),
      ])
    ])
  func testDeletesCategoryWithoutReplacement(repository: InMemoryCategoryRepository) async throws {
    let categories = try await repository.fetchAll()
    let toDelete = categories[0]

    try await repository.delete(id: toDelete.id, withReplacement: nil)

    let remaining = try await repository.fetchAll()
    #expect(remaining.count == 1)
    #expect(remaining[0].name == "Transport")
  }

  @Test(
    "InMemoryCategoryRepository - deletes category and updates children",
    arguments: [
      makeRepositoryWithHierarchy()
    ])
  func testDeletesCategoryAndUpdatesChildren(repository: InMemoryCategoryRepository) async throws {
    let categories = try await repository.fetchAll()
    let groceries = categories.first { $0.name == "Groceries" }!
    let transport = categories.first { $0.name == "Transport" }!

    // Delete Groceries and replace with Transport
    try await repository.delete(id: groceries.id, withReplacement: transport.id)

    let remaining = try await repository.fetchAll()
    // Should have Transport and Fruit (now under Transport)
    #expect(remaining.count == 2)

    let updatedFruit = remaining.first { $0.name == "Fruit" }!
    #expect(updatedFruit.parentId == transport.id)
  }

  @Test(
    "InMemoryCategoryRepository - deletes category and orphans children",
    arguments: [
      makeRepositoryWithHierarchy()
    ])
  func testDeletesCategoryAndOrphansChildren(repository: InMemoryCategoryRepository) async throws {
    let categories = try await repository.fetchAll()
    let groceries = categories.first { $0.name == "Groceries" }!

    // Delete Groceries without replacement
    try await repository.delete(id: groceries.id, withReplacement: nil)

    let remaining = try await repository.fetchAll()
    // Should have Transport and Fruit (now top-level)
    #expect(remaining.count == 2)

    let updatedFruit = remaining.first { $0.name == "Fruit" }!
    #expect(updatedFruit.parentId == nil)
  }

  @Test(
    "InMemoryCategoryRepository - throws on update non-existent",
    arguments: [
      InMemoryCategoryRepository()
    ])
  func testThrowsOnUpdateNonExistent(repository: InMemoryCategoryRepository) async throws {
    let nonExistent = Category(name: "DoesNotExist")

    await #expect(throws: BackendError.serverError(404)) {
      _ = try await repository.update(nonExistent)
    }
  }

  @Test(
    "InMemoryCategoryRepository - throws on delete non-existent",
    arguments: [
      InMemoryCategoryRepository()
    ])
  func testThrowsOnDeleteNonExistent(repository: InMemoryCategoryRepository) async throws {
    await #expect(throws: BackendError.serverError(404)) {
      try await repository.delete(id: UUID(), withReplacement: nil)
    }
  }
}

private func makeRepositoryWithHierarchy() -> InMemoryCategoryRepository {
  let groceriesId = UUID()
  return InMemoryCategoryRepository(initialCategories: [
    Category(id: groceriesId, name: "Groceries"),
    Category(name: "Fruit", parentId: groceriesId),
    Category(name: "Transport"),
  ])
}
