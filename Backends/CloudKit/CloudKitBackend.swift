// swiftlint:disable multiline_arguments

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
  let csvImportProfiles: any CSVImportProfileRepository
  let importRules: any ImportRuleRepository

  init(
    modelContainer: ModelContainer,
    instrument: Instrument,
    profileLabel: String,
    conversionService: any InstrumentConversionService
  ) {
    self.auth = CloudKitAuthProvider(profileLabel: profileLabel)
    self.accounts = CloudKitAccountRepository(
      modelContainer: modelContainer)
    self.transactions = CloudKitTransactionRepository(
      modelContainer: modelContainer,
      instrument: instrument,
      conversionService: conversionService)
    self.categories = CloudKitCategoryRepository(modelContainer: modelContainer)
    self.earmarks = CloudKitEarmarkRepository(
      modelContainer: modelContainer, instrument: instrument)
    self.analysis = CloudKitAnalysisRepository(
      modelContainer: modelContainer, instrument: instrument,
      conversionService: conversionService)
    self.investments = CloudKitInvestmentRepository(
      modelContainer: modelContainer, instrument: instrument)
    self.conversionService = conversionService
    self.csvImportProfiles = CloudKitCSVImportProfileRepository(
      modelContainer: modelContainer)
    self.importRules = CloudKitImportRuleRepository(modelContainer: modelContainer)
  }
}
