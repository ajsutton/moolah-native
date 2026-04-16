#if os(macOS)
  import AppKit
  import Foundation
  import OSLog

  private let logger = Logger(subsystem: "com.moolah.app", category: "CreateAccountCommand")

  /// Handles: `create account profile "X" name "Checking" type "bank"`
  class CreateAccountCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
      guard let profileName = resolveProfileName() else {
        scriptErrorNumber = -10000
        scriptErrorString = "Missing profile specifier"
        return nil
      }
      guard let args = evaluatedArguments,
        let name = args["name"] as? String,
        let typeString = args["type"] as? String
      else {
        scriptErrorNumber = -10000
        scriptErrorString = "Missing required parameters: name and type"
        return nil
      }

      guard let accountType = AccountType(rawValue: typeString) else {
        scriptErrorNumber = -10000
        scriptErrorString =
          "Invalid account type '\(typeString)'. Use: bank, cc, asset, or investment"
        return nil
      }

      let profName = profileName
      let result: ScriptableAccount? = runBlockingWithError {
        @MainActor () async throws -> ScriptableAccount in
        guard let service = ScriptingContext.automationService else {
          throw AutomationError.operationFailed("Scripting not configured")
        }
        let account = try await service.createAccount(
          profileIdentifier: profName,
          name: name,
          type: accountType
        )
        return ScriptableAccount(account: account, profileName: profName)
      }
      return result
    }
  }
#endif
