import CloudKit
import OSLog
import SwiftData
import SwiftUI

@main
@MainActor
struct MoolahApp: App {
  @Environment(\.scenePhase) private var scenePhase
  private let containerManager: ProfileContainerManager
  private let syncCoordinator: SyncCoordinator
  /// The seeded profile ID under `--ui-testing`, or `nil` for production
  /// launches. Stored as `let` because `MoolahApp.init` runs once per
  /// process; the value is decided at launch and never changes.
  private let uiTestingProfileId: UUID?
  @State private var profileStore: ProfileStore
  private let logger = Logger(subsystem: "com.moolah.app", category: "BackgroundSync")

  #if os(macOS)
    @NSApplicationDelegateAdaptor(ScriptingBridge.self) var scriptingBridge
    private let backupManager: StoreBackupManager
    @State private var sessionManager: SessionManager
  #else
    @State private var activeSession: ProfileSession?
    @State private var sessionManager: SessionManager
  #endif

  init() {
    // UI-testing launch mode: swap the on-disk profile index for an
    // in-memory one and hydrate it from UI_TESTING_SEED. CloudKit sync and
    // telemetry are skipped entirely — the app runs against `TestBackend`
    // shaped storage (in-memory `CloudKitBackend`) so XCUITest flows never
    // touch the user's iCloud. See guides/UI_TEST_GUIDE.md §6.
    let (manager, uiTestingProfileId) = Self.makeContainerManager(
      arguments: CommandLine.arguments
    )
    containerManager = manager
    syncCoordinator = SyncCoordinator(containerManager: manager)
    self.uiTestingProfileId = uiTestingProfileId

    let store = ProfileStore(validator: RemoteServerValidator(), containerManager: containerManager)
    _profileStore = State(initialValue: store)

    let sessionManager = SessionManager(
      containerManager: containerManager,
      syncCoordinator: syncCoordinator
    )
    _sessionManager = State(initialValue: sessionManager)

    #if os(macOS)
      backupManager = StoreBackupManager()
    #endif

    Self.configureSyncCoordinator(
      store: store,
      coordinator: syncCoordinator,
      isUITesting: uiTestingProfileId != nil,
      logger: logger
    )

    // Clean up cached sessions when a profile is removed (locally or via remote sync).
    store.onProfileRemoved = { [weak sessionManager] profileID in
      sessionManager?.removeSession(for: profileID)
    }

    Self.configureAutomation(
      sessionManager: sessionManager,
      store: store,
      containerManager: containerManager,
      syncCoordinator: syncCoordinator
    )
  }

  var body: some Scene {
    #if os(macOS)
      WindowGroup(for: Profile.ID.self) { $profileID in
        // UI-testing mode pins the window to the seeded profile; the
        // per-window binding is used only in production launches.
        ProfileWindowView(profileID: uiTestingProfileId ?? profileID)
          .environment(profileStore)
          .environment(sessionManager)
          .environment(containerManager)
          .environment(syncCoordinator)
          .onOpenURL { url in handleURL(url) }
          .task {
            // Daily backup runs in production launches only; under UI
            // testing the fixture container is ephemeral, so there is
            // nothing meaningful to back up.
            guard uiTestingProfileId == nil else { return }
            backupManager.performDailyBackup(
              profiles: profileStore.profiles,
              containerManager: containerManager
            )
            Timer.scheduledTimer(withTimeInterval: 86400, repeats: true) { _ in
              Task { @MainActor in
                backupManager.performDailyBackup(
                  profiles: profileStore.profiles,
                  containerManager: containerManager
                )
              }
            }
          }
      }
      .modelContainer(containerManager.indexContainer)
      .onChange(of: scenePhase) { _, newPhase in
        handleScenePhaseChange(newPhase)
      }
      .commands {
        AboutCommands()
        ProfileCommands(
          profileStore: profileStore,
          sessionManager: sessionManager,
          containerManager: containerManager,
          syncCoordinator: syncCoordinator
        )
        NewItemCommands()
        ImportCSVCommands()
        RefreshCommands()
        SidebarCommands()
        ToolbarCommands()
        InspectorCommands()
        ShowHiddenCommands()
        MoolahDomainCommands()
      }

      Window("About Moolah", id: "about") {
        AboutView()
      }
      .windowResizability(.contentSize)
      .windowStyle(.hiddenTitleBar)

      Window("Keyboard Shortcuts", id: "keyboard-shortcuts") {
        KeyboardShortcutsView()
      }
      .windowResizability(.contentSize)

      Settings {
        SettingsView()
          .environment(profileStore)
          .environment(sessionManager)
          .environment(containerManager)
          .environment(syncCoordinator)
          .modelContainer(containerManager.indexContainer)
      }

      // Auto-open the seeded profile window on `--ui-testing` launches.
      // `WindowGroup(for: Profile.ID.self)` does not present without an
      // explicit value, so a hidden launcher Window with
      // `.defaultLaunchBehavior(.presented)` runs `openWindow(value:)`
      // and immediately dismisses itself. In production the launcher is
      // suppressed and never reachable from the UI.
      Window("UI Testing Launcher", id: "ui-testing-launcher") {
        UITestingLauncherView(profileId: uiTestingProfileId)
      }
      .windowResizability(.contentSize)
      .defaultLaunchBehavior(uiTestingProfileId != nil ? .presented : .suppressed)
    #else
      WindowGroup {
        ProfileRootView(activeSession: $activeSession)
          .environment(profileStore)
          .environment(sessionManager)
          .environment(containerManager)
          .environment(syncCoordinator)
          .onOpenURL { url in handleURL(url) }
      }
      .modelContainer(containerManager.indexContainer)
      .onChange(of: scenePhase) { _, newPhase in
        handleScenePhaseChange(newPhase)
      }
      .commands {
        NewItemCommands()
        RefreshCommands()
        ShowHiddenCommands()
      }
    #endif
  }

  // MARK: - Background Sync

  private func handleScenePhaseChange(_ newPhase: ScenePhase) {
    switch newPhase {
    case .background:
      flushPendingChanges()
    case .active:
      Task { await fetchRemoteChanges() }
    default:
      break
    }
  }

  private func flushPendingChanges() {
    guard syncCoordinator.hasPendingChanges else {
      logger.debug("No pending changes to flush on background entry")
      return
    }

    logger.info("Flushing pending sync changes on background entry")

    #if os(iOS)
      // Request extra background time on iOS to complete uploads.
      // On macOS the app process stays alive, so no special handling is needed.
      ProcessInfo.processInfo.performExpiringActivity(
        withReason: "Uploading pending sync changes"
      ) { expired in
        guard !expired else { return }
        Task { @MainActor in
          await self.syncCoordinator.sendChanges()
        }
      }
    #else
      Task {
        await syncCoordinator.sendChanges()
      }
    #endif
  }

  private func fetchRemoteChanges() async {
    logger.info("Fetching remote changes on foreground entry")
    await syncCoordinator.fetchChanges()
  }

  // MARK: - URL Handling

  /// CSV files opened via Finder "Open With Moolah" or dropped on the Dock
  /// icon arrive here as `file://` URLs. Post a notification — the active
  /// profile's `ContentView` is subscribed and will route it through
  /// `ImportStore.ingest` (matcher auto-routes, unknown files land in
  /// Needs Setup) exactly like a drag-and-drop.
  private func handleURL(_ url: URL) {
    guard url.isFileURL, url.pathExtension.lowercased() == "csv" else { return }
    NotificationCenter.default.post(name: .openCSVFile, object: url)
  }
}

// MARK: - Init Helpers

extension MoolahApp {
  /// Returns the `UITestSeed` to hydrate from when the process was launched
  /// with `--ui-testing`, or `nil` for normal launches. An unset or unknown
  /// `UI_TESTING_SEED` is a fatal error so test runs cannot silently fall
  /// back to an unrelated seed when the environment fails to propagate.
  private static func uiTestingSeed(from arguments: [String]) -> UITestSeed? {
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

  /// Builds the profile container manager. Under `--ui-testing` the index is
  /// swapped for an in-memory hydrator-seeded container; otherwise the
  /// production on-disk SwiftData configuration is used.
  private static func makeContainerManager(
    arguments: [String]
  ) -> (manager: ProfileContainerManager, uiTestingProfileId: UUID?) {
    do {
      if let seed = uiTestingSeed(from: arguments) {
        let manager = try ProfileContainerManager.forTesting()
        let profile = try UITestSeedHydrator.hydrate(seed, into: manager)
        return (manager, profile.id)
      }
      let profileSchema = Schema([ProfileRecord.self])
      let profileStoreURL = URL.applicationSupportDirectory.appending(path: "Moolah-v2.store")
      let profileConfig = ModelConfiguration(url: profileStoreURL, cloudKitDatabase: .none)
      let indexContainer = try ModelContainer(
        for: profileSchema,
        configurations: [profileConfig]
      )
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
      return (manager, nil)
    } catch {
      fatalError("Failed to initialize ModelContainer: \(error)")
    }
  }

  /// Starts the sync coordinator for production launches and wires observers
  /// that reload profiles on remote changes. In test or `--ui-testing`
  /// contexts, logs why the coordinator is skipped and returns. Test contexts
  /// must not reach for real iCloud:
  ///   - XCTest: the test binary is signed with the production iCloud
  ///     entitlement, so the coordinator would fetch real records from the
  ///     user's iCloud into on-disk profile stores; those records have bled
  ///     into tests' in-memory containers via SwiftData's shared process
  ///     state and caused intermittent balance failures.
  ///   - --ui-testing: the app is running against in-memory `TestBackend`-
  ///     shaped storage and must not reach for real iCloud.
  ///     See guides/UI_TEST_GUIDE.md §6.
  private static func configureSyncCoordinator(
    store: ProfileStore,
    coordinator: SyncCoordinator,
    isUITesting: Bool,
    logger: Logger
  ) {
    if isUITesting {
      logger.info("Running under --ui-testing — skipping CloudKit sync coordinator")
      return
    }
    if NSClassFromString("XCTestCase") != nil {
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
        zoneName: "profile-index",
        ownerName: CKCurrentUserDefaultName
      )
      coordinator?.queueSave(id: id, zoneID: zoneID)
    }
    store.onProfileDeleted = { [weak coordinator] id in
      let zoneID = CKRecordZone.ID(
        zoneName: "profile-index",
        ownerName: CKCurrentUserDefaultName
      )
      coordinator?.queueDeletion(id: id, zoneID: zoneID)
    }
    coordinator.start()
    // Clean up the legacy CloudKit zone from SwiftData's automatic sync
    LegacyZoneCleanup.performIfNeeded()
  }

  /// Wires the App Intents service locator, and on macOS also configures the
  /// AppleScript scripting context with the other supporting services.
  private static func configureAutomation(
    sessionManager: SessionManager,
    store: ProfileStore,
    containerManager: ProfileContainerManager,
    syncCoordinator: SyncCoordinator
  ) {
    #if os(macOS)
      let automationService = ScriptingContext.configure(
        sessionManager: sessionManager,
        profileStore: store,
        containerManager: containerManager,
        syncCoordinator: syncCoordinator
      )
    #else
      let automationService = AutomationService(sessionManager: sessionManager)
    #endif
    AutomationServiceLocator.shared.service = automationService
  }
}
