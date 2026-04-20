import CloudKit
import OSLog
import SwiftData
import SwiftUI

/// Combined File > New… commands (Transaction, Earmark, Account, Category).
/// Grouping them into one Commands struct keeps the top-level `.commands` block
/// under `CommandsBuilder`'s 10-argument limit.
struct NewItemCommands: Commands {
  @FocusedValue(\.newTransactionAction) private var newTransactionAction
  @FocusedValue(\.newEarmarkAction) private var newEarmarkAction
  @FocusedValue(\.newAccountAction) private var newAccountAction
  @FocusedValue(\.newCategoryAction) private var newCategoryAction

  var body: some Commands {
    CommandGroup(replacing: .newItem) {
      Button("New Transaction\u{2026}") {
        newTransactionAction?()
      }
      .keyboardShortcut("n", modifiers: .command)
      .disabled(newTransactionAction == nil)

      Button("New Earmark\u{2026}") {
        newEarmarkAction?()
      }
      .keyboardShortcut("n", modifiers: [.command, .shift])
      .disabled(newEarmarkAction == nil)

      Button("New Account\u{2026}") {
        newAccountAction?()
      }
      .keyboardShortcut("n", modifiers: [.command, .control])
      .disabled(newAccountAction == nil)

      Button("New Category\u{2026}") {
        newCategoryAction?()
      }
      .keyboardShortcut("n", modifiers: [.command, .option])
      .disabled(newCategoryAction == nil)
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

/// View menu verb-pair for showing / hiding hidden accounts and earmarks.
/// Uses a Button with a flipped label (per §14 "Toggle State") and stays
/// visible when no window is focused — disabled per §14 "Disable, don't hide".
struct ShowHiddenCommands: Commands {
  @FocusedValue(\.showHiddenAccounts) private var showHidden

  var body: some Commands {
    CommandGroup(after: .sidebar) {
      Button(
        showHidden?.wrappedValue == true ? "Hide Hidden Accounts" : "Show Hidden Accounts"
      ) {
        showHidden?.wrappedValue.toggle()
      }
      .keyboardShortcut("h", modifiers: [.command, .shift])
      .disabled(showHidden == nil)
    }
  }
}

/// Moolah-specific top-level domain menus grouped into one Commands struct so
/// the outer `.commands` block stays within `CommandsBuilder`'s 10-argument limit.
/// CommandMenus are inlined here (rather than references to per-feature structs)
/// to keep the opaque `some Commands` return type inferable.
struct MoolahDomainCommands: Commands {
  @FocusedValue(\.selectedTransaction) private var selectedTransaction
  @FocusedValue(\.selectedAccount) private var selectedAccount
  @FocusedValue(\.selectedEarmark) private var selectedEarmark
  @FocusedValue(\.selectedCategory) private var selectedCategory
  @FocusedValue(\.sidebarSelection) private var sidebarSelection
  @FocusedValue(\.findInListAction) private var findInListAction
  @Environment(\.openWindow) private var openWindow
  @Environment(\.openURL) private var openURL

  var body: some Commands {
    CommandMenu("Transaction") {
      Button("Edit Transaction\u{2026}") {
        NotificationCenter.default.post(
          name: .requestTransactionEdit,
          object: selectedTransaction?.wrappedValue?.id
        )
      }
      .disabled(selectedTransaction?.wrappedValue == nil)

      Button("Duplicate Transaction") {}
        .disabled(true)

      Button("Pay Scheduled Transaction") {
        NotificationCenter.default.post(
          name: .requestTransactionPay,
          object: selectedTransaction?.wrappedValue?.id
        )
      }
      .disabled(selectedTransaction?.wrappedValue?.recurPeriod == nil)

      Divider()

      Button("Delete Transaction\u{2026}", role: .destructive) {
        NotificationCenter.default.post(
          name: .requestTransactionDelete,
          object: selectedTransaction?.wrappedValue?.id
        )
      }
      .disabled(selectedTransaction?.wrappedValue == nil)
    }

    CommandMenu("Go") {
      Button("Transactions") {
        sidebarSelection?.wrappedValue = .allTransactions
      }
      .keyboardShortcut("1", modifiers: .command)
      .disabled(sidebarSelection == nil)

      Button("Scheduled") {
        sidebarSelection?.wrappedValue = .upcomingTransactions
      }
      .keyboardShortcut("2", modifiers: .command)
      .disabled(sidebarSelection == nil)

      Button("Categories") {
        sidebarSelection?.wrappedValue = .categories
      }
      .keyboardShortcut("3", modifiers: .command)
      .disabled(sidebarSelection == nil)

      Button("Reports") {
        sidebarSelection?.wrappedValue = .reports
      }
      .keyboardShortcut("4", modifiers: .command)
      .disabled(sidebarSelection == nil)

      Button("Analysis") {
        sidebarSelection?.wrappedValue = .analysis
      }
      .keyboardShortcut("5", modifiers: .command)
      .disabled(sidebarSelection == nil)

      Divider()

      Button("Go Back") {}
        .keyboardShortcut("[", modifiers: .command)
        .disabled(true)

      Button("Go Forward") {}
        .keyboardShortcut("]", modifiers: .command)
        .disabled(true)
    }

    CommandMenu("Account") {
      Button("Edit Account\u{2026}") {
        NotificationCenter.default.post(
          name: .requestAccountEdit,
          object: selectedAccount?.wrappedValue?.id
        )
      }
      .disabled(selectedAccount?.wrappedValue == nil)

      Button("View Transactions") {
        if let id = selectedAccount?.wrappedValue?.id {
          sidebarSelection?.wrappedValue = .account(id)
        }
      }
      .disabled(selectedAccount?.wrappedValue == nil)
    }

    CommandMenu("Earmark") {
      Button("Edit Earmark\u{2026}") {
        NotificationCenter.default.post(
          name: .requestEarmarkEdit,
          object: selectedEarmark?.wrappedValue?.id
        )
      }
      .disabled(selectedEarmark?.wrappedValue == nil)

      Button(
        selectedEarmark?.wrappedValue?.isHidden == true ? "Show Earmark" : "Hide Earmark"
      ) {
        NotificationCenter.default.post(
          name: .requestEarmarkToggleHidden,
          object: selectedEarmark?.wrappedValue?.id
        )
      }
      .disabled(selectedEarmark?.wrappedValue == nil)
    }

    CommandMenu("Category") {
      Button("Edit Category\u{2026}") {
        NotificationCenter.default.post(
          name: .requestCategoryEdit,
          object: selectedCategory?.wrappedValue?.id
        )
      }
      .disabled(selectedCategory?.wrappedValue == nil)
    }

    CommandGroup(after: .textEditing) {
      Button("Find Transactions\u{2026}") { findInListAction?() }
        .keyboardShortcut("f", modifiers: .command)
        .disabled(findInListAction == nil)

      Button("Find Next") {}
        .keyboardShortcut("g", modifiers: .command)
        .disabled(true)

      Button("Find Previous") {}
        .keyboardShortcut("g", modifiers: [.command, .shift])
        .disabled(true)
    }

    CommandGroup(after: .pasteboard) {
      Button("Copy Transaction Link") {}
        .keyboardShortcut("c", modifiers: [.command, .control])
        .disabled(true)
    }

    CommandGroup(after: .help) {
      Button("Moolah Help") {
        openURL(URL(string: "https://moolah.app/help")!)
      }

      Button("Keyboard Shortcuts\u{2026}") {
        openWindow(id: "keyboard-shortcuts")
      }
      .keyboardShortcut("/", modifiers: [.command, .shift])

      Divider()

      Button("Release Notes") {
        openURL(URL(string: "https://moolah.app/release-notes")!)
      }

      Button("Report a Bug") {
        openURL(URL(string: "https://github.com/ajsutton/moolah-native/issues/new")!)
      }

      Divider()

      Button("Privacy Policy") {
        openURL(URL(string: "https://moolah.app/privacy")!)
      }

      Button("Terms of Service") {
        openURL(URL(string: "https://moolah.app/terms")!)
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
        CSVImportProfileRecord.self,
        ImportRuleRecord.self,
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
    // Never start CloudKit sync under XCTest: the test binary is signed with the production
    // iCloud entitlement, so the coordinator would fetch real records from the user's iCloud
    // into on-disk profile stores; those records have bled into tests' in-memory containers
    // via SwiftData's shared process state and caused intermittent balance failures.
    let isRunningTests = NSClassFromString("XCTestCase") != nil
    if CloudKitAuthProvider.isCloudKitAvailable && !isRunningTests {
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
    } else if isRunningTests {
      logger.info("Running under XCTest — skipping CloudKit sync coordinator")
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
          containerManager: containerManager, syncCoordinator: syncCoordinator)
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
