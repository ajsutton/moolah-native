import CloudKit
import Foundation
import GRDB

extension ProfileSession {
  /// Bundle of the three market-data services consumed by the CloudKit
  /// backend's `FullConversionService`. Lets `makeCloudKitBackend` take a
  /// single value instead of three separate parameters so it stays at
  /// SwiftLint's parameter-count policy.
  struct CloudKitMarketDataServices {
    let exchangeRates: ExchangeRateService
    let stockPrices: StockPriceService
    let cryptoPrices: CryptoPriceService
  }

  /// Builds the CloudKit `BackendProvider` branch of `makeBackend`. Pulled
  /// out so `makeBackend` itself stays at SwiftLint's body-length policy
  /// while still doing the full registry/conversion-service/backend wiring
  /// inline (the construction order is load-bearing — see issue #102).
  static func makeCloudKitBackend(
    profile: Profile,
    syncCoordinator: SyncCoordinator?,
    marketData: CloudKitMarketDataServices,
    database: any DatabaseWriter
  ) -> BackendProvider {
    let zoneID = CKRecordZone.ID(
      zoneName: "profile-\(profile.id.uuidString)",
      ownerName: CKCurrentUserDefaultName)
    // Prefer the app-level shared registry when the coordinator was
    // constructed with one. All sessions on the same iCloud account
    // then share a single registry instance, so spam classifications
    // and discovered-token resolutions propagate without per-profile
    // duplication. Fall back to a per-profile registry for legacy
    // callers (preview / tests) that didn't pass a shared instance
    // through `SyncCoordinator.init`.
    let registry: GRDBInstrumentRegistryRepository
    if let shared = syncCoordinator?.sharedInstrumentRegistry {
      registry = shared
    } else {
      // Per-profile fallback for legacy callers (preview / tests).
      // The shared-registry path drives all remote-change fan-out via
      // `SyncCoordinator.makeInstrumentRemoteChangeFanOut` (installed
      // by `SyncCoordinator.init` on the profile-index handler), so
      // no extra wiring is needed here.
      registry = makeInstrumentRegistry(
        database: database, zoneID: zoneID, syncCoordinator: syncCoordinator)
    }
    // CloudKit profiles need full stock+crypto conversion support. The
    // closure reads the profile's registry on each conversion so
    // registrations added at runtime become usable without rebuilding the
    // service. See issue #102.
    let conversionService = FullConversionService(
      exchangeRates: marketData.exchangeRates,
      stockPrices: marketData.stockPrices,
      cryptoPrices: marketData.cryptoPrices,
      cryptoRegistrations: {
        try await registry.allCryptoRegistrations()
      },
      database: database
    )
    let hooks = grdbRepoHooks(zoneID: zoneID, syncCoordinator: syncCoordinator)
    return CloudKitBackend(
      database: database,
      instrument: profile.instrument,
      profileLabel: profile.label,
      conversionService: conversionService,
      instrumentRegistry: registry,
      hooks: CloudKitBackend.CloudKitBackendHooks(
        onCSVImportProfileChanged: hooks.changed,
        onCSVImportProfileDeleted: hooks.deleted,
        onImportRuleChanged: hooks.changed,
        onImportRuleDeleted: hooks.deleted,
        onAccountChanged: hooks.changed,
        onAccountDeleted: hooks.deleted,
        onCategoryChanged: hooks.changed,
        onCategoryDeleted: hooks.deleted,
        onEarmarkChanged: hooks.changed,
        onEarmarkDeleted: hooks.deleted,
        onEarmarkBudgetItemChanged: hooks.changed,
        onEarmarkBudgetItemDeleted: hooks.deleted,
        onInvestmentChanged: hooks.changed,
        onInvestmentDeleted: hooks.deleted,
        onTransactionChanged: hooks.changed,
        onTransactionDeleted: hooks.deleted,
        onTransactionLegChanged: hooks.changed,
        onTransactionLegDeleted: hooks.deleted,
        onInstrumentChanged: makeInstrumentChangedHook(
          zoneID: zoneID, syncCoordinator: syncCoordinator))
    )
  }

  /// Builds the closure `GRDBTransactionRepository` /
  /// `GRDBAccountRepository` fire whenever they auto-insert a non-fiat
  /// `InstrumentRow` to satisfy a leg or account denomination. Routes
  /// through the same recordName-keyed `queueSave` path
  /// `GRDBInstrumentRegistryRepository.registerStock` already uses so
  /// the row reaches CloudKit on the next batch. Without this, an
  /// instrument introduced by SelfWealth import or a stock-account
  /// create would live only on the device that wrote it (sibling
  /// devices fall back to `Instrument.fiat(code: id)` and stock
  /// conversions 404 against the fiat-only Frankfurter API). Returns a
  /// no-op closure when no coordinator is wired (preview / test
  /// backends).
  private static func makeInstrumentChangedHook(
    zoneID: CKRecordZone.ID, syncCoordinator: SyncCoordinator?
  ) -> @Sendable (String) -> Void {
    { [weak syncCoordinator] recordName in
      Task { @MainActor [weak syncCoordinator] in
        syncCoordinator?.queueSave(recordName: recordName, zoneID: zoneID)
      }
    }
  }

  /// Bundle of the change/delete closures the GRDB repos call on each
  /// successful local mutation. Both record types share the same shape
  /// (`(recordType, id) -> queueSave/queueDeletion`), so a single pair
  /// covers them all — keeps the wiring uniform and small.
  private struct GRDBRepoHooks {
    let changed: @Sendable (String, UUID) -> Void
    let deleted: @Sendable (String, UUID) -> Void
  }

  /// Builds the GRDB-repo hook closures that fan local mutations out to
  /// the sync coordinator's queue. Returns no-op closures when no
  /// coordinator is wired (preview / test backends).
  private static func grdbRepoHooks(
    zoneID: CKRecordZone.ID, syncCoordinator: SyncCoordinator?
  ) -> GRDBRepoHooks {
    GRDBRepoHooks(
      changed: { [weak syncCoordinator] recordType, id in
        Task { @MainActor [weak syncCoordinator] in
          syncCoordinator?.queueSave(recordType: recordType, id: id, zoneID: zoneID)
        }
      },
      deleted: { [weak syncCoordinator] recordType, id in
        Task { @MainActor [weak syncCoordinator] in
          syncCoordinator?.queueDeletion(recordType: recordType, id: id, zoneID: zoneID)
        }
      })
  }

  /// Builds the `GRDBInstrumentRegistryRepository` for a profile, wiring
  /// its mutation hooks to the sync coordinator's per-zone queue helpers.
  /// Extracted from `makeCloudKitBackend` so the per-mutation closure
  /// definitions don't bloat its body length.
  private static func makeInstrumentRegistry(
    database: any DatabaseWriter,
    zoneID: CKRecordZone.ID,
    syncCoordinator: SyncCoordinator?
  ) -> GRDBInstrumentRegistryRepository {
    GRDBInstrumentRegistryRepository(
      database: database,
      onRecordChanged: { [weak syncCoordinator] recordName in
        // Registry callbacks may run off MainActor; hop onto MainActor to
        // reach the actor-isolated SyncCoordinator.queueSave(_:zoneID:).
        Task { @MainActor [weak syncCoordinator] in
          syncCoordinator?.queueSave(recordName: recordName, zoneID: zoneID)
        }
      },
      onRecordDeleted: { [weak syncCoordinator] recordName in
        Task { @MainActor [weak syncCoordinator] in
          syncCoordinator?.queueDeletion(recordName: recordName, zoneID: zoneID)
        }
      }
    )
  }

  // `wireInstrumentRemoteChangeFanOut` was removed in stage 14 — the
  // shared registry on the profile-index zone now drives every
  // InstrumentRecord remote-change fan-out via
  // `SyncCoordinator.makeInstrumentRemoteChangeFanOut`.
}
