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

      let objectKey = specifier.key

      // Walk up to find the profile name
      guard let profileSpec = specifier.container as? NSNameSpecifier else {
        // Maybe the specifier IS a profile
        if let nameSpec = specifier as? NSNameSpecifier, specifier.key == "scriptableProfiles" {
          // Navigate to profile root — just open the window
          let profileName = nameSpec.name
          let urlString =
            "moolah://\(profileName.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed) ?? profileName)"
          if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
          }
          return nil
        }
        scriptErrorNumber = -10000
        scriptErrorString = "Cannot determine profile for navigation"
        return nil
      }
      let profileName = profileSpec.name

      // Build a moolah:// URL based on the object type
      let destination: String
      switch objectKey {
      case "scriptableAccounts":
        if let nameSpec = specifier as? NSNameSpecifier {
          destination =
            "accounts/\(nameSpec.name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? nameSpec.name)"
        } else {
          destination = "accounts"
        }
      case "scriptableTransactions":
        destination = "transactions"
      case "scriptableEarmarks":
        if let nameSpec = specifier as? NSNameSpecifier {
          destination =
            "earmarks/\(nameSpec.name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? nameSpec.name)"
        } else {
          destination = "earmarks"
        }
      case "scriptableCategories":
        destination = "categories"
      default:
        destination = ""
      }

      let host =
        profileName.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed) ?? profileName
      let urlString = destination.isEmpty ? "moolah://\(host)" : "moolah://\(host)/\(destination)"
      if let url = URL(string: urlString) {
        NSWorkspace.shared.open(url)
      }

      return nil
    }
  }
#endif
