import Foundation
import GRDB
import SwiftData

/// Factory for creating CloudKitBackend instances for SwiftUI previews.
/// Uses an in-memory GRDB queue — no CloudKit sync, fast initialization.
/// A SwiftData ModelContainer is also created and returned so previews
/// that still seed via SwiftData can share the same wiring as
/// `TestBackend`; once every preview seed reaches GRDB directly the
/// container parameter can drop.
///
/// **`import GRDB` in `Shared/` is justified.** `DATABASE_CODE_GUIDE.md`
/// scopes `import GRDB` to `Backends/GRDB/` (and implicitly `App/`), but
/// `PreviewBackend` is the canonical preview-wiring helper that every
/// `Features/*/Views/*+Previews.swift` reaches for. Treat this file as
/// a peer to `TestBackend` — the second of two in-memory backend
/// factories — rather than as `Shared/` business logic. Moving it under
/// `Backends/GRDB/` would force every feature preview to import the
/// backend layer, which is a worse coupling than the targeted
/// preview-only import here.
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
    // swiftlint:disable:next force_try
    let database = try! ProfileDatabase.openInMemory()
    let exchangeRates = ExchangeRateService(
      client: FrankfurterClient(),
      database: database
    )
    let conversionService = FiatConversionService(exchangeRates: exchangeRates)
    let registry = GRDBInstrumentRegistryRepository(database: database)
    let backend = CloudKitBackend(
      database: database,
      instrument: instrument,
      profileLabel: "Preview",
      conversionService: conversionService,
      instrumentRegistry: registry
    )
    return (backend, container)
  }
}
