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
