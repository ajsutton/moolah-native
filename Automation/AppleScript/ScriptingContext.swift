#if os(macOS)
  import Foundation

  /// Static accessor for AppleScript command handlers to reach the app's services.
  /// Populated during app initialization (see `ScriptingContext.configure(...)`)
  /// before any scripting commands can execute.
  @MainActor
  enum ScriptingContext {
    static var automationService: AutomationService?
    static var sessionManager: SessionManager?
    static var profileStore: ProfileStore?
    static var containerManager: ProfileContainerManager?
    static var syncCoordinator: SyncCoordinator?

    // MARK: - SwiftUI Bridges
    //
    // Scripting commands (`NavigateCommand`, `OpenAccountIntent`) need to
    // open a profile window or set a pending navigation without
    // round-tripping through `NSWorkspace.shared.open(moolah://…)`. Firing a
    // URL event causes SwiftUI's `WindowGroup(for: Profile.ID.self)` to
    // auto-spawn a stray window (issue #378). `ProfileWindowView.task`
    // captures the scene's `openWindow` action and `pendingNavigation`
    // binding into these closures so commands can drive the UI in-process.
    static var openProfileWindow: ((UUID) -> Void)?
    static var setPendingNavigation: ((PendingNavigation) -> Void)?

    /// Wires a freshly built `AutomationService` to the scripting context and
    /// returns it. Also records the supporting services so extension methods
    /// (e.g. profile export/import) can reach them when commands execute.
    @discardableResult
    static func configure(
      sessionManager: SessionManager,
      profileStore: ProfileStore,
      containerManager: ProfileContainerManager,
      syncCoordinator: SyncCoordinator
    ) -> AutomationService {
      let service = AutomationService(sessionManager: sessionManager)
      self.automationService = service
      self.sessionManager = sessionManager
      self.profileStore = profileStore
      self.containerManager = containerManager
      self.syncCoordinator = syncCoordinator
      return service
    }
  }
#endif
