import Foundation

protocol ExchangeClient: Sendable {
  func fetchTransactions(token: String) async throws -> [ExchangeImportedTransaction]
}
