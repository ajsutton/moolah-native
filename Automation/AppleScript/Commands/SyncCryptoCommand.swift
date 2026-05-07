#if os(macOS)
  import AppKit
  import Foundation
  import OSLog

  private let logger = Logger(subsystem: "com.moolah.app", category: "SyncCryptoCommand")

  /// Handles: `sync crypto profile "X"` or `sync crypto`.
  ///
  /// Forces a crypto-account sync for a single profile (when given a
  /// profile specifier) or every open profile. Equivalent to the user
  /// hitting "Sync now" on every wallet account at once and bypasses
  /// the staleness check, so automation and smoke tests can drive the
  /// importer without waiting for the hourly timer.
  class SyncCryptoCommand: AppLevelScriptCommand {
    override func performDefaultImplementation() -> Any? {
      let profileName = resolveProfileName()

      let _: Void? = runBlockingWithError { @MainActor in
        guard let service = ScriptingContext.automationService else {
          throw AutomationError.operationFailed("Scripting not configured")
        }

        if let profileName {
          try await service.syncCryptoAccounts(profileIdentifier: profileName)
        } else {
          for session in service.sessionManager.openProfiles {
            try await service.syncCryptoAccounts(profileIdentifier: session.profile.label)
          }
        }
      }
      return nil
    }
  }
#endif
