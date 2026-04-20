import Foundation
import SwiftData

/// Factory for creating CloudKitBackend instances for SwiftUI previews.
/// Uses in-memory SwiftData — no CloudKit sync, fast initialization.
enum PreviewBackend {
  static func create(instrument: Instrument = .AUD) -> (CloudKitBackend, ModelContainer) {
    let schema = Schema([
      AccountRecord.self,
      TransactionRecord.self,
      TransactionLegRecord.self,
      InstrumentRecord.self,
      CategoryRecord.self,
      EarmarkRecord.self,
      EarmarkBudgetItemRecord.self,
      InvestmentValueRecord.self,
      CSVImportProfileRecord.self,
      ImportRuleRecord.self,
    ])
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try! ModelContainer(for: schema, configurations: [config])
    let exchangeRates = ExchangeRateService(
      client: FrankfurterClient(),
      cacheDirectory: FileManager.default.temporaryDirectory
        .appendingPathComponent("preview-rates")
    )
    let conversionService = FiatConversionService(exchangeRates: exchangeRates)
    let backend = CloudKitBackend(
      modelContainer: container,
      instrument: instrument, profileLabel: "Preview",
      conversionService: conversionService
    )
    return (backend, container)
  }
}
