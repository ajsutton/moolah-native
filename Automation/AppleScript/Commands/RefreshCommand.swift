#if os(macOS)
  import AppKit
  import Foundation
  import OSLog

  private let logger = Logger(subsystem: "com.moolah.app", category: "RefreshCommand")

  /// Handles: `refresh profile "X"` or `refresh`
  class RefreshCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
      let profileName = resolveProfileName()

      let _: Bool? = runBlockingWithError { @MainActor in
        guard let service = ScriptingContext.automationService else {
          throw AutomationError.operationFailed("Scripting not configured")
        }

        if let profileName {
          try await service.refresh(profileIdentifier: profileName)
        } else {
          // Refresh all open profiles
          for session in service.sessionManager.openProfiles {
            try await service.refresh(profileIdentifier: session.profile.label)
          }
        }

        return true
      }
      return nil
    }
  }
#endif
