import CloudKit
import Foundation
import GRDB
import OSLog
import SwiftData

/// Holds the backend and all stores for a single profile.
/// Each profile gets its own isolated URLSession, cookie storage, and keychain entry.
@Observable
@MainActor
final class ProfileSession: Identifiable {
  let profile: Profile
  /// Per-profile GRDB connection. Owns the lifecycle of `data.sqlite`
  /// (or an in-memory queue under previews / tests). Released when the
  /// session deinits; on profile delete the parent `profiles/<id>/`
  /// directory is removed by `ProfileContainerManager.deleteStore`.
  let database: DatabaseQueue
  let backend: BackendProvider
  let authStore: AuthStore
  let accountStore: AccountStore
  let transactionStore: TransactionStore
  let categoryStore: CategoryStore
  let earmarkStore: EarmarkStore
  let analysisStore: AnalysisStore
  let investmentStore: InvestmentStore
  let reportingStore: ReportingStore
  let exchangeRateService: ExchangeRateService
  let stockPriceService: StockPriceService
  let cryptoPriceService: CryptoPriceService
  let instrumentRegistry: (any InstrumentRegistryRepository)?
  let cryptoTokenStore: CryptoTokenStore?
  let instrumentSearchService: InstrumentSearchService?
  let coinGeckoCatalog: (any CoinGeckoCatalog)?
  let tokenResolutionClient: (any TokenResolutionClient)?
  let importStore: ImportStore
  let importRuleStore: ImportRuleStore
  let importPreferences: ImportPreferences
  private let folderScanner: FolderScanService
  private let folderWatcher: FolderWatchService

  /// Non-nil while a profile export is in progress. Set by the File menu's
  /// export command; read by `SessionRootView` to present a progress sheet
  /// (see issue #359). `nil` when idle so the sheet dismisses automatically.
  var activeExport: ActiveExport?

  /// Observer token for sync coordinator notifications.
  private var syncObserverToken: SyncCoordinator.ObserverToken?

  nonisolated var id: UUID { profile.id }

  private let logger = Logger(subsystem: "com.moolah.app", category: "ProfileSession")
  private var syncReloadTask: Task<Void, Never>?
  private var pendingChangedTypes = Set<String>()
  private var lastSyncEventTime: ContinuousClock.Instant?

  init(
    profile: Profile,
    containerManager: ProfileContainerManager? = nil,
    syncCoordinator: SyncCoordinator? = nil,
    database: DatabaseQueue? = nil
  ) throws {
    self.profile = profile

    let resolvedDatabase = try Self.resolveDatabase(
      override: database, profile: profile, containerManager: containerManager)
    self.database = resolvedDatabase

    let services = Self.makeMarketDataServices(database: resolvedDatabase)
    self.exchangeRateService = services.exchangeRate
    self.stockPriceService = services.stockPrice
    self.cryptoPriceService = services.cryptoPrice

    let backend = Self.makeBackend(
      profile: profile,
      containerManager: containerManager,
      syncCoordinator: syncCoordinator,
      services: services,
      database: resolvedDatabase
    )
    self.backend = backend

    let registryWiring = Self.makeRegistryWiring(
      backend: backend,
      cryptoPriceService: services.cryptoPrice,
      yahooPriceFetcher: services.yahooPriceFetcher,
      coinGeckoApiKey: services.coinGeckoApiKey
    )
    self.instrumentRegistry = registryWiring.registry
    self.cryptoTokenStore = registryWiring.cryptoTokenStore
    self.instrumentSearchService = registryWiring.searchService
    self.coinGeckoCatalog = registryWiring.coinGeckoCatalog
    self.tokenResolutionClient = registryWiring.tokenResolutionClient
    let stores = Self.makeDomainStores(profile: profile, backend: backend)
    self.authStore = stores.auth
    self.accountStore = stores.account
    self.categoryStore = stores.category
    self.earmarkStore = stores.earmark
    self.transactionStore = stores.transaction
    self.analysisStore = stores.analysis
    self.investmentStore = stores.investment
    self.reportingStore = stores.reporting

    // CSV import: ImportStore owns the pipeline orchestration; the staging
    // store lives per-profile on disk so pending/failed files follow the
    // profile across app restarts.
    let importPipeline = Self.makeImportPipeline(
      backend: backend, profileId: profile.id, logger: logger)
    self.importStore = importPipeline.importStore
    self.importRuleStore = importPipeline.importRuleStore
    self.importPreferences = importPipeline.preferences
    self.folderScanner = importPipeline.scanner
    self.folderWatcher = importPipeline.watcher

    wireCrossStoreSideEffects()
    registerWithSyncCoordinator(syncCoordinator)
  }

  /// Wires the investment-store -> account-store callback so the sidebar
  /// total updates when a position revalues. The callback is fire-and-forget
  /// in production; `updateInvestmentValue` awaits its own first conversion
  /// pass, so the sidebar reflects the new value once the Task completes
  /// on MainActor.
  private func wireCrossStoreSideEffects() {
    let accountStore = self.accountStore
    self.investmentStore.onInvestmentValueChanged = { accountId, latestValue in
      Task {
        await accountStore.updateInvestmentValue(accountId: accountId, value: latestValue)
      }
    }
  }

  /// Registers the session with the `SyncCoordinator`:
  /// installs the per-profile reload observer and wires the repository
  /// sync callbacks for the profile's zone. Logs a warning when the
  /// coordinator is unavailable.
  private func registerWithSyncCoordinator(_ coordinator: SyncCoordinator?) {
    let profileId = profile.id
    guard let coordinator else {
      logger.warning("CloudKit not available — profile sync disabled for \(profileId)")
      return
    }
    let zoneID = CKRecordZone.ID(
      zoneName: "profile-\(profileId.uuidString)",
      ownerName: CKCurrentUserDefaultName)
    logger.info("Registering profile \(profileId) with sync coordinator")
    self.syncObserverToken = coordinator.addObserver(for: profileId) { [weak self] changedTypes in
      self?.scheduleReloadFromSync(changedTypes: changedTypes)
    }
    wireRepositorySync(coordinator: coordinator, zoneID: zoneID)
  }

  // MARK: - CloudKit Sync

  /// Debounces sync reloads — cancels any pending reload and waits briefly.
  /// This avoids redundant reloads when CKSyncEngine delivers multiple change batches
  /// in quick succession. Only reloads stores affected by the changed record types.
  /// During bulk sync (rapid consecutive batches), the debounce increases to 2s to
  /// avoid thrashing.
  private func scheduleReloadFromSync(changedTypes: Set<String>) {
    pendingChangedTypes.formUnion(changedTypes)

    let now = ContinuousClock.now
    let isBulkSync: Bool
    if let last = lastSyncEventTime, now - last < .seconds(1) {
      isBulkSync = true
    } else {
      isBulkSync = false
    }
    lastSyncEventTime = now
    let debounceMs = isBulkSync ? 2000 : 500

    syncReloadTask?.cancel()
    syncReloadTask = Task {
      try? await Task.sleep(for: .milliseconds(debounceMs))
      guard !Task.isCancelled else { return }

      let types = self.pendingChangedTypes
      self.pendingChangedTypes.removeAll()

      let reloadStart = ContinuousClock.now
      logger.debug("Reloading stores after CloudKit sync: \(types)")
      let plan = Self.storesToReload(for: types)
      if plan.contains(.accounts) {
        await accountStore.reloadFromSync()
      }
      if plan.contains(.categories) {
        await categoryStore.reloadFromSync()
      }
      if plan.contains(.earmarks) {
        await earmarkStore.reloadFromSync()
      }
      if plan.contains(.importRules) {
        await importRuleStore.reloadFromSync()
      }
      let reloadMs = (ContinuousClock.now - reloadStart).inMilliseconds
      logger.info("📊 Store reloads after sync completed in \(reloadMs)ms for types: \(types)")
    }
  }

  // MARK: - Sync Cleanup

  /// Removes the sync observer from the coordinator. Call when the session is being torn down.
  func cleanupSync(coordinator: SyncCoordinator) {
    if let token = syncObserverToken {
      coordinator.removeObserver(token: token)
      syncObserverToken = nil
    }
    coordinator.removeInstrumentRemoteChangeCallback(profileId: profile.id)
    syncReloadTask?.cancel()
    syncReloadTask = nil
  }

  // MARK: - Folder watch

  /// Kick off the folder watch: catches up on any files added while the app
  /// was closed and (on macOS) opens an FSEvents stream for live updates.
  /// Safe to call repeatedly; stop() must be paired with start() for state
  /// hygiene.
  func startFolderWatch() async {
    await folderWatcher.start()
  }

  /// Stop the folder watch and release the security-scoped resource.
  func stopFolderWatch() {
    folderWatcher.stop()
  }

  /// Catch-up scan — used at launch / foreground on iOS where the live
  /// watch isn't available.
  func scanWatchedFolder() async {
    await folderScanner.scanForNewFiles()
  }

  /// Per-profile directory under Application Support where CSV import staging
  /// lives. Not part of the SwiftData store because staging is device-local
  /// and doesn't sync.
  nonisolated static func importStagingDirectory(for profileId: UUID) -> URL {
    URL.moolahScopedApplicationSupport
      .appendingPathComponent("Moolah", isDirectory: true)
      .appendingPathComponent("csv-staging", isDirectory: true)
      .appendingPathComponent(profileId.uuidString, isDirectory: true)
  }

  /// Per-profile directory containing `data.sqlite` (and its `-wal`/`-shm`
  /// sidecars). Removed wholesale on profile delete by
  /// `ProfileContainerManager.deleteStore(for:)`.
  nonisolated static func profileDatabaseDirectory(for profileId: UUID) -> URL {
    URL.moolahScopedApplicationSupport
      .appendingPathComponent("Moolah", isDirectory: true)
      .appendingPathComponent("profiles", isDirectory: true)
      .appendingPathComponent(profileId.uuidString, isDirectory: true)
  }

  /// Opens the profile's `data.sqlite` GRDB queue, creating intermediate
  /// directories as needed and applying the `ProfileSchema` migrator.
  nonisolated static func openProfileDatabase(profileId: UUID) throws -> DatabaseQueue {
    let url = profileDatabaseDirectory(for: profileId)
      .appendingPathComponent("data.sqlite")
    return try ProfileDatabase.open(at: url)
  }

  /// Resolves which `DatabaseQueue` the session should own. Order:
  ///   1. Caller-provided `override` (tests, previews).
  ///   2. In-memory queue when the parent `containerManager` is in-memory
  ///      (UI testing, `ProfileContainerManager.forTesting()`).
  ///   3. On-disk `data.sqlite` under `profiles/<id>/` for production.
  nonisolated private static func resolveDatabase(
    override: DatabaseQueue?,
    profile: Profile,
    containerManager: ProfileContainerManager?
  ) throws -> DatabaseQueue {
    if let override { return override }
    if containerManager?.inMemory == true { return try ProfileDatabase.openInMemory() }
    return try openProfileDatabase(profileId: profile.id)
  }

  /// Convenience constructor for `#Preview` blocks. Backs the session with
  /// an in-memory GRDB queue so previews never touch disk. Uses an in-memory
  /// `ProfileContainerManager` so the CloudKit backend can be constructed
  /// without touching the network or the on-disk container store.
  static func preview(
    profile: Profile = Profile(label: "Preview")
  ) throws -> ProfileSession {
    try ProfileSession(
      profile: profile,
      containerManager: ProfileContainerManager.forTesting(),
      database: ProfileDatabase.openInMemory())
  }
}
