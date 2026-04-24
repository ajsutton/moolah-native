// swiftlint:disable multiline_arguments

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
    // In-memory ModelContainer construction on a known schema never fails at
    // runtime. Previews don't render on main in production so a crash here
    // only affects SwiftUI canvas rendering.
    // swiftlint:disable:next force_try
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
      conversionService: conversionService,
      instrumentRegistry: CloudKitInstrumentRegistryRepository(modelContainer: container)
    )
    return (backend, container)
  }
}
