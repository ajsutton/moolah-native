import Foundation

actor InMemoryCategoryRepository: CategoryRepository {
  private var categories: [UUID: Category]
  private let transactionRepository: InMemoryTransactionRepository?

  init(
    initialCategories: [Category] = [],
    transactionRepository: InMemoryTransactionRepository? = nil
  ) {
    self.categories = Dictionary(uniqueKeysWithValues: initialCategories.map { ($0.id, $0) })
    self.transactionRepository = transactionRepository
  }

  func fetchAll() async throws -> [Category] {
    return Array(categories.values).sorted { $0.name < $1.name }
  }

  func create(_ category: Category) async throws -> Category {
    categories[category.id] = category
    return category
  }

  func update(_ category: Category) async throws -> Category {
    guard categories[category.id] != nil else {
      throw BackendError.serverError(404)
    }
    categories[category.id] = category
    return category
  }

  func delete(id: UUID, withReplacement replacementId: UUID?) async throws {
    guard categories[id] != nil else {
      throw BackendError.serverError(404)
    }

    // Update any child categories to point to the replacement (or nil)
    for (childId, var child) in categories where child.parentId == id {
      child.parentId = replacementId
      categories[childId] = child
    }

    // Update transactions that reference this category
    await transactionRepository?.replaceCategoryId(id, with: replacementId)

    // Remove the category
    categories.removeValue(forKey: id)
  }

  // For test setup
  func setCategories(_ categories: [Category]) {
    self.categories = Dictionary(uniqueKeysWithValues: categories.map { ($0.id, $0) })
  }
}
