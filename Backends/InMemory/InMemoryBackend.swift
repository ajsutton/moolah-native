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
  let investments: any InvestmentRepository

  init(
    currency: Currency = .AUD,
    auth: (any AuthProvider)? = nil,
    accounts: (any AccountRepository)? = nil,
    transactions: (any TransactionRepository)? = nil,
    categories: (any CategoryRepository)? = nil,
    earmarks: (any EarmarkRepository)? = nil,
    investments: (any InvestmentRepository)? = nil
  ) {
    // Use provided repositories or create defaults
    let authRepo = auth ?? InMemoryAuthProvider()
    let accountsRepo = accounts ?? InMemoryAccountRepository()
    let transactionsRepo = transactions ?? InMemoryTransactionRepository(currency: currency)
    let earmarksRepo = earmarks ?? InMemoryEarmarkRepository(currency: currency)
    let categoriesRepo =
      categories
      ?? InMemoryCategoryRepository(
        transactionRepository: transactionsRepo as? InMemoryTransactionRepository,
        earmarkRepository: earmarksRepo as? InMemoryEarmarkRepository
      )

    // Create analysis repository with dependencies
    // Analysis repository requires concrete InMemory types for computation
    let analysisRepo = InMemoryAnalysisRepository(
      transactionRepository: transactionsRepo as! InMemoryTransactionRepository,
      accountRepository: accountsRepo as! InMemoryAccountRepository,
      earmarkRepository: earmarksRepo as! InMemoryEarmarkRepository,
      currency: currency
    )

    // Assign to properties
    self.auth = authRepo
    self.accounts = accountsRepo
    self.transactions = transactionsRepo
    self.categories = categoriesRepo
    self.earmarks = earmarksRepo
    self.analysis = analysisRepo
    self.investments = investments ?? InMemoryInvestmentRepository()
  }
}
