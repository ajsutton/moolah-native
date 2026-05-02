// swiftlint:disable multiline_arguments
// Reason: swift-format wraps long initialisers / SwiftUI builders across
// multiple lines in a way the multiline_arguments rule disagrees with.

import CloudKit
import Foundation
import OSLog
import SwiftData
import SwiftUI

// Launch-time container/sync/automation configuration extracted from the main
// `MoolahApp` body so it stays under SwiftLint's `type_body_length` threshold.
// All members are static and referenced from `MoolahApp.init()`.
extension MoolahApp {

  struct ContainerSetup {
    let manager: ProfileContainerManager
    let uiTestingProfileId: UUID?
  }

  /// Returns the `UITestSeed` to hydrate from when the process was launched
  /// with `--ui-testing`, or `nil` for normal launches. An unset or unknown
  /// `UI_TESTING_SEED` is a fatal error so test runs cannot silently fall
  /// back to an unrelated seed when the environment fails to propagate.
  static func uiTestingSeed(from arguments: [String]) -> UITestSeed? {
    guard arguments.contains("--ui-testing") else { return nil }
    guard let raw = ProcessInfo.processInfo.environment["UI_TESTING_SEED"] else {
      fatalError(
        "--ui-testing launched without UI_TESTING_SEED — set the env var via MoolahApp.launch(seed:)."
      )
    }
    guard let seed = UITestSeed(rawValue: raw) else {
      fatalError("Unknown UI test seed '\(raw)' — extend UITestSeed in UITestSupport.")
    }
    return seed
  }

  /// Build the `ProfileContainerManager` — either backed by the user's
  /// on-disk profile index or, under UI testing, by an in-memory one
  /// hydrated from the requested seed.
  static func makeContainerSetup(uiTestingSeed: UITestSeed?) -> ContainerSetup {
    do {
      if let seed = uiTestingSeed {
        // Each `--ui-testing` launch starts from a fresh in-memory
        // `ProfileContainerManager` with a different seed, but
        // `UserDefaults.standard` persists across xctest launches in
        // the same runner. Without resetting the per-record-type
        // SwiftData → GRDB migration flags, the second launch's
        // migrator would skip and the seeded SwiftData rows would
        // never reach GRDB — sidebar / accounts queries return empty
        // and downstream UI assertions time out. Production code
        // paths never enter this branch.
        SwiftDataToGRDBMigrator.resetMigrationFlags()
        let manager = try ProfileContainerManager.forTesting()
        let profile = try UITestSeedHydrator.hydrate(seed, into: manager)
        return ContainerSetup(manager: manager, uiTestingProfileId: profile?.id)
      }

      let profileSchema = Schema([ProfileRecord.self])
      let profileStoreURL = URL.moolahScopedApplicationSupport
        .appending(path: "Moolah-v2.store")
      let profileConfig = ModelConfiguration(
        url: profileStoreURL,
        cloudKitDatabase: .none
      )
      let indexContainer = try ModelContainer(
        for: profileSchema, configurations: [profileConfig])

      let dataSchema = Schema([
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

      let profileIndexURL = URL.moolahScopedApplicationSupport
        .appending(path: "Moolah", directoryHint: .isDirectory)
        .appending(path: "profile-index.sqlite")
      let profileIndexDatabase = try ProfileIndexDatabase.open(at: profileIndexURL)

      let manager = ProfileContainerManager(
        indexContainer: indexContainer,
        profileIndexDatabase: profileIndexDatabase,
        dataSchema: dataSchema
      )
      return ContainerSetup(manager: manager, uiTestingProfileId: nil)
    } catch {
      fatalError("Failed to initialize ModelContainer: \(error)")
    }
  }

  /// Wire the sync coordinator to reload profiles on remote changes only
  /// for production launches. Test contexts must not reach for real iCloud:
  ///   - XCTest: the test binary is signed with the production iCloud
  ///     entitlement, so the coordinator would fetch real records from the
  ///     user's iCloud into on-disk profile stores; those records have bled
  ///     into tests' in-memory containers via SwiftData's shared process
  ///     state and caused intermittent balance failures.
  ///   - --ui-testing: the app is running against in-memory `TestBackend`-
  ///     shaped storage and must not reach for real iCloud. See
  ///     guides/UI_TEST_GUIDE.md §6.
  static func configureSyncCoordinator(
    store: ProfileStore,
    coordinator: SyncCoordinator,
    isUITesting: Bool,
    profileIndexMigrationTask: Task<Void, Never>?
  ) {
    let logger = Logger(subsystem: "com.moolah.app", category: "BackgroundSync")
    let isRunningTests = NSClassFromString("XCTestCase") != nil
    if isUITesting {
      logger.info("Running under --ui-testing — skipping CloudKit sync coordinator")
      return
    }
    if isRunningTests {
      logger.info("Running under XCTest — skipping CloudKit sync coordinator")
      return
    }
    guard CloudKitAuthProvider.isCloudKitAvailable else {
      logger.warning(
        "CloudKit not available — profile sync disabled (NSUbiquitousContainers missing from Info.plist)"
      )
      return
    }
    logger.info("CloudKit available — starting sync coordinator")
    _ = coordinator.addIndexObserver { [weak store] in
      store?.loadCloudProfiles()
    }
    // `GRDBProfileIndexRepository.attachSyncHooks` (wired from
    // `SyncCoordinator.init`) already queues these saves / deletions on
    // every repo mutation. The store-side callbacks below stay as a
    // belt-and-braces transition until a follow-up release deletes
    // them. Double-firing is benign — `queueSave` / `queueDeletion`
    // are idempotent on `(recordType, id, zoneID)`.
    store.onProfileChanged = { [weak coordinator] id in
      let zoneID = CKRecordZone.ID(
        zoneName: "profile-index", ownerName: CKCurrentUserDefaultName)
      coordinator?.queueSave(
        recordType: ProfileRow.recordType, id: id, zoneID: zoneID)
    }
    store.onProfileDeleted = { [weak coordinator] id in
      let zoneID = CKRecordZone.ID(
        zoneName: "profile-index", ownerName: CKCurrentUserDefaultName)
      coordinator?.queueDeletion(
        recordType: ProfileRow.recordType, id: id, zoneID: zoneID)
    }
    // Defer the engine `start()` until the SwiftData → GRDB profile-index
    // migration commits, otherwise CKSyncEngine can deliver fetched
    // profile-data zone changes for a profile id whose `ProfileSession`
    // has not yet been registered (the local index reads zero rows
    // until the migration finishes), which traps in
    // `SyncCoordinator.handlerForProfileZone(profileId:zoneID:)`. The
    // coordinator owns the spawned `launchTask` so `stop()` can cancel
    // it if the app tears down before the migration finishes.
    coordinator.startAfter(profileIndexMigration: profileIndexMigrationTask)
    // Clean up the legacy CloudKit zone from SwiftData's automatic sync.
    LegacyZoneCleanup.performIfNeeded()
  }

  /// Apply any `SyncProgress` mutations required by a UI test seed.
  ///
  /// Called immediately after `SyncCoordinator` is created and before
  /// `configureSyncCoordinator` wires any real CloudKit observers. Under
  /// `--ui-testing` the coordinator is never started, so these mutations
  /// are the only writes that drive the progress state seen by the test.
  ///
  /// Seeds that do not need custom progress state are a no-op.
  static func applySeedProgressFixtures(seed: UITestSeed?, coordinator: SyncCoordinator) {
    guard let seed else { return }
    switch seed {
    case .tradeBaseline,
      .welcomeEmpty,
      .welcomeSingleCloudProfile,
      .welcomeMultipleCloudProfiles,
      .cryptoCatalogPreloaded,
      .tradeReady:
      break
    case .welcomeDownloading:
      // Override iCloudAvailability to `.available` so the WelcomeStateResolver
      // can reach `.heroDownloading`. Without this, `SyncCoordinator.init` sets
      // `.unavailable(.entitlementsMissing)` in the test environment (no real
      // iCloud entitlement), which routes the resolver to `.heroOff` first.
      coordinator.applyICloudAvailability(.available)
      coordinator.progress.beginReceiving()
      coordinator.progress.recordReceived(modifications: 1234, deletions: 0)
    case .sidebarFooterUpToDate:
      // Override iCloudAvailability so the progress calls are not no-ops.
      // `SyncCoordinator.init` sets `.unavailable(.entitlementsMissing)` in
      // test environments (no real iCloud entitlement), which keeps the
      // progress phase as `.degraded` and blocks `beginReceiving` / `endReceiving`.
      coordinator.applyICloudAvailability(.available)
      coordinator.progress.beginReceiving()
      coordinator.progress.endReceiving(now: Date(timeIntervalSinceNow: -300))
    case .sidebarFooterReceiving:
      coordinator.applyICloudAvailability(.available)
      coordinator.progress.beginReceiving()
      coordinator.progress.recordReceived(modifications: 1234, deletions: 0)
    case .sidebarFooterSending:
      coordinator.applyICloudAvailability(.available)
      coordinator.progress.updatePendingUploads(12)
      coordinator.progress.beginReceiving()
      coordinator.progress.endReceiving(now: Date())
    }
  }

  /// Configure the automation service locator. On macOS this also sets up
  /// the AppleScript scripting context.
  static func configureAutomationService(
    store: ProfileStore,
    sessionManager: SessionManager,
    containerManager: ProfileContainerManager,
    coordinator: SyncCoordinator
  ) {
    #if os(macOS)
      let automationService = ScriptingContext.configure(
        sessionManager: sessionManager, profileStore: store,
        containerManager: containerManager, syncCoordinator: coordinator)
      AutomationServiceLocator.shared.service = automationService
    #else
      let automationService = AutomationService(sessionManager: sessionManager)
      AutomationServiceLocator.shared.service = automationService
    #endif
  }

  /// One-shot cleanup: removes the legacy gzipped JSON rate caches that
  /// shipped before rate persistence moved to per-profile SQLite. Gated by
  /// the `v2.rates.cache.cleared` `UserDefaults` flag so it runs at most
  /// once per install. Best-effort — failures are silent and the rate
  /// services repopulate from network on demand.
  ///
  /// `defaults` is injected with a `.standard` default so production callers
  /// pass nothing while tests can supply an isolated suite — satisfies the
  /// `CODE_GUIDE.md` §17 "no direct singleton access" rule without
  /// inventing a wrapper type for a single call site.
  static func cleanupLegacyRateCachesOnce(defaults: UserDefaults = .standard) {
    let key = "v2.rates.cache.cleared"
    guard !defaults.bool(forKey: key) else { return }
    let logger = Logger(subsystem: "com.moolah.app", category: "LegacyCacheCleanup")
    if let caches = FileManager.default
      .urls(for: .cachesDirectory, in: .userDomainMask)
      .first
    {
      let fileManager = FileManager.default
      for sub in ["exchange-rates", "stock-prices", "crypto-prices"] {
        let url = caches.appendingPathComponent(sub)
        do {
          try fileManager.removeItem(at: url)
        } catch let error as NSError
          where error.domain == NSCocoaErrorDomain
          && error.code == NSFileNoSuchFileError
        {
          // Already absent (e.g. fresh install or prior partial cleanup) — fine.
        } catch {
          logger.warning(
            "Failed to delete legacy rate cache \(sub, privacy: .public): \(error.localizedDescription, privacy: .public)"
          )
        }
      }
    }
    defaults.set(true, forKey: key)
  }

  /// Migrates the SwiftData profile index to GRDB once per install.
  /// Logs and swallows errors — a failure leaves the GRDB database
  /// empty and the next launch retries.
  static func runProfileIndexMigrationIfNeeded(
    setup: ContainerSetup,
    defaults: UserDefaults = .standard
  ) async {
    do {
      try await SwiftDataToGRDBMigrator().migrateProfileIndexIfNeeded(
        indexContainer: setup.manager.indexContainer,
        profileIndexDatabase: setup.manager.profileIndexDatabase,
        defaults: defaults)
    } catch {
      Logger(subsystem: "com.moolah.app", category: "Setup")
        .error("ProfileRecord migration failed: \(error, privacy: .public)")
    }
  }
}
