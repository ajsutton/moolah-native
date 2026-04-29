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
  ///
  /// Module-internal so `ProfileSession+DatabaseMaintenance.swift` can
  /// invoke `database.write` for `PRAGMA optimize`. External consumers
  /// must still go through repositories and the rate services rather than
  /// poking the queue directly.
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
  /// Background task handle for the once-per-session CoinGecko
  /// `refreshIfStale()` kick-off. Tracked so it can be cancelled in
  /// `cleanupSync(coordinator:)` if the session is torn down before the
  /// refresh completes.
  private var catalogRefreshTask: Task<Void, Never>?
  /// Background task handle for the most recent `PRAGMA optimize` kick-off.
  /// Tracked so we can cancel any pending optimize on session teardown
  /// (per `guides/CONCURRENCY_GUIDE.md` §8 — fire-and-forget tasks must
  /// be tracked). Replaced (with cancellation of the prior handle) on
  /// each call to `schedulePragmaOptimize()`. Module-internal so
  /// `ProfileSession+DatabaseMaintenance.swift` can manage the handle.
  var pragmaOptimizeTask: Task<Void, Never>?
  /// Long-lived task that fires `runPragmaOptimize` at most once per
  /// configured interval while the session is active. Cancelled in
  /// `cleanupSync(coordinator:)` so it cannot outlive the session.
  /// Replaced (with cancellation of the prior handle) on each call to
  /// `startPeriodicPragmaOptimize(interval:)` so a new cadence supersedes
  /// the previous one rather than running alongside it. Module-internal
  /// for the same reason as `pragmaOptimizeTask`.
  var periodicPragmaOptimizeTask: Task<Void, Never>?
  /// Number of times `runPragmaOptimize` has completed for this session.
  /// Incremented after each invocation regardless of success — failures
  /// are still attempts, and the counter is consumed by tests that pin
  /// the hourly-while-active cadence (see issue #576). Module-internal
  /// because `runPragmaOptimize` lives in
  /// `ProfileSession+DatabaseMaintenance.swift`; mutated only there.
  var pragmaOptimizeRunCount: Int = 0
  /// Tasks spawned by the investment-store → account-store bridge, kept
  /// reachable so `cleanupSync` can cancel in-flight balance updates
  /// (per `guides/CONCURRENCY_GUIDE.md` §8).
  private var crossStoreUpdateTasks: [Task<Void, Never>] = []

  /// Stashed reference to the container manager so `setUp()` can open the
  /// per-profile SwiftData container and run the SwiftData → GRDB
  /// migration after init returns. `nil` for tests / previews that pass
  /// `containerManager: nil` (those have nothing to migrate from).
  private let containerManagerForMigration: ProfileContainerManager?

  /// Tracks the in-flight (or completed) `setUp()` call so callers can
  /// `await session.setUp()` without re-running the migration. Set by
  /// `setUp()` on its first invocation; subsequent calls return the
  /// same task. `nil` until the first call. Tracked here (rather than
  /// in `SessionManager`) so any caller with the session reference can
  /// await migration completion.
  private var setUpTask: Task<Void, any Error>?

  /// Synchronous initialiser — opens the per-profile GRDB queue and
  /// builds every store / service the session exposes. Does **not** run
  /// the SwiftData → GRDB migration; that lives in `setUp()` so the
  /// GRDB writes happen off `@MainActor` (issue #575). Callers must
  /// invoke `try await session.setUp()` before any code path expects
  /// the migrated rows to be visible — `SessionManager.session(for:)`
  /// schedules this automatically when it creates the session.
  init(
    profile: Profile,
    containerManager: ProfileContainerManager? = nil,
    syncCoordinator: SyncCoordinator? = nil,
    database: DatabaseQueue? = nil
  ) throws {
    self.profile = profile
    self.containerManagerForMigration = containerManager

    let resolvedDatabase = try Self.resolveDatabase(
      override: database, profile: profile, containerManager: containerManager)
    self.database = resolvedDatabase

    let services = Self.makeMarketDataServices(database: resolvedDatabase)
    self.exchangeRateService = services.exchangeRate
    self.stockPriceService = services.stockPrice
    self.cryptoPriceService = services.cryptoPrice

    let backend = Self.makeBackend(
      profile: profile,
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
    self.catalogRefreshTask = registryWiring.catalogRefreshTask
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

    finishInit(syncCoordinator: syncCoordinator)
  }

  /// Tail of the initialiser — kept as a separate method so `init`
  /// stays under SwiftLint's `function_body_length` threshold. Wires
  /// cross-store side effects, registers with the sync coordinator,
  /// and starts the hourly `PRAGMA optimize` tick (issue #576).
  private func finishInit(syncCoordinator: SyncCoordinator?) {
    wireCrossStoreSideEffects()
    registerWithSyncCoordinator(syncCoordinator)
    startPeriodicPragmaOptimize()
  }

  /// Wires the investment-store -> account-store callback. The spawned
  /// Task is appended to `crossStoreUpdateTasks` so `cleanupSync` can
  /// cancel in-flight updates if the session is torn down.
  private func wireCrossStoreSideEffects() {
    let accountStore = self.accountStore
    self.investmentStore.onInvestmentValueChanged = { [weak self] accountId, latestValue in
      let task = Task { @MainActor in
        await accountStore.updateInvestmentValue(accountId: accountId, value: latestValue)
      }
      self?.crossStoreUpdateTasks.append(task)
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
    logger.info("Registering profile \(profileId) with sync coordinator")
    self.syncObserverToken = coordinator.addObserver(for: profileId) { [weak self] changedTypes in
      self?.scheduleReloadFromSync(changedTypes: changedTypes)
    }
    wireRepositorySync(coordinator: coordinator)
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
    coordinator.removeProfileGRDBRepositories(profileId: profile.id)
    syncReloadTask?.cancel()
    syncReloadTask = nil
    catalogRefreshTask?.cancel()
    catalogRefreshTask = nil
    pragmaOptimizeTask?.cancel()
    pragmaOptimizeTask = nil
    periodicPragmaOptimizeTask?.cancel()
    periodicPragmaOptimizeTask = nil
    for task in crossStoreUpdateTasks {
      task.cancel()
    }
    crossStoreUpdateTasks.removeAll()
    setUpTask?.cancel()
    setUpTask = nil
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

  /// Drives the one-shot SwiftData → GRDB migration for the given
  /// profile's SwiftData container and GRDB queue. Skipped when no
  /// `containerManager` is supplied (tests / previews build a fresh
  /// in-memory GRDB queue and have nothing to migrate from).
  ///
  /// MUST run before stores read from `data.sqlite` so CKSyncEngine
  /// and the GRDB repositories read a fully populated database on
  /// first launch.
  ///
  /// `async throws` so each per-type migrator can hand off the heavy
  /// GRDB upserts to GRDB's writer queue via `await database.write`
  /// rather than holding `@MainActor` for the duration (issue #575).
  /// The bounded SwiftData fetches stay on `@MainActor` because that's
  /// where the SwiftData `mainContext` requires them.
  static func runSwiftDataToGRDBMigrationIfNeeded(
    profileId: UUID,
    containerManager: ProfileContainerManager?,
    database: DatabaseQueue
  ) async throws {
    guard let containerManager else { return }
    let modelContainer = try containerManager.container(for: profileId)
    try await SwiftDataToGRDBMigrator().migrateIfNeeded(
      modelContainer: modelContainer, database: database)
  }

  /// Runs the SwiftData → GRDB migration off `@MainActor` and reloads
  /// the affected stores. Idempotent: subsequent calls return the same
  /// task so callers can `await session.setUp()` from multiple sites
  /// (UI test seed setup, `SessionManager.session(for:)`, etc.) without
  /// re-running the migration.
  ///
  /// Throws whatever the migrator throws — the caller (typically
  /// `SessionManager`) is responsible for surfacing the error to the
  /// user. A failed setUp leaves the migration's `UserDefaults` flags
  /// unset, so the next launch retries.
  func setUp() async throws {
    if let existing = setUpTask {
      return try await existing.value
    }
    let profileId = profile.id
    let containerManager = containerManagerForMigration
    let database = database
    let task = Task<Void, any Error> {
      try await Self.runSwiftDataToGRDBMigrationIfNeeded(
        profileId: profileId,
        containerManager: containerManager,
        database: database)
    }
    setUpTask = task
    try await task.value
  }

}
