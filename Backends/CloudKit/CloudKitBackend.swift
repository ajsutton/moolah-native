import Foundation
import SwiftData

final class CloudKitBackend: BackendProvider, @unchecked Sendable {
  let auth: any AuthProvider
  let accounts: any AccountRepository
  let transactions: any TransactionRepository
  let categories: any CategoryRepository
  let earmarks: any EarmarkRepository
  let analysis: any AnalysisRepository
  let investments: any InvestmentRepository

  init(modelContainer: ModelContainer, currency: Currency, profileLabel: String) {
    self.auth = CloudKitAuthProvider(profileLabel: profileLabel)
    self.accounts = CloudKitAccountRepository(modelContainer: modelContainer, currency: currency)
    self.transactions = CloudKitTransactionRepository(
      modelContainer: modelContainer, currency: currency)
    self.categories = CloudKitCategoryRepository(modelContainer: modelContainer)
    self.earmarks = CloudKitEarmarkRepository(modelContainer: modelContainer, currency: currency)
    self.analysis = CloudKitAnalysisRepository(modelContainer: modelContainer, currency: currency)
    self.investments = CloudKitInvestmentRepository(
      modelContainer: modelContainer, currency: currency)
  }
}
