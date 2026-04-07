import Foundation

actor InMemoryCategoryRepository: CategoryRepository {
  private var categories: [UUID: Category]

  init(initialCategories: [Category] = []) {
    self.categories = Dictionary(uniqueKeysWithValues: initialCategories.map { ($0.id, $0) })
  }

  func fetchAll() async throws -> [Category] {
    return Array(categories.values).sorted { $0.name < $1.name }
  }

  // For test setup
  func setCategories(_ categories: [Category]) {
    self.categories = Dictionary(uniqueKeysWithValues: categories.map { ($0.id, $0) })
  }
}
