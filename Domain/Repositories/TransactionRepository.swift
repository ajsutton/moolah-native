import Foundation

protocol TransactionRepository: Sendable {
  func fetch(filter: TransactionFilter, page: Int, pageSize: Int) async throws -> [Transaction]
}
