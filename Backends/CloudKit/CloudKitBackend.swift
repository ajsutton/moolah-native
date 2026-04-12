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
  let conversionService: any InstrumentConversionService

  init(
    modelContainer: ModelContainer,
    instrument: Instrument,
    profileLabel: String,
    conversionService: (any InstrumentConversionService)? = nil
  ) {
    self.auth = CloudKitAuthProvider(profileLabel: profileLabel)
    self.accounts = CloudKitAccountRepository(
      modelContainer: modelContainer, instrument: instrument)
    self.transactions = CloudKitTransactionRepository(
      modelContainer: modelContainer, instrument: instrument)
    self.categories = CloudKitCategoryRepository(modelContainer: modelContainer)
    self.earmarks = CloudKitEarmarkRepository(
      modelContainer: modelContainer, instrument: instrument)
    self.analysis = CloudKitAnalysisRepository(
      modelContainer: modelContainer, instrument: instrument)
    self.investments = CloudKitInvestmentRepository(
      modelContainer: modelContainer, instrument: instrument)
    if let conversionService {
      self.conversionService = conversionService
    } else {
      let client = FrankfurterClient()
      let exchangeRates = ExchangeRateService(client: client)
      self.conversionService = FiatConversionService(exchangeRates: exchangeRates)
    }
  }
}
