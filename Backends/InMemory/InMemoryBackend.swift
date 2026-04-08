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

  init(
    auth: (any AuthProvider)? = nil,
    accounts: (any AccountRepository)? = nil,
    transactions: (any TransactionRepository)? = nil,
    categories: (any CategoryRepository)? = nil,
    earmarks: (any EarmarkRepository)? = nil
  ) {
    // Use provided repositories or create defaults
    let authRepo = auth ?? InMemoryAuthProvider()
    let accountsRepo = accounts ?? InMemoryAccountRepository()
    let transactionsRepo = transactions ?? InMemoryTransactionRepository()
    let categoriesRepo = categories ?? InMemoryCategoryRepository()
    let earmarksRepo = earmarks ?? InMemoryEarmarkRepository()

    // Create analysis repository with dependencies
    // Analysis repository requires concrete InMemory types for computation
    let analysisRepo = InMemoryAnalysisRepository(
      transactionRepository: transactionsRepo as! InMemoryTransactionRepository,
      accountRepository: accountsRepo as! InMemoryAccountRepository,
      earmarkRepository: earmarksRepo as! InMemoryEarmarkRepository
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
