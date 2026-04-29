import Foundation

protocol TransactionRepository: Sendable {
  func fetch(filter: TransactionFilter, page: Int, pageSize: Int) async throws -> TransactionPage
  /// Returns every matching transaction without pagination. Used by bulk
  /// consumers (profile export, profile import) where paginating forces the
  /// backend to re-filter and re-sort the whole dataset per page. Skips the
  /// prior-balance computation since it is not meaningful for the bulk path.
  func fetchAll(filter: TransactionFilter) async throws -> [Transaction]
  func create(_ transaction: Transaction) async throws -> Transaction
  func update(_ transaction: Transaction) async throws -> Transaction
  func delete(id: UUID) async throws
  /// Frequency-sorted payee strings beginning with `prefix`. When
  /// `excludingTransactionId` is supplied, the matching transaction does
  /// not contribute to the frequency count and its payee will not appear
  /// in the result if no other transaction shares it. Unknown ids — and
  /// unsaved drafts — leave the unfiltered list intact.
  func fetchPayeeSuggestions(prefix: String, excludingTransactionId: UUID?) async throws
    -> [String]
}

extension TransactionRepository {
  /// Convenience overload with `excludingTransactionId` defaulting to
  /// `nil`. Returns the unfiltered frequency-sorted prefix matches.
  func fetchPayeeSuggestions(prefix: String) async throws -> [String] {
    try await fetchPayeeSuggestions(prefix: prefix, excludingTransactionId: nil)
  }
}
