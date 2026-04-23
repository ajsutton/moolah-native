#if os(macOS)
  import AppKit
  import Foundation
  import OSLog

  private let logger = Logger(subsystem: "com.moolah.app", category: "CreateEarmarkCommand")

  /// Handles: `create earmark profile "X" name "Holiday" target 5000.0`
  class CreateEarmarkCommand: AppLevelScriptCommand {
    override func performDefaultImplementation() -> Any? {
      guard let profileName = resolveProfileName() else {
        scriptErrorNumber = -10000
        scriptErrorString = "Missing profile specifier"
        return nil
      }
      guard let args = evaluatedArguments,
        let name = args["name"] as? String
      else {
        scriptErrorNumber = -10000
        scriptErrorString = "Missing required parameter: name"
        return nil
      }

      let target = args["target"] as? Double
      let profName = profileName

      let result: ScriptableEarmark? = runBlockingWithError {
        @MainActor () async throws -> ScriptableEarmark in
        guard let service = ScriptingContext.automationService else {
          throw AutomationError.operationFailed("Scripting not configured")
        }
        let earmark = try await service.createEarmark(
          profileIdentifier: profName,
          name: name,
          targetAmount: target.map { Decimal($0) }
        )
        return ScriptableEarmark(earmark: earmark, profileName: profName)
      }
      return result
    }
  }
#endif
