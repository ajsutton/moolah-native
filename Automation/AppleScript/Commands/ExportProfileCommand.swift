#if os(macOS)
  import AppKit
  import Foundation
  import OSLog

  /// Handles: `export profile "X" to file "/path/to/file.json"`
  class ExportProfileCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
      guard let profileName = resolveProfileName() else {
        scriptErrorNumber = -10000
        scriptErrorString = "Missing profile specifier"
        return nil
      }
      guard let args = evaluatedArguments,
        let toFile = args["toFile"] as? String,
        !toFile.isEmpty
      else {
        scriptErrorNumber = -10000
        scriptErrorString = "Missing required parameter: to file"
        return nil
      }
      let fileURL = URL(fileURLWithPath: (toFile as NSString).expandingTildeInPath)

      let _: Void? = runBlockingWithError { @MainActor in
        guard let service = ScriptingContext.automationService else {
          throw AutomationError.operationFailed("Scripting not configured")
        }
        try await service.exportProfile(profileIdentifier: profileName, to: fileURL)
      }
      return nil
    }
  }
#endif
