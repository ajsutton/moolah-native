import Foundation
import GRDB
import SwiftData
import Testing

@testable import Moolah

@Suite("CategoryRepository Contract")
struct CategoryRepositoryContractTests {
  @Test("creates category")
  func testCreatesCategory() async throws {
    let repository = try makeCloudKitCategoryRepository()
    let newCategory = Category(name: "Groceries")

    let created = try await repository.create(newCategory)

    #expect(created.id == newCategory.id)
    #expect(created.name == "Groceries")

    let all = try await repository.fetchAll()
    #expect(all.count == 1)
    #expect(all[0].name == "Groceries")
  }

  @Test("updates category name")
  func testUpdatesCategory() async throws {
    let repository = try makeCloudKitCategoryRepository(initialCategories: [
      Category(id: UUID(), name: "Groceries")
    ])
    let categories = try await repository.fetchAll()
    var toUpdate = categories[0]
    toUpdate.name = "Food & Groceries"

    let updated = try await repository.update(toUpdate)

    #expect(updated.name == "Food & Groceries")

    let all = try await repository.fetchAll()
    #expect(all[0].name == "Food & Groceries")
  }

  @Test("deletes category without replacement")
  func testDeletesCategoryWithoutReplacement() async throws {
    let repository = try makeCloudKitCategoryRepository(initialCategories: [
      Category(id: UUID(), name: "Groceries"),
      Category(id: UUID(), name: "Transport"),
    ])
    let categories = try await repository.fetchAll()
    let toDelete = categories[0]

    try await repository.delete(id: toDelete.id, withReplacement: nil)

    let remaining = try await repository.fetchAll()
    #expect(remaining.count == 1)
    #expect(remaining[0].name == "Transport")
  }

  @Test("deletes category and orphans children even with replacement")
  func testDeletesCategoryOrphansChildrenEvenWithReplacement() async throws {
    let repository = try makeCloudKitRepositoryWithHierarchy()
    let categories = try await repository.fetchAll()
    let groceries = categories.first { $0.name == "Groceries" }!
    let transport = categories.first { $0.name == "Transport" }!

    // Delete Groceries with Transport as replacement
    // Server behavior: children are always orphaned (parent_id = NULL),
    // replacement only applies to transactions and budgets
    try await repository.delete(id: groceries.id, withReplacement: transport.id)

    let remaining = try await repository.fetchAll()
    // Should have Transport and Fruit (now orphaned at top level)
    #expect(remaining.count == 2)

    let updatedFruit = remaining.first { $0.name == "Fruit" }!
    #expect(updatedFruit.parentId == nil, "Children should be orphaned, not reparented")
  }

  @Test("deletes category and orphans children")
  func testDeletesCategoryAndOrphansChildren() async throws {
    let repository = try makeCloudKitRepositoryWithHierarchy()
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

  @Test("throws on update non-existent")
  func testThrowsOnUpdateNonExistent() async throws {
    let repository = try makeCloudKitCategoryRepository()
    let nonExistent = Category(name: "DoesNotExist")

    await #expect(throws: BackendError.serverError(404)) {
      _ = try await repository.update(nonExistent)
    }
  }

  @Test("throws on delete non-existent")
  func testThrowsOnDeleteNonExistent() async throws {
    let repository = try makeCloudKitCategoryRepository()
    await #expect(throws: BackendError.serverError(404)) {
      try await repository.delete(id: UUID(), withReplacement: nil)
    }
  }

  @Test("deleting category nulls categoryId on transactions")
  func testDeleteCategoryCascadesToTransactions() async throws {
    let backend = try CloudKitCategoryTestBackend()
    let account = Account(
      id: UUID(),
      name: "Test Account",
      type: .bank,
      instrument: .defaultTestInstrument
    )
    _ = try await backend.accounts.create(account)

    let category = Category(id: UUID(), name: "Groceries")
    _ = try await backend.categories.create(category)

    let txn = Transaction(
      date: Date(),
      payee: "Store",
      legs: [
        TransactionLeg(
          accountId: account.id,
          instrument: .defaultTestInstrument,
          quantity: dec("-5.00"),
          type: .expense,
          categoryId: category.id
        )
      ]
    )
    let created = try await backend.transactions.create(txn)

    try await backend.categories.delete(id: category.id, withReplacement: nil)

    let page = try await backend.transactions.fetch(
      filter: TransactionFilter(),
      page: 0,
      pageSize: 50
    )
    let updated = page.transactions.first { $0.id == created.id }
    #expect(updated != nil, "Transaction should still exist")
    #expect(
      updated?.legs.allSatisfy { $0.categoryId == nil } == true,
      "categoryId should be nulled after category deletion")
  }

  @Test("deleting category cascades to budget items")
  func testDeleteCategoryCascadesToBudgets() async throws {
    let backend = try CloudKitCategoryTestBackend()
    let category = Category(id: UUID(), name: "Groceries")
    _ = try await backend.categories.create(category)

    let earmark = Earmark(id: UUID(), name: "Savings", instrument: .defaultTestInstrument)
    _ = try await backend.earmarks.create(earmark)

    // Set a budget for the category
    try await backend.earmarks.setBudget(
      earmarkId: earmark.id, categoryId: category.id,
      amount: InstrumentAmount(
        quantity: dec("500.00"), instrument: .defaultTestInstrument))

    let budgetBefore = try await backend.earmarks.fetchBudget(earmarkId: earmark.id)
    #expect(budgetBefore.count == 1)

    // Delete the category without replacement
    try await backend.categories.delete(id: category.id, withReplacement: nil)

    // Budget item should be removed
    let budgetAfter = try await backend.earmarks.fetchBudget(earmarkId: earmark.id)
    #expect(budgetAfter.isEmpty, "Budget items should be removed when category is deleted")
  }

  @Test("deleting category with replacement reassigns budget items")
  func testDeleteCategoryReassignsBudgets() async throws {
    let backend = try CloudKitCategoryTestBackend()
    let groceries = Category(id: UUID(), name: "Groceries")
    let food = Category(id: UUID(), name: "Food")
    _ = try await backend.categories.create(groceries)
    _ = try await backend.categories.create(food)

    let earmark = Earmark(id: UUID(), name: "Savings", instrument: .defaultTestInstrument)
    _ = try await backend.earmarks.create(earmark)

    // Set a budget for groceries
    try await backend.earmarks.setBudget(
      earmarkId: earmark.id, categoryId: groceries.id,
      amount: InstrumentAmount(
        quantity: dec("500.00"), instrument: .defaultTestInstrument))

    // Delete groceries with food as replacement
    try await backend.categories.delete(id: groceries.id, withReplacement: food.id)

    // Budget item should now reference food
    let budget = try await backend.earmarks.fetchBudget(earmarkId: earmark.id)
    #expect(budget.count == 1, "Budget should have one entry")
    #expect(budget.first?.categoryId == food.id, "Budget should reference replacement category")
    #expect(
      budget.first?.amount.quantity == dec("500.00"),
      "Budget amount should be preserved")
  }
}

/// Wraps a `TestBackend.create(...)` pair so contract tests that need a
/// `CategoryRepository` running inside a real `BackendProvider` (so they
/// can also exercise the cross-repo cascade behaviour) can grab the
/// concrete repo while keeping the rest of the backend wired up.
private struct CloudKitCategoryTestBackend: @unchecked Sendable {
  let backend: CloudKitBackend
  let database: DatabaseQueue

  var categories: any CategoryRepository { backend.categories }
  var transactions: any TransactionRepository { backend.transactions }
  var accounts: any AccountRepository { backend.accounts }
  var earmarks: any EarmarkRepository { backend.earmarks }

  init() throws {
    let pair = try TestBackend.create()
    self.backend = pair.backend
    self.database = pair.database
  }
}

private func makeCloudKitCategoryRepository(
  initialCategories: [Moolah.Category] = []
) throws -> any CategoryRepository {
  let pair = try TestBackend.create()
  if !initialCategories.isEmpty {
    TestBackend.seed(categories: initialCategories, in: pair.database)
  }
  return pair.backend.categories
}

private func makeCloudKitRepositoryWithHierarchy() throws -> any CategoryRepository {
  let groceriesId = UUID()
  return try makeCloudKitCategoryRepository(initialCategories: [
    Moolah.Category(id: groceriesId, name: "Groceries"),
    Moolah.Category(name: "Fruit", parentId: groceriesId),
    Moolah.Category(name: "Transport"),
  ])
}
