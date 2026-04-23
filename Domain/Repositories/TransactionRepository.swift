import Foundation

protocol TransactionRepository: Sendable {
  func fetch(filter: TransactionFilter, page: Int, pageSize: Int) async throws -> TransactionPage
  /// Returns every matching transaction without pagination. Used by bulk
  /// consumers (profile export, migration) where paginating forces the
  /// backend to re-filter and re-sort the whole dataset per page. Skips the
  /// prior-balance computation since it is not meaningful for the bulk path.
  func fetchAll(filter: TransactionFilter) async throws -> [Transaction]
  func create(_ transaction: Transaction) async throws -> Transaction
  func update(_ transaction: Transaction) async throws -> Transaction
  func delete(id: UUID) async throws
  func fetchPayeeSuggestions(prefix: String) async throws -> [String]
}
