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

@main
@MainActor
struct MoolahApp: App {
  @Environment(\.scenePhase) private var scenePhase
  private let containerManager: ProfileContainerManager
  private let syncCoordinator: SyncCoordinator
  @State private var profileStore: ProfileStore
  private let logger = Logger(subsystem: "com.moolah.app", category: "BackgroundSync")
  #if os(macOS)
    private let backupManager: StoreBackupManager
    @State private var sessionManager: SessionManager
  #else
    @State private var activeSession: ProfileSession?
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
        ProfileCommands(
          profileStore: profileStore, sessionManager: sessionManager,
          containerManager: containerManager)
        NewTransactionCommands()
        NewEarmarkCommands()
        RefreshCommands()
        ShowHiddenCommands()
      }

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
          .environment(containerManager)
          .environment(syncCoordinator)
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
}
