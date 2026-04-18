import CloudKit
import OSLog
import SwiftData
import SwiftUI

/// Commands for creating new transactions
struct NewTransactionCommands: Commands {
  @FocusedValue(\.newTransactionAction) private var newTransactionAction

  var body: some Commands {
    CommandGroup(replacing: .newItem) {
      Button("New Transaction") {
        newTransactionAction?()
      }
      .keyboardShortcut("n", modifiers: .command)
      .disabled(newTransactionAction == nil)
    }
  }
}

/// Commands for creating new earmarks
struct NewEarmarkCommands: Commands {
  @FocusedValue(\.newEarmarkAction) private var newEarmarkAction

  var body: some Commands {
    CommandGroup(after: .newItem) {
      Button("New Earmark") {
        newEarmarkAction?()
      }
      .keyboardShortcut("n", modifiers: [.command, .shift])
      .disabled(newEarmarkAction == nil)
    }
  }
}

/// Commands for refreshing data
struct RefreshCommands: Commands {
  @FocusedValue(\.refreshAction) private var refreshAction

  var body: some Commands {
    CommandGroup(after: .newItem) {
      Divider()
      Button("Refresh") {
        refreshAction?()
      }
      .keyboardShortcut("r", modifiers: .command)
      .disabled(refreshAction == nil)
    }
  }
}

/// View menu toggle for showing hidden accounts and earmarks
struct ShowHiddenCommands: Commands {
  @FocusedValue(\.showHiddenAccounts) private var showHidden

  var body: some Commands {
    CommandGroup(after: .sidebar) {
      if let showHidden {
        Toggle("Show Hidden Accounts", isOn: showHidden)
          .keyboardShortcut("h", modifiers: [.command, .shift])
      }
    }
  }
}

/// Groups the Moolah-specific domain menus (Transaction, Go, and future Account/Earmark/Category).
/// Wraps them into a single `Commands` so the top-level `.commands` block stays within
/// `CommandsBuilder`'s 10-argument `buildBlock` limit.
struct MoolahDomainCommands: Commands {
  var body: some Commands {
    TransactionCommands()
  }
}

@main
@MainActor
struct MoolahApp: App {
  @Environment(\.scenePhase) private var scenePhase
  private let containerManager: ProfileContainerManager
  private let syncCoordinator: SyncCoordinator
  @State private var profileStore: ProfileStore
  private let logger = Logger(subsystem: "com.moolah.app", category: "BackgroundSync")
  @State private var pendingNavigation: PendingNavigation?
  #if os(macOS)
    @NSApplicationDelegateAdaptor(ScriptingBridge.self) var scriptingBridge
    @Environment(\.openWindow) private var openWindow
    private let backupManager: StoreBackupManager
    @State private var sessionManager: SessionManager
  #else
    @State private var activeSession: ProfileSession?
    @State private var sessionManager: SessionManager
  #endif

  init() {
    do {
      let profileSchema = Schema([ProfileRecord.self])
      let profileStoreURL = URL.applicationSupportDirectory.appending(path: "Moolah-v2.store")
      let profileConfig = ModelConfiguration(
        url: profileStoreURL,
        cloudKitDatabase: .none
      )
      let indexContainer = try ModelContainer(for: profileSchema, configurations: [profileConfig])

      let dataSchema = Schema([
        AccountRecord.self,
        TransactionRecord.self,
        TransactionLegRecord.self,
        InstrumentRecord.self,
        CategoryRecord.self,
        EarmarkRecord.self,
        EarmarkBudgetItemRecord.self,
        InvestmentValueRecord.self,
      ])

      let manager = ProfileContainerManager(
        indexContainer: indexContainer,
        dataSchema: dataSchema
      )
      containerManager = manager
      syncCoordinator = SyncCoordinator(containerManager: manager)
    } catch {
      fatalError("Failed to initialize ModelContainer: \(error)")
    }

    let store = ProfileStore(validator: RemoteServerValidator(), containerManager: containerManager)
    _profileStore = State(initialValue: store)

    let coordinator = syncCoordinator

    // Wire sync coordinator to reload profiles on remote changes (only when CloudKit is available)
    if CloudKitAuthProvider.isCloudKitAvailable {
      logger.info("CloudKit available — starting sync coordinator")
      _ = coordinator.addIndexObserver { [weak store] in
        store?.loadCloudProfiles()
      }
      store.onProfileChanged = { [weak coordinator] id in
        let zoneID = CKRecordZone.ID(
          zoneName: "profile-index", ownerName: CKCurrentUserDefaultName)
        coordinator?.queueSave(id: id, zoneID: zoneID)
      }
      store.onProfileDeleted = { [weak coordinator] id in
        let zoneID = CKRecordZone.ID(
          zoneName: "profile-index", ownerName: CKCurrentUserDefaultName)
        coordinator?.queueDeletion(id: id, zoneID: zoneID)
      }
      coordinator.start()

      // Clean up the legacy CloudKit zone from SwiftData's automatic sync
      LegacyZoneCleanup.performIfNeeded()
    } else {
      logger.warning(
        "CloudKit not available — profile sync disabled (NSUbiquitousContainers missing from Info.plist)"
      )
    }

    #if os(macOS)
      backupManager = StoreBackupManager()
      let sessionManager = SessionManager(
        containerManager: containerManager, syncCoordinator: coordinator)
      _sessionManager = State(initialValue: sessionManager)

      // Clean up cached sessions when a profile is removed (locally or via remote sync)
      store.onProfileRemoved = { [weak sessionManager] profileID in
        sessionManager?.removeSession(for: profileID)
      }

      // Configure AppleScript scripting context and App Intents service locator
      let automationService = AutomationService(sessionManager: sessionManager)
      ScriptingContext.automationService = automationService
      ScriptingContext.sessionManager = sessionManager
      AutomationServiceLocator.shared.service = automationService
    #else
      let sessionManager = SessionManager(
        containerManager: containerManager, syncCoordinator: coordinator)
      _sessionManager = State(initialValue: sessionManager)

      // Clean up cached sessions when a profile is removed (locally or via remote sync)
      store.onProfileRemoved = { [weak sessionManager] profileID in
        sessionManager?.removeSession(for: profileID)
      }

      // Configure App Intents service locator
      let automationService = AutomationService(sessionManager: sessionManager)
      AutomationServiceLocator.shared.service = automationService
    #endif
  }

  var body: some Scene {
    #if os(macOS)
      WindowGroup(for: Profile.ID.self) { $profileID in
        ProfileWindowView(profileID: profileID)
          .environment(profileStore)
          .environment(sessionManager)
          .environment(containerManager)
          .environment(syncCoordinator)
          .environment(\.pendingNavigation, $pendingNavigation)
          .onOpenURL { url in handleURL(url) }
          .task {
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
          profileStore: profileStore, sessionManager: sessionManager,
          containerManager: containerManager)
        NewTransactionCommands()
        NewEarmarkCommands()
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

      Settings {
        SettingsView()
          .environment(profileStore)
          .environment(sessionManager)
          .environment(containerManager)
          .modelContainer(containerManager.indexContainer)
      }
    #else
      WindowGroup {
        ProfileRootView(activeSession: $activeSession)
          .environment(profileStore)
          .environment(sessionManager)
          .environment(containerManager)
          .environment(syncCoordinator)
          .environment(\.pendingNavigation, $pendingNavigation)
          .onOpenURL { url in handleURL(url) }
      }
      .modelContainer(containerManager.indexContainer)
      .onChange(of: scenePhase) { _, newPhase in
        handleScenePhaseChange(newPhase)
      }
      .commands {
        NewTransactionCommands()
        NewEarmarkCommands()
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

  // MARK: - URL Scheme Handling

  private func handleURL(_ url: URL) {
    do {
      let route = try URLSchemeHandler.parse(url)
      // Find profile by name (case-insensitive) then by UUID
      if let profile = profileStore.profiles.first(where: {
        $0.label.lowercased() == route.profileIdentifier.lowercased()
      })
        ?? profileStore.profiles.first(where: {
          $0.id.uuidString.lowercased() == route.profileIdentifier.lowercased()
        })
      {
        #if os(macOS)
          openWindow(value: profile.id)
        #else
          profileStore.setActiveProfile(profile.id)
        #endif
        if let destination = route.destination {
          pendingNavigation = PendingNavigation(
            profileId: profile.id, destination: destination)
        }
      } else {
        logger.warning(
          "No profile found matching '\(route.profileIdentifier, privacy: .public)'")
      }
    } catch {
      logger.error("Failed to parse URL: \(error.localizedDescription, privacy: .public)")
    }
  }
}
