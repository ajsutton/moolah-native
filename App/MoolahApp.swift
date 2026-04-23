// swiftlint:disable multiline_arguments

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

      Button("Duplicate Transaction") {}.disabled(true)

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
      goMenuItems
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
        if let url = URL(string: "https://moolah.app/help") { openURL(url) }
      }

      Button("Keyboard Shortcuts\u{2026}") {
        openWindow(id: "keyboard-shortcuts")
      }
      .keyboardShortcut("/", modifiers: [.command, .shift])

      Divider()

      Button("Release Notes") {
        if let url = URL(string: "https://moolah.app/release-notes") { openURL(url) }
      }

      Button("Report a Bug") {
        if let url = URL(string: "https://github.com/ajsutton/moolah-native/issues/new") {
          openURL(url)
        }
      }

      Divider()

      Button("Privacy Policy") {
        if let url = URL(string: "https://moolah.app/privacy") { openURL(url) }
      }

      Button("Terms of Service") {
        if let url = URL(string: "https://moolah.app/terms") { openURL(url) }
      }
    }
  }

  @ViewBuilder private var goMenuItems: some View {
    Button("Transactions") { sidebarSelection?.wrappedValue = .allTransactions }
      .keyboardShortcut("1", modifiers: .command)
      .disabled(sidebarSelection == nil)
    Button("Scheduled") { sidebarSelection?.wrappedValue = .upcomingTransactions }
      .keyboardShortcut("2", modifiers: .command)
      .disabled(sidebarSelection == nil)
    Button("Categories") { sidebarSelection?.wrappedValue = .categories }
      .keyboardShortcut("3", modifiers: .command)
      .disabled(sidebarSelection == nil)
    Button("Reports") { sidebarSelection?.wrappedValue = .reports }
      .keyboardShortcut("4", modifiers: .command)
      .disabled(sidebarSelection == nil)
    Button("Analysis") { sidebarSelection?.wrappedValue = .analysis }
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
}

@main
@MainActor
struct MoolahApp: App {
  @Environment(\.scenePhase) private var scenePhase
  // internal (was private) so the `+Lifecycle` extension can use these in
  // scene-phase / URL-scheme handlers.
  let containerManager: ProfileContainerManager
  let syncCoordinator: SyncCoordinator
  /// The seeded profile ID under `--ui-testing`, or `nil` for production
  /// launches. Stored as `let` because `MoolahApp.init` runs once per
  /// process; the value is decided at launch and never changes.
  private let uiTestingProfileId: UUID?
  @State var profileStore: ProfileStore
  // internal (was private) so `+Lifecycle` can log under the shared
  // subsystem/category.
  let logger = Logger(subsystem: "com.moolah.app", category: "BackgroundSync")
  @State var pendingNavigation: PendingNavigation?

  #if os(macOS)
    @NSApplicationDelegateAdaptor(ScriptingBridge.self) var scriptingBridge
    @Environment(\.openWindow) var openWindow
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
    let uiTestingSeed = Self.uiTestingSeed(from: CommandLine.arguments)
    let setup = Self.makeContainerSetup(uiTestingSeed: uiTestingSeed)
    let coordinator = SyncCoordinator(containerManager: setup.manager)
    containerManager = setup.manager
    syncCoordinator = coordinator
    uiTestingProfileId = setup.uiTestingProfileId

    let store = ProfileStore(validator: RemoteServerValidator(), containerManager: setup.manager)
    _profileStore = State(initialValue: store)

    Self.configureSyncCoordinator(
      store: store,
      coordinator: coordinator,
      uiTestingProfileId: setup.uiTestingProfileId)

    let sessionManager = SessionManager(
      containerManager: setup.manager, syncCoordinator: coordinator)
    // Clean up cached sessions when a profile is removed (locally or via
    // remote sync).
    store.onProfileRemoved = { [weak sessionManager] profileID in
      sessionManager?.removeSession(for: profileID)
    }
    Self.configureAutomationService(
      store: store,
      sessionManager: sessionManager,
      containerManager: setup.manager,
      coordinator: coordinator)

    #if os(macOS)
      backupManager = StoreBackupManager()
    #endif
    _sessionManager = State(initialValue: sessionManager)
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
          .environment(\.pendingNavigation, $pendingNavigation)
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

}
