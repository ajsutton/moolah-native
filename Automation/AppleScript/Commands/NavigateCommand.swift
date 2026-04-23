#if os(macOS)
  import AppKit
  import Foundation
  import OSLog

  private let logger = Logger(subsystem: "com.moolah.app", category: "NavigateCommand")

  /// Handles: `navigate to account "Checking" of profile "X"`.
  ///
  /// Drives the UI in-process through `ScriptingContext` closures rather than
  /// building a `moolah://` URL and calling `NSWorkspace.shared.open` — a URL
  /// round-trip causes SwiftUI's `WindowGroup(for: Profile.ID.self)` to
  /// auto-spawn a stray window on the URL event (issue #378). The URL scheme
  /// parser is still used to translate the specifier into a `Destination`.
  class NavigateCommand: AppLevelScriptCommand {
    override func performDefaultImplementation() -> Any? {
      guard let specifier = directParameter as? NSScriptObjectSpecifier else {
        scriptErrorNumber = -10000
        scriptErrorString = "Missing object specifier for navigation"
        return nil
      }

      let profileName: String
      let destinationPath: String

      if let profileSpec = specifier.container as? NSNameSpecifier {
        profileName = profileSpec.name
        destinationPath = destinationTail(for: specifier)
      } else if let nameSpec = specifier as? NSNameSpecifier,
        specifier.key == "scriptableProfiles"
      {
        profileName = nameSpec.name
        destinationPath = ""
      } else {
        scriptErrorNumber = -10000
        scriptErrorString = "Cannot determine profile for navigation"
        return nil
      }

      let destination = parsedDestination(
        profileName: profileName, destinationPath: destinationPath)

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
      profileName: String, destination: URLSchemeHandler.Destination?
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
        guard let opener = ScriptingContext.openProfileWindow else {
          logger.error(
            "ScriptingContext.openProfileWindow unset — cannot open '\(profileName, privacy: .public)'"
          )
          return .appNotReady
        }
        opener(profile.id)
      }

      if let destination {
        ScriptingContext.setPendingNavigation?(
          PendingNavigation(profileId: profile.id, destination: destination))
      }
      return .success
    }

    // MARK: - Parsing helpers

    /// Map an object specifier (accounts / transactions / earmarks / categories)
    /// to the URL path tail that `URLSchemeHandler` will parse.
    private func destinationTail(for specifier: NSScriptObjectSpecifier) -> String {
      switch specifier.key {
      case "scriptableAccounts":
        return namedPath(prefix: "accounts", specifier: specifier)
      case "scriptableTransactions":
        return "transactions"
      case "scriptableEarmarks":
        return namedPath(prefix: "earmarks", specifier: specifier)
      case "scriptableCategories":
        return "categories"
      default:
        return ""
      }
    }

    /// Append the specifier's name to `prefix` (if the specifier is a name
    /// specifier) or return just the prefix otherwise.
    private func namedPath(prefix: String, specifier: NSScriptObjectSpecifier) -> String {
      guard let nameSpec = specifier as? NSNameSpecifier else { return prefix }
      let encoded =
        nameSpec.name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
        ?? nameSpec.name
      return "\(prefix)/\(encoded)"
    }

    /// Reuses `URLSchemeHandler.parse` to translate the destination path into
    /// a typed `Destination`. The URL is synthetic — it is never opened.
    private func parsedDestination(profileName: String, destinationPath: String)
      -> URLSchemeHandler.Destination?
    {
      guard !destinationPath.isEmpty else { return nil }
      let host =
        profileName.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed) ?? profileName
      guard let url = URL(string: "moolah://\(host)/\(destinationPath)") else { return nil }
      return (try? URLSchemeHandler.parse(url))?.destination
    }

    @MainActor
    private static func resolveProfile(named name: String, in store: ProfileStore) -> Profile? {
      let lowered = name.lowercased()
      return store.profiles.first(where: { $0.label.lowercased() == lowered })
        ?? store.profiles.first(where: { $0.id.uuidString.lowercased() == lowered })
    }
  }
#endif
