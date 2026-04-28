import CloudKit
import Foundation
import GRDB
import SwiftData

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
    containerManager: ProfileContainerManager,
    syncCoordinator: SyncCoordinator?,
    marketData: CloudKitMarketDataServices,
    database: any DatabaseWriter
  ) -> BackendProvider {
    // A missing container here means the profile can't be constructed;
    // every call site depends on the session existing so there's no recovery.
    // swiftlint:disable:next force_try
    let profileContainer = try! containerManager.container(for: profile.id)
    let zoneID = CKRecordZone.ID(
      zoneName: "profile-\(profile.id.uuidString)",
      ownerName: CKCurrentUserDefaultName)
    let registry = makeInstrumentRegistry(
      profileContainer: profileContainer, zoneID: zoneID, syncCoordinator: syncCoordinator)
    // Wire the inverse direction: when the per-profile data handler
    // applies a remote pull that touches `InstrumentRecord` rows, fan
    // out to the registry's local subscribers so the picker UI refreshes
    // without waiting for an app relaunch.
    wireInstrumentRemoteChangeFanOut(
      registry: registry, profileId: profile.id, syncCoordinator: syncCoordinator)
    // CloudKit profiles need full stock+crypto conversion support. The
    // closure reads the profile's registry on each conversion so
    // registrations added at runtime become usable without rebuilding the
    // service. See issue #102.
    let conversionService = FullConversionService(
      exchangeRates: marketData.exchangeRates,
      stockPrices: marketData.stockPrices,
      cryptoPrices: marketData.cryptoPrices,
      providerMappings: {
        try await registry.allCryptoRegistrations().map(\.mapping)
      }
    )
    let hooks = grdbRepoHooks(zoneID: zoneID, syncCoordinator: syncCoordinator)
    return CloudKitBackend(
      modelContainer: profileContainer,
      database: database,
      instrument: profile.instrument,
      profileLabel: profile.label,
      conversionService: conversionService,
      instrumentRegistry: registry,
      onCSVImportProfileChanged: hooks.changed,
      onCSVImportProfileDeleted: hooks.deleted,
      onImportRuleChanged: hooks.changed,
      onImportRuleDeleted: hooks.deleted
    )
  }

  /// Bundle of the change/delete closures the GRDB repos call on each
  /// successful local mutation. Both record types share the same shape
  /// (`(recordType, id) -> queueSave/queueDeletion`), so a single pair
  /// covers both — slice 0 keeps the wiring uniform and small.
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

  /// Builds the `CloudKitInstrumentRegistryRepository` for a profile, wiring
  /// its mutation hooks to the sync coordinator's per-zone queue helpers.
  /// Extracted from `makeCloudKitBackend` so the per-mutation closure
  /// definitions don't bloat its body length.
  private static func makeInstrumentRegistry(
    profileContainer: ModelContainer,
    zoneID: CKRecordZone.ID,
    syncCoordinator: SyncCoordinator?
  ) -> CloudKitInstrumentRegistryRepository {
    CloudKitInstrumentRegistryRepository(
      modelContainer: profileContainer,
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

  /// Registers the closure that the per-profile data handler invokes when
  /// a remote pull touches an `InstrumentRecord` row. The registry is
  /// captured weakly so the coordinator-held closure does not retain it
  /// beyond the session's natural lifetime; the `Task { @MainActor }` hop
  /// is required because `notifyExternalChange()` is `@MainActor`-isolated.
  /// No-op when there is no `SyncCoordinator` (test backends, previews).
  private static func wireInstrumentRemoteChangeFanOut(
    registry: CloudKitInstrumentRegistryRepository,
    profileId: UUID,
    syncCoordinator: SyncCoordinator?
  ) {
    syncCoordinator?.setInstrumentRemoteChangeCallback(profileId: profileId) { [weak registry] in
      Task { @MainActor [weak registry] in
        registry?.notifyExternalChange()
      }
    }
  }
}
