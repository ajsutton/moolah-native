// swiftlint:disable multiline_arguments

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
        let manager = try ProfileContainerManager.forTesting()
        let profile = try UITestSeedHydrator.hydrate(seed, into: manager)
        return ContainerSetup(manager: manager, uiTestingProfileId: profile.id)
      }

      let profileSchema = Schema([ProfileRecord.self])
      let profileStoreURL = URL.applicationSupportDirectory.appending(path: "Moolah-v2.store")
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

      let manager = ProfileContainerManager(
        indexContainer: indexContainer,
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
    store: ProfileStore, coordinator: SyncCoordinator, uiTestingProfileId: UUID?
  ) {
    let logger = Logger(subsystem: "com.moolah.app", category: "BackgroundSync")
    let isRunningTests = NSClassFromString("XCTestCase") != nil
    let isUITesting = uiTestingProfileId != nil
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
    store.onProfileChanged = { [weak coordinator] id in
      let zoneID = CKRecordZone.ID(
        zoneName: "profile-index", ownerName: CKCurrentUserDefaultName)
      coordinator?.queueSave(
        recordType: ProfileRecord.recordType, id: id, zoneID: zoneID)
    }
    store.onProfileDeleted = { [weak coordinator] id in
      let zoneID = CKRecordZone.ID(
        zoneName: "profile-index", ownerName: CKCurrentUserDefaultName)
      coordinator?.queueDeletion(
        recordType: ProfileRecord.recordType, id: id, zoneID: zoneID)
    }
    coordinator.start()
    // Clean up the legacy CloudKit zone from SwiftData's automatic sync.
    LegacyZoneCleanup.performIfNeeded()
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
}
