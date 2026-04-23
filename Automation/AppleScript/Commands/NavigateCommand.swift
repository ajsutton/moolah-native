#if os(macOS)
  import AppKit
  import Foundation
  import OSLog

  private let logger = Logger(subsystem: "com.moolah.app", category: "NavigateCommand")

  /// Handles: `navigate to account "Checking" of profile "X"`.
  ///
  /// Drives the UI in-process through `ScriptingContext` closures: focuses an
  /// existing profile window via `ProfileWindowLocator` when one is already
  /// on screen, or calls the scene's `openWindow` action through
  /// `ScriptingContext.openProfileWindow`. Destinations (list views like
  /// accounts / earmarks / categories) are dispatched via
  /// `PendingNavigation`.
  class NavigateCommand: AppLevelScriptCommand {
    override func performDefaultImplementation() -> Any? {
      guard let specifier = directParameter as? NSScriptObjectSpecifier else {
        scriptErrorNumber = -10000
        scriptErrorString = "Missing object specifier for navigation"
        return nil
      }

      let profileName: String
      let destination: NavigationDestination?

      if let profileSpec = specifier.container as? NSNameSpecifier {
        profileName = profileSpec.name
        destination = Self.destination(for: specifier)
      } else if let nameSpec = specifier as? NSNameSpecifier,
        specifier.key == "scriptableProfiles"
      {
        profileName = nameSpec.name
        destination = nil
      } else {
        scriptErrorNumber = -10000
        scriptErrorString = "Cannot determine profile for navigation"
        return nil
      }

      let result: DispatchResult = MainActor.assumeIsolated {
        Self.dispatch(profileName: profileName, destination: destination)
      }
      switch result {
      case .success:
        return nil
      case .profileNotFound(let name):
        scriptErrorNumber = -10000
        scriptErrorString = "Profile not found: \(name)"
        return nil
      case .appNotReady:
        scriptErrorNumber = -10000
        scriptErrorString = "App not ready to open a new profile window"
        return nil
      }
    }

    // MARK: - Routing

    /// Why a `Dispatch` may fail. Kept separate so `performDefaultImplementation`
    /// (non-MainActor) can set the Cocoa error fields after `dispatch` returns.
    private enum DispatchResult {
      case success
      case profileNotFound(String)
      case appNotReady
    }

    @MainActor
    private static func dispatch(
      profileName: String, destination: NavigationDestination?
    ) -> DispatchResult {
      guard
        let profileStore = ScriptingContext.profileStore,
        let profile = resolveProfile(named: profileName, in: profileStore)
      else {
        logger.warning(
          "No profile found matching '\(profileName, privacy: .public)'"
        )
        return .profileNotFound(profileName)
      }

      if !ProfileWindowLocator.activateExistingWindow(for: profile.id) {
        guard let opener = NavigationBridge.openProfile else {
          logger.error(
            "NavigationBridge.openProfile unset — cannot open '\(profileName, privacy: .public)'"
          )
          return .appNotReady
        }
        opener(profile.id)
      }

      if let destination {
        NavigationBridge.setPendingNavigation?(
          PendingNavigation(profileId: profile.id, destination: destination))
      }
      return .success
    }

    // MARK: - Specifier decoding

    /// Maps an AppleScript object specifier (`scriptableAccounts`,
    /// `scriptableEarmarks`, …) onto a `NavigationDestination`. Returns `nil`
    /// for specifier keys that don't correspond to a list/detail view — the
    /// caller treats that as "navigate to the profile root only".
    private static func destination(
      for specifier: NSScriptObjectSpecifier
    ) -> NavigationDestination? {
      switch specifier.key {
      case "scriptableAccounts": .accounts
      case "scriptableEarmarks": .earmarks
      case "scriptableCategories": .categories
      default: nil
      }
    }

    @MainActor
    private static func resolveProfile(named name: String, in store: ProfileStore) -> Profile? {
      let lowered = name.lowercased()
      return store.profiles.first(where: { $0.label.lowercased() == lowered })
        ?? store.profiles.first(where: { $0.id.uuidString.lowercased() == lowered })
    }
  }
#endif
