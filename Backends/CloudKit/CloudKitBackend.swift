// swiftlint:disable multiline_arguments

import Foundation
import GRDB
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
  let instrumentRegistry: any InstrumentRegistryRepository
  /// Concrete GRDB-backed repositories for the record types covered by
  /// `v2_csv_import_and_rules`. Exposed alongside the protocol-typed
  /// `csvImportProfiles` / `importRules` so `ProfileSession` can register
  /// them with `SyncCoordinator` (which needs the concrete actor type to
  /// reach the synchronous sync entry points). The protocol-typed
  /// properties point at the same instances.
  let grdbCSVImportProfiles: GRDBCSVImportProfileRepository
  let grdbImportRules: GRDBImportRuleRepository

  init(
    modelContainer: ModelContainer,
    database: any DatabaseWriter,
    instrument: Instrument,
    profileLabel: String,
    conversionService: any InstrumentConversionService,
    instrumentRegistry: any InstrumentRegistryRepository,
    onCSVImportProfileChanged: @escaping @Sendable (String, UUID) -> Void = { _, _ in },
    onCSVImportProfileDeleted: @escaping @Sendable (String, UUID) -> Void = { _, _ in },
    onImportRuleChanged: @escaping @Sendable (String, UUID) -> Void = { _, _ in },
    onImportRuleDeleted: @escaping @Sendable (String, UUID) -> Void = { _, _ in }
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
    let csvRepo = GRDBCSVImportProfileRepository(
      database: database,
      onRecordChanged: onCSVImportProfileChanged,
      onRecordDeleted: onCSVImportProfileDeleted)
    let ruleRepo = GRDBImportRuleRepository(
      database: database,
      onRecordChanged: onImportRuleChanged,
      onRecordDeleted: onImportRuleDeleted)
    self.grdbCSVImportProfiles = csvRepo
    self.grdbImportRules = ruleRepo
    self.csvImportProfiles = csvRepo
    self.importRules = ruleRepo
    self.instrumentRegistry = instrumentRegistry
  }
}
