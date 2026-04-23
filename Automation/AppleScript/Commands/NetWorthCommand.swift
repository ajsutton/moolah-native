#if os(macOS)
  import AppKit
  import Foundation
  import OSLog

  private let logger = Logger(subsystem: "com.moolah.app", category: "NetWorthCommand")

  /// Handles: `net worth profile "X"` → returns a real number
  class NetWorthCommand: AppLevelScriptCommand {
    override func performDefaultImplementation() -> Any? {
      guard let profileName = resolveProfileName() else {
        scriptErrorNumber = -10000
        scriptErrorString = "Missing profile specifier"
        return nil
      }

      let result: NSNumber? = runBlockingWithError { @MainActor () async throws -> NSNumber in
        guard let service = ScriptingContext.automationService else {
          throw AutomationError.operationFailed("Scripting not configured")
        }
        let netWorth = try await service.getNetWorth(profileIdentifier: profileName)
        return netWorth.doubleValue as NSNumber
      }
      return result
    }
  }
#endif
