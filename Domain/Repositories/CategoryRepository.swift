import Foundation

protocol CategoryRepository: Sendable {
  func fetchAll() async throws -> [Category]
  func create(_ category: Category) async throws -> Category
  func update(_ category: Category) async throws -> Category
  func delete(id: UUID, withReplacement replacementId: UUID?) async throws
}
