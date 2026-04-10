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

  init(modelContainer: ModelContainer, profileId: UUID, currency: Currency, profileLabel: String) {
    self.auth = CloudKitAuthProvider(profileLabel: profileLabel)
    self.accounts = CloudKitAccountRepository(
      modelContainer: modelContainer, profileId: profileId, currency: currency)
    self.transactions = CloudKitTransactionRepository(
      modelContainer: modelContainer, profileId: profileId, currency: currency)
    self.categories = CloudKitCategoryRepository(
      modelContainer: modelContainer, profileId: profileId)
    self.earmarks = CloudKitEarmarkRepository(
      modelContainer: modelContainer, profileId: profileId, currency: currency)
    self.analysis = CloudKitAnalysisRepository(
      modelContainer: modelContainer, profileId: profileId, currency: currency)
    self.investments = CloudKitInvestmentRepository(
      modelContainer: modelContainer, profileId: profileId, currency: currency)
  }
}
