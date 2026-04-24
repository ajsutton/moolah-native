// swiftlint:disable multiline_arguments

import CloudKit
import OSLog
import SwiftData
import SwiftUI

// Command-menu definitions live in `MoolahDomainCommands.swift`.

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

    let store = ProfileStore(
      validator: RemoteServerValidator(),
      containerManager: setup.manager,
      syncCoordinator: coordinator
    )
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
