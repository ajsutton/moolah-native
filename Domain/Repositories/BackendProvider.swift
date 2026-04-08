import Foundation

/// Single injection point for all repository and auth instances.
/// Pass a different BackendProvider to @Environment to swap the entire backend.
protocol BackendProvider: Sendable {
  var auth: any AuthProvider { get }
  var accounts: any AccountRepository { get }
  var transactions: any TransactionRepository { get }
  var categories: any CategoryRepository { get }
  var earmarks: any EarmarkRepository { get }
  var analysis: any AnalysisRepository { get }
  var investments: any InvestmentRepository { get }
}
