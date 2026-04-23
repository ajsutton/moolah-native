import AppIntents
import Foundation

#if os(macOS)
  import AppKit
#endif

struct OpenAccountIntent: AppIntent {
  static let title: LocalizedStringResource = "Open Account"
  static let description = IntentDescription(
    "Opens a specific account in the Moolah app.")

  @Parameter(title: "Profile") var profile: ProfileEntity

  @Parameter(title: "Account") var account: AccountEntity

  static let openAppWhenRun = true

  @MainActor
  func perform() async throws -> some IntentResult & ReturnsValue<String> {
    guard AutomationServiceLocator.shared.service != nil else {
      throw AutomationError.operationFailed("App not ready")
    }

    // Drive the UI in-process through `NavigationBridge`. Avoids firing a
    // `moolah://` URL event that the `WindowGroup(for:)` auto-spawn would
    // react to on macOS (issue #378), and works with the URL scheme now
    // removed (issue #386).
    #if os(macOS)
      let alreadyOpen = ProfileWindowLocator.activateExistingWindow(for: profile.id)
    #else
      let alreadyOpen = false
    #endif
    if !alreadyOpen {
      guard let opener = NavigationBridge.openProfile else {
        throw AutomationError.operationFailed("App not ready to open a profile")
      }
      opener(profile.id)
    }
    NavigationBridge.setPendingNavigation?(
      PendingNavigation(profileId: profile.id, destination: .account(account.id)))

    return .result(value: "Opening \(account.name)")
  }
}
