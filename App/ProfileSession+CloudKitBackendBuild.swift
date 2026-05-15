import CloudKit
import Foundation
import GRDB
import OSLog

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
    // duplication. Production ALWAYS lands here:
    // `MoolahApp.bootstrapSyncCoordinator` constructs the only
    // production `SyncCoordinator` with a non-nil
    // `sharedInstrumentRegistry`, so the fallback below is reached
    // exclusively by legacy callers (preview / tests) that didn't pass
    // a shared instance through `SyncCoordinator.init`.
    let registry: GRDBInstrumentRegistryRepository
    if let shared = syncCoordinator?.sharedInstrumentRegistry {
      registry = shared
    } else {
      // Preview / test fallback. The registry is built over a
      // profile-index database — never the per-profile `data.sqlite`:
      // the `v10_drop_shared_instrument_legacy` migration removed the
      // per-profile `instrument` table, so instrument identity lives
      // solely on the profile-index registry. When a coordinator is
      // present its container manager's profile-index DB is reused;
      // otherwise a fresh in-memory profile-index DB stands in.
      //
      // The shared-registry path drives all remote-change fan-out via
      // `SyncCoordinator.makeInstrumentRemoteChangeFanOut` (installed
      // by `SyncCoordinator.init` on the profile-index handler), so
      // no extra wiring is needed here.
      registry = makeInstrumentRegistry(
        zoneID: zoneID, syncCoordinator: syncCoordinator)
    }
    // CloudKit profiles need full stock+crypto conversion support. The
    // closure reads the profile's registry on each conversion so
    // registrations added at runtime become usable without rebuilding the
    // service. See issue #102.
    //
    // `observeRates()` watches the rate-cache tables for change ticks.
    // The shared price services live on the profile-index DB, so the
    // observation must follow — watching the per-profile DB would
    // silently miss every cache write. Fall back to the per-profile DB
    // only for legacy callers that didn't pass a coordinator with
    // shared services (preview / tests).
    let rateObservationDatabase: any DatabaseWriter =
      syncCoordinator?.containerManager.profileIndexDatabase ?? database
    let conversionService = FullConversionService(
      exchangeRates: marketData.exchangeRates,
      stockPrices: marketData.stockPrices,
      cryptoPrices: marketData.cryptoPrices,
      cryptoRegistrations: {
        try await registry.allCryptoRegistrations()
      },
      database: rateObservationDatabase
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
          syncCoordinator: syncCoordinator))
    )
  }

  /// Builds the closure `GRDBTransactionRepository` /
  /// `GRDBAccountRepository` fire whenever they auto-insert a non-fiat
  /// `InstrumentRow` to satisfy a leg or account denomination. Routes
  /// through the **shared** registry's `registerStock` /
  /// `registerCrypto`, which writes to the profile-index DB and queues
  /// the upload to the profile-index zone — never to a per-profile
  /// zone. Without this, an instrument introduced by SelfWealth import
  /// or a stock-account create would live only on the device that
  /// wrote it (sibling devices fall back to `Instrument.fiat(code:
  /// id)` and stock conversions 404 against the fiat-only Frankfurter
  /// API). Returns a no-op closure when no shared registry is wired
  /// (preview / legacy-test backends without `SharedInstrumentScope`).
  private static func makeInstrumentChangedHook(
    syncCoordinator: SyncCoordinator?
  ) -> @Sendable (Instrument) -> Void {
    { [weak syncCoordinator] instrument in
      // Fiat doesn't go through the registry; defensively no-op even
      // though `ensureInstrumentReadable` already filters fiat out.
      guard instrument.kind != .fiatCurrency else { return }
      Task { [weak syncCoordinator] in
        guard let registry = syncCoordinator?.sharedInstrumentRegistry else { return }
        await Self.publishToSharedRegistry(instrument: instrument, registry: registry)
      }
    }
  }

  /// Publishes an auto-inserted `Instrument` to the shared registry.
  /// Stocks go through `registerStock`; crypto rows go through
  /// `registerCrypto` with an empty provider mapping (the discovery
  /// service fills the mapping in later via `resolveOrLoad`). Both
  /// register methods are idempotent — they upsert by id and preserve
  /// existing system fields, so a redundant publish from
  /// `ensureInstrumentReadable` after the row already reached the
  /// shared zone is a no-op merge.
  private static func publishToSharedRegistry(
    instrument: Instrument,
    registry: GRDBInstrumentRegistryRepository
  ) async {
    do {
      switch instrument.kind {
      case .stock:
        try await registry.registerStock(instrument)
      case .cryptoToken:
        try await registry.registerCrypto(
          instrument,
          mapping: CryptoProviderMapping(
            instrumentId: instrument.id,
            coingeckoId: nil,
            cryptocompareSymbol: nil,
            binanceSymbol: nil))
      case .fiatCurrency:
        // Filtered out at the call site; defensive no-op.
        return
      }
    } catch {
      // Best-effort publish — a failure here leaves the per-profile
      // copy intact and the next session boot's self-heal scan
      // (`SyncCoordinator.queueUnsyncedSharedInstruments`) re-attempts
      // upload. Logging keeps the failure observable without breaking
      // the surrounding write.
      Logger(subsystem: "com.moolah.app", category: "ProfileSession")
        .warning(
          """
          Shared-registry publish failed for \(instrument.id, privacy: .public): \
          \(error.localizedDescription, privacy: .public)
          """
        )
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

  /// Builds the preview/test-only `GRDBInstrumentRegistryRepository`,
  /// wiring its mutation hooks to the sync coordinator's per-zone queue
  /// helpers. Extracted from `makeCloudKitBackend` so the per-mutation
  /// closure definitions don't bloat its body length.
  ///
  /// The registry is backed by a profile-index database, never the
  /// per-profile `data.sqlite` (whose `instrument` table the
  /// `v10_drop_shared_instrument_legacy` migration removed): the
  /// coordinator's container-manager profile-index DB when a coordinator
  /// is present, otherwise a fresh in-memory profile-index DB. This
  /// branch is unreachable in production — see `makeCloudKitBackend` —
  /// so trapping on the (test-harness-only) in-memory open failure
  /// mirrors `PreviewBackend`'s precedent and never affects shipping
  /// code.
  private static func makeInstrumentRegistry(
    zoneID: CKRecordZone.ID,
    syncCoordinator: SyncCoordinator?
  ) -> GRDBInstrumentRegistryRepository {
    let database: any DatabaseWriter
    if let containerManager = syncCoordinator?.containerManager {
      database = containerManager.profileIndexDatabase
    } else {
      // In-memory ProfileIndexDatabase.openInMemory() cannot fail (no
      // filesystem path); this branch is test-harness-only (no
      // coordinator) and never runs in production — see the doc comment.
      // swiftlint:disable:next force_try
      database = try! ProfileIndexDatabase.openInMemory()
    }
    return GRDBInstrumentRegistryRepository(
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

  // `wireInstrumentRemoteChangeFanOut` is intentionally absent here:
  // the shared registry on the profile-index zone drives every
  // InstrumentRecord remote-change fan-out via
  // `SyncCoordinator.makeInstrumentRemoteChangeFanOut`.
}
