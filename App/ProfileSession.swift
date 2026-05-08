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
  var profile: Profile
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
  /// Orchestrator for crypto-wallet auto-import. `nil` when the profile
  /// has no `instrumentRegistry` (preview / degraded launches). Set
  /// once in `finishInit` after `init` returns; effectively `let` from
  /// the consumer's perspective. `private(set)` so callers cannot
  /// reassign.
  private(set) var cryptoSyncStore: CryptoSyncStore?

  /// Token resolver shared with the inbox UI. Nil with `cryptoSyncStore`.
  /// Same lifecycle pattern as `cryptoSyncStore`.
  private(set) var cryptoTokenDiscovery: CryptoTokenDiscoveryService?
  let importStore: ImportStore
  let importRuleStore: ImportRuleStore
  let importPreferences: ImportPreferences
  private let folderScanner: FolderScanService
  private let folderWatcher: FolderWatchService

  /// Non-nil while a profile export is in progress. Set by the File menu's
  /// export command; read by `SessionRootView` to present a progress sheet
  /// (see issue #359). `nil` when idle so the sheet dismisses automatically.
  var activeExport: ActiveExport?

  /// Stable profile identity captured at init time so the nonisolated
  /// `id` accessor (used by `Identifiable` conformance / SwiftUI diffing)
  /// does not have to read the main-actor-isolated `profile` property.
  /// `updateProfile(_:)` preconditions on `updated.id == profile.id`,
  /// so this stays in lockstep with `profile.id` for the session's
  /// lifetime.
  nonisolated private let profileID: UUID

  nonisolated var id: UUID { profileID }

  /// Module-internal so `ProfileSession+SyncCleanup.swift` and
  /// `ProfileSession+DatabaseMaintenance.swift` can log without needing
  /// their own Logger instances.
  let logger = Logger(subsystem: "com.moolah.app", category: "ProfileSession")
  /// Background task handle for the once-per-session CoinGecko
  /// `refreshIfStale()` kick-off. Tracked so it can be cancelled in
  /// `cleanupSync(coordinator:)` if the session is torn down before the
  /// refresh completes. Module-internal for the sync-cleanup extension.
  var catalogRefreshTask: Task<Void, Never>?
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
  /// Tasks spawned by cross-store side effects (e.g.
  /// `seedBuiltInCryptoPresets`, the `cryptoTokenStore` ->
  /// `investmentStore.revaluateLoadedPositions` callback). Kept
  /// reachable so `cleanupSync` can cancel in-flight work (per
  /// `guides/CONCURRENCY_GUIDE.md` §8). Module-internal so
  /// `ProfileSession+SyncCleanup.swift` can drain the list on teardown.
  var crossStoreUpdateTasks: [Task<Void, Never>] = []

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
  /// await migration completion. Module-internal so
  /// `ProfileSession+SyncCleanup.swift` can cancel a pending bootstrap
  /// during teardown.
  var setUpTask: Task<Void, any Error>?

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
    self.profileID = profile.id
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

    finishInit(
      cryptoRegistry: registryWiring.registry,
      cryptoPriceService: services.cryptoPrice)
  }

  /// Tail of the initialiser — kept as a separate method so `init`
  /// stays under SwiftLint's `function_body_length` threshold. Wires
  /// the crypto-wallet sync stores and starts the hourly
  /// `PRAGMA optimize` tick (issue #576).
  ///
  /// Cross-store propagation is handled reactively: every store
  /// subscribes to its repository's GRDB `ValueObservation` stream in
  /// `init`, so remote-sync writes (and local writes) reach views
  /// without an explicit reload step. The session no longer needs a
  /// reference to `SyncCoordinator` here — apply still drives GRDB
  /// writes and the observation streams take it from there.
  private func finishInit(
    cryptoRegistry: (any InstrumentRegistryRepository)?,
    cryptoPriceService: CryptoPriceService
  ) {
    let cryptoWiring = Self.makeCryptoSyncWiring(
      backend: backend,
      registry: cryptoRegistry,
      cryptoPriceService: cryptoPriceService)
    self.cryptoSyncStore = cryptoWiring?.store
    self.cryptoTokenDiscovery = cryptoWiring?.discovery
    seedBuiltInCryptoPresets(registry: cryptoRegistry)
    wireCrossStoreSideEffects()
    startPeriodicPragmaOptimize()
  }

  /// Fires `registerBuiltInPresetsIfMissing` on the profile's registry
  /// so chain native gas tokens (ETH on Ethereum / OP / Base; MATIC on
  /// Polygon) and well-known ERC-20s carry a real provider mapping
  /// before any conversion path consults the registry. Without this,
  /// transaction detail / running-balance render fails for crypto legs
  /// the very first time a profile reads them — issue #791. Tracked in
  /// `crossStoreUpdateTasks` so `cleanupSync` cancels in-flight seeds
  /// when the session tears down.
  private func seedBuiltInCryptoPresets(
    registry: (any InstrumentRegistryRepository)?
  ) {
    guard let registry else { return }
    let task = Task {
      await registry.registerBuiltInPresetsIfMissing()
    }
    crossStoreUpdateTasks.append(task)
  }

  /// Wires the crypto-token-store -> investment-store hook: when a
  /// registration's `pricingStatus` flips (e.g. user marks a token as
  /// `.spam` from preferences), the loaded investment account
  /// re-valuates so the spam position drops out of `valuedPositions`
  /// without the user having to navigate away and back. Issue #790.
  ///
  /// The investment-store -> account-store fan-out (formerly
  /// `onInvestmentValueChanged`) was removed when AccountStore
  /// migrated to reactive observation: AccountStore now subscribes to
  /// `investmentRepository.observeAllValues()` and refreshes its cache
  /// directly, so a write to `investment_value` reaches the sidebar
  /// without a callback. The spawned crypto-token Task is tracked in
  /// `crossStoreUpdateTasks` so `cleanupSync` can cancel in-flight
  /// revaluations on session teardown.
  private func wireCrossStoreSideEffects() {
    let investmentStore = self.investmentStore
    self.cryptoTokenStore?.onRegistrationsChanged = { [weak self] in
      let task = Task { @MainActor in
        await investmentStore.revaluateLoadedPositions()
      }
      self?.crossStoreUpdateTasks.append(task)
    }
  }

  // `cleanupSync(coordinator:)` and `updateProfile(_:)` live in
  // `ProfileSession+SyncCleanup.swift`.

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

  /// Runs the bootstrap migrations off `@MainActor` and reloads the
  /// affected stores. Idempotent: subsequent calls return the same
  /// task so callers can `await session.setUp()` from multiple sites
  /// (UI test seed setup, `SessionManager.session(for:)`, etc.) without
  /// re-running anything.
  ///
  /// Phase 1 — SwiftData → GRDB migration.
  /// Throws whatever the migrator throws (the caller, typically
  /// `SessionManager`, surfaces the error to the user). A throw leaves
  /// the migration's `UserDefaults` flags unset so the next launch
  /// retries.
  ///
  /// Phase 2 — `ValuationModeMigration`.
  /// Runs after Phase 1 commits so the GRDB-backed repositories see
  /// every account / `InvestmentValue` row. Non-fatal: errors are
  /// logged but do not propagate, because read sites still auto-detect
  /// at this rollout stage and the next launch will retry. Both phases
  /// share the same `setUpTask` so the per-session idempotency guard
  /// covers the whole bootstrap, not just Phase 1.
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
      await self.runValuationModeMigration()
    }
    setUpTask = task
    try await task.value
  }

  // `runValuationModeMigration` lives in
  // `ProfileSession+ValuationMigration.swift` so this file stays under
  // SwiftLint's `file_length` threshold.
}
