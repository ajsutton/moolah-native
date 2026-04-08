import Foundation

/// Full in-memory implementation of BackendProvider.
/// Grows a property each time a new repository protocol is introduced.
final class InMemoryBackend: BackendProvider, @unchecked Sendable {
  let auth: any AuthProvider
  let accounts: any AccountRepository
  let transactions: any TransactionRepository
  let categories: any CategoryRepository
  let earmarks: any EarmarkRepository
  let analysis: any AnalysisRepository

  init() {
    // Create concrete repositories first
    let authRepo = InMemoryAuthProvider()
    let accountsRepo = InMemoryAccountRepository()
    let transactionsRepo = InMemoryTransactionRepository()
    let categoriesRepo = InMemoryCategoryRepository()
    let earmarksRepo = InMemoryEarmarkRepository()

    // Create analysis repository with dependencies
    let analysisRepo = InMemoryAnalysisRepository(
      transactionRepository: transactionsRepo,
      accountRepository: accountsRepo,
      earmarkRepository: earmarksRepo
    )

    // Assign to properties
    self.auth = authRepo
    self.accounts = accountsRepo
    self.transactions = transactionsRepo
    self.categories = categoriesRepo
    self.earmarks = earmarksRepo
    self.analysis = analysisRepo
  }
}
