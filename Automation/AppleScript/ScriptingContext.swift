#if os(macOS)
  import Foundation

  /// Static accessor for AppleScript command handlers to reach the app's services.
  /// Set during app initialization before any scripting commands can execute.
  @MainActor
  enum ScriptingContext {
    static var automationService: AutomationService?
    static var sessionManager: SessionManager?
  }
#endif
