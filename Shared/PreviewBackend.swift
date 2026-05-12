import Foundation
import GRDB

/// Factory for creating CloudKitBackend instances for SwiftUI previews.
/// Uses an in-memory GRDB queue — no CloudKit sync, fast initialization.
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
  /// Builds a CloudKit-shaped backend for SwiftUI previews. The
  /// optional `sharedRegistry` mirrors `TestBackend.create`'s
  /// equivalent parameter — pass the same instance across multiple
  /// preview backends to share one registry like production does.
  /// Defaults to a fresh per-call registry against the per-call
  /// in-memory `ProfileDatabase`.
  static func create(
    instrument: Instrument = .AUD,
    sharedRegistry: GRDBInstrumentRegistryRepository? = nil
  ) -> CloudKitBackend {
    // swiftlint:disable:next force_try
    let database = try! ProfileDatabase.openInMemory()
    let exchangeRates = ExchangeRateService(
      client: FrankfurterClient(),
      database: database
    )
    let conversionService = FiatConversionService(
      exchangeRates: exchangeRates, database: database)
    let registry =
      sharedRegistry
      ?? GRDBInstrumentRegistryRepository(database: database)
    return CloudKitBackend(
      database: database,
      instrument: instrument,
      profileLabel: "Preview",
      conversionService: conversionService,
      instrumentRegistry: registry
    )
  }
}
