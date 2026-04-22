#if os(macOS)
  import AppKit
  import Foundation
  import OSLog

  /// Handles: `import from file "/path/to/file.json"`
  class ImportProfileCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
      guard let args = evaluatedArguments,
        let fromFile = args["fromFile"] as? String,
        !fromFile.isEmpty
      else {
        scriptErrorNumber = -10000
        scriptErrorString = "Missing required parameter: from file"
        return nil
      }
      let fileURL = URL(fileURLWithPath: (fromFile as NSString).expandingTildeInPath)

      let result: ScriptableProfile? = runBlockingWithError {
        @MainActor () async throws -> ScriptableProfile in
        guard let service = ScriptingContext.automationService,
          let sessionManager = ScriptingContext.sessionManager
        else {
          throw AutomationError.operationFailed("Scripting not configured")
        }
        let profile = try await service.importProfile(from: fileURL)
        let session = sessionManager.session(for: profile)
        return ScriptableProfile(session: session)
      }
      return result
    }
  }
#endif
