import Foundation

protocol TransactionRepository: Sendable {
  func fetch(filter: TransactionFilter, page: Int, pageSize: Int) async throws -> TransactionPage
  func create(_ transaction: Transaction) async throws -> Transaction
  func update(_ transaction: Transaction) async throws -> Transaction
  func delete(id: UUID) async throws
  func fetchPayeeSuggestions(prefix: String) async throws -> [String]
}
