#if os(macOS)
  import AppKit
  import Foundation
  import OSLog

  private let logger = Logger(subsystem: "com.moolah.app", category: "NavigateCommand")

  /// Handles: `navigate to account "Checking" of profile "X"`
  /// Uses the URL scheme handler to trigger navigation in the UI.
  class NavigateCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
      guard let specifier = directParameter as? NSScriptObjectSpecifier else {
        scriptErrorNumber = -10000
        scriptErrorString = "Missing object specifier for navigation"
        return nil
      }

      guard let profileSpec = specifier.container as? NSNameSpecifier else {
        return openProfileRoot(specifier: specifier)
      }

      let host =
        profileSpec.name.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed)
        ?? profileSpec.name
      let destination = destinationPath(for: specifier)
      let urlString = destination.isEmpty ? "moolah://\(host)" : "moolah://\(host)/\(destination)"
      if let url = URL(string: urlString) { NSWorkspace.shared.open(url) }
      return nil
    }

    /// Open the top-level window for a profile specifier with no container,
    /// or record an error when the specifier can't be resolved to a profile.
    private func openProfileRoot(specifier: NSScriptObjectSpecifier) -> Any? {
      if let nameSpec = specifier as? NSNameSpecifier, specifier.key == "scriptableProfiles" {
        let encoded =
          nameSpec.name.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed)
          ?? nameSpec.name
        if let url = URL(string: "moolah://\(encoded)") { NSWorkspace.shared.open(url) }
        return nil
      }
      scriptErrorNumber = -10000
      scriptErrorString = "Cannot determine profile for navigation"
      return nil
    }

    /// Map an object specifier (accounts / transactions / earmarks / categories)
    /// to the tail of the `moolah://` URL.
    private func destinationPath(for specifier: NSScriptObjectSpecifier) -> String {
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
  }
#endif
