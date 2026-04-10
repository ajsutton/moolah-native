import Foundation
import SwiftData
import Testing

@testable import Moolah

@Suite("CategoryRepository Contract")
struct CategoryRepositoryContractTests {
  @Test(
    "creates category",
    arguments: [
      InMemoryCategoryRepository() as any CategoryRepository,
      makeCloudKitCategoryRepository() as any CategoryRepository,
    ])
  func testCreatesCategory(repository: any CategoryRepository) async throws {
    let newCategory = Category(name: "Groceries")

    let created = try await repository.create(newCategory)

    #expect(created.id == newCategory.id)
    #expect(created.name == "Groceries")

    let all = try await repository.fetchAll()
    #expect(all.count == 1)
    #expect(all[0].name == "Groceries")
  }

  @Test(
    "updates category name",
    arguments: [
      InMemoryCategoryRepository(initialCategories: [
        Category(id: UUID(), name: "Groceries")
      ]) as any CategoryRepository,
      makeCloudKitCategoryRepository(initialCategories: [
        Category(id: UUID(), name: "Groceries")
      ]) as any CategoryRepository,
    ])
  func testUpdatesCategory(repository: any CategoryRepository) async throws {
    let categories = try await repository.fetchAll()
    var toUpdate = categories[0]
    toUpdate.name = "Food & Groceries"

    let updated = try await repository.update(toUpdate)

    #expect(updated.name == "Food & Groceries")

    let all = try await repository.fetchAll()
    #expect(all[0].name == "Food & Groceries")
  }

  @Test(
    "deletes category without replacement",
    arguments: [
      InMemoryCategoryRepository(initialCategories: [
        Category(id: UUID(), name: "Groceries"),
        Category(id: UUID(), name: "Transport"),
      ]) as any CategoryRepository,
      makeCloudKitCategoryRepository(initialCategories: [
        Category(id: UUID(), name: "Groceries"),
        Category(id: UUID(), name: "Transport"),
      ]) as any CategoryRepository,
    ])
  func testDeletesCategoryWithoutReplacement(repository: any CategoryRepository) async throws {
    let categories = try await repository.fetchAll()
    let toDelete = categories[0]

    try await repository.delete(id: toDelete.id, withReplacement: nil)

    let remaining = try await repository.fetchAll()
    #expect(remaining.count == 1)
    #expect(remaining[0].name == "Transport")
  }

  @Test(
    "deletes category and updates children",
    arguments: [
      makeRepositoryWithHierarchy() as any CategoryRepository,
      makeCloudKitRepositoryWithHierarchy() as any CategoryRepository,
    ])
  func testDeletesCategoryAndUpdatesChildren(repository: any CategoryRepository) async throws {
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
    "deletes category and orphans children",
    arguments: [
      makeRepositoryWithHierarchy() as any CategoryRepository,
      makeCloudKitRepositoryWithHierarchy() as any CategoryRepository,
    ])
  func testDeletesCategoryAndOrphansChildren(repository: any CategoryRepository) async throws {
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
    "throws on update non-existent",
    arguments: [
      InMemoryCategoryRepository() as any CategoryRepository,
      makeCloudKitCategoryRepository() as any CategoryRepository,
    ])
  func testThrowsOnUpdateNonExistent(repository: any CategoryRepository) async throws {
    let nonExistent = Category(name: "DoesNotExist")

    await #expect(throws: BackendError.serverError(404)) {
      _ = try await repository.update(nonExistent)
    }
  }

  @Test(
    "throws on delete non-existent",
    arguments: [
      InMemoryCategoryRepository() as any CategoryRepository,
      makeCloudKitCategoryRepository() as any CategoryRepository,
    ])
  func testThrowsOnDeleteNonExistent(repository: any CategoryRepository) async throws {
    await #expect(throws: BackendError.serverError(404)) {
      try await repository.delete(id: UUID(), withReplacement: nil)
    }
  }

  @Test(
    "deleting category nulls categoryId on transactions",
    arguments: [
      InMemoryBackend() as any BackendProvider,
      CloudKitCategoryTestBackend() as any BackendProvider,
    ])
  func testDeleteCategoryCascadesToTransactions(backend: any BackendProvider) async throws {
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
    let profileId = UUID()
    let currency = Currency.defaultTestCurrency
    self.auth = InMemoryAuthProvider()
    self.accounts = CloudKitAccountRepository(
      modelContainer: container, profileId: profileId, currency: currency)
    self.transactions = CloudKitTransactionRepository(
      modelContainer: container, profileId: profileId, currency: currency)
    self.categories = CloudKitCategoryRepository(
      modelContainer: container, profileId: profileId)
    self.earmarks = CloudKitEarmarkRepository(
      modelContainer: container, profileId: profileId, currency: currency)
    self.analysis = CloudKitAnalysisRepository(
      modelContainer: container, profileId: profileId, currency: currency)
    self.investments = InMemoryInvestmentRepository()
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

private func makeCloudKitCategoryRepository(
  initialCategories: [Moolah.Category] = []
) -> CloudKitCategoryRepository {
  let container = try! TestModelContainer.create()
  let profileId = UUID()
  let repo = CloudKitCategoryRepository(modelContainer: container, profileId: profileId)

  if !initialCategories.isEmpty {
    let context = ModelContext(container)
    for category in initialCategories {
      context.insert(CategoryRecord.from(category, profileId: profileId))
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
