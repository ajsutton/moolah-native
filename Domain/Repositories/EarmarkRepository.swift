import Foundation

protocol EarmarkRepository: Sendable {
  func fetchAll() async throws -> [Earmark]
  func create(_ earmark: Earmark) async throws -> Earmark
  func update(_ earmark: Earmark) async throws -> Earmark
  func fetchBudget(earmarkId: UUID) async throws -> [EarmarkBudgetItem]
  func setBudget(earmarkId: UUID, categoryId: UUID, amount: Int) async throws
}
