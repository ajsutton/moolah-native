import Foundation
import SwiftData
import Testing

@testable import Moolah

@Suite("CategoryRepository Contract")
struct CategoryRepositoryContractTests {
  @Test("creates category")
  func testCreatesCategory() async throws {
    let repository = makeCloudKitCategoryRepository()
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
    let repository = makeCloudKitCategoryRepository(initialCategories: [
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
    let repository = makeCloudKitCategoryRepository(initialCategories: [
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
    let repository = makeCloudKitRepositoryWithHierarchy()
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
    let repository = makeCloudKitRepositoryWithHierarchy()
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
    let repository = makeCloudKitCategoryRepository()
    let nonExistent = Category(name: "DoesNotExist")

    await #expect(throws: BackendError.serverError(404)) {
      _ = try await repository.update(nonExistent)
    }
  }

  @Test("throws on delete non-existent")
  func testThrowsOnDeleteNonExistent() async throws {
    let repository = makeCloudKitCategoryRepository()
    await #expect(throws: BackendError.serverError(404)) {
      try await repository.delete(id: UUID(), withReplacement: nil)
    }
  }

  @Test("deleting category nulls categoryId on transactions")
  func testDeleteCategoryCascadesToTransactions() async throws {
    let backend = CloudKitCategoryTestBackend()
    let account = Account(
      id: UUID(),
      name: "Test Account",
      type: .bank,
      balance: MonetaryAmount(cents: 0, currency: .defaultTestCurrency)
    )
    _ = try await backend.accounts.create(account)

    let category = Category(id: UUID(), name: "Groceries")
    _ = try await backend.categories.create(category)

    let txn = Transaction(
      type: .expense,
      date: Date(),
      accountId: account.id,
      amount: MonetaryAmount(cents: -500, currency: .defaultTestCurrency),
      payee: "Store",
      categoryId: category.id
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
    #expect(updated?.categoryId == nil, "categoryId should be nulled after category deletion")
  }

  @Test("deleting category cascades to budget items")
  func testDeleteCategoryCascadesToBudgets() async throws {
    let backend = CloudKitCategoryTestBackend()
    let category = Category(id: UUID(), name: "Groceries")
    _ = try await backend.categories.create(category)

    let earmark = Earmark(id: UUID(), name: "Savings")
    _ = try await backend.earmarks.create(earmark)

    // Set a budget for the category
    try await backend.earmarks.setBudget(
      earmarkId: earmark.id, categoryId: category.id, amount: 50000)

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
    let backend = CloudKitCategoryTestBackend()
    let groceries = Category(id: UUID(), name: "Groceries")
    let food = Category(id: UUID(), name: "Food")
    _ = try await backend.categories.create(groceries)
    _ = try await backend.categories.create(food)

    let earmark = Earmark(id: UUID(), name: "Savings")
    _ = try await backend.earmarks.create(earmark)

    // Set a budget for groceries
    try await backend.earmarks.setBudget(
      earmarkId: earmark.id, categoryId: groceries.id, amount: 50000)

    // Delete groceries with food as replacement
    try await backend.categories.delete(id: groceries.id, withReplacement: food.id)

    // Budget item should now reference food
    let budget = try await backend.earmarks.fetchBudget(earmarkId: earmark.id)
    #expect(budget.count == 1, "Budget should have one entry")
    #expect(budget.first?.categoryId == food.id, "Budget should reference replacement category")
    #expect(budget.first?.amount.cents == 50000, "Budget amount should be preserved")
  }
}

private struct CloudKitCategoryTestBackend: BackendProvider, @unchecked Sendable {
  let auth: any AuthProvider
  let accounts: any AccountRepository
  let transactions: any TransactionRepository
  let categories: any CategoryRepository
  let earmarks: any EarmarkRepository
  let analysis: any AnalysisRepository
  let investments: any InvestmentRepository

  init() {
    let container = try! TestModelContainer.create()
    let currency = Currency.defaultTestCurrency
    self.auth = InMemoryAuthProvider()
    self.accounts = CloudKitAccountRepository(
      modelContainer: container, currency: currency)
    self.transactions = CloudKitTransactionRepository(
      modelContainer: container, currency: currency)
    self.categories = CloudKitCategoryRepository(
      modelContainer: container)
    self.earmarks = CloudKitEarmarkRepository(
      modelContainer: container, currency: currency)
    self.analysis = CloudKitAnalysisRepository(
      modelContainer: container, currency: currency)
    self.investments = CloudKitInvestmentRepository(
      modelContainer: container, currency: currency)
  }
}

private func makeCloudKitCategoryRepository(
  initialCategories: [Moolah.Category] = []
) -> CloudKitCategoryRepository {
  let container = try! TestModelContainer.create()
  let repo = CloudKitCategoryRepository(modelContainer: container)

  if !initialCategories.isEmpty {
    let context = ModelContext(container)
    for category in initialCategories {
      context.insert(CategoryRecord.from(category))
    }
    try! context.save()
  }

  return repo
}

private func makeCloudKitRepositoryWithHierarchy() -> CloudKitCategoryRepository {
  let groceriesId = UUID()
  return makeCloudKitCategoryRepository(initialCategories: [
    Moolah.Category(id: groceriesId, name: "Groceries"),
    Moolah.Category(name: "Fruit", parentId: groceriesId),
    Moolah.Category(name: "Transport"),
  ])
}
