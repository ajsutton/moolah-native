import AppIntents
import Foundation

#if os(macOS)
  import AppKit
#else
  import UIKit
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

    #if os(macOS)
      // Drive the UI in-process (focus existing window or call the scene's
      // `openWindow` action via `ScriptingContext`) rather than firing a
      // `moolah://` URL event that SwiftUI's `WindowGroup(for:)` would
      // auto-spawn a stray window for. See issue #378.
      try dispatchMacOS()
    #else
      let profileEncoded =
        profile.name.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed) ?? profile.name
      let urlString = "moolah://\(profileEncoded)/account/\(account.id.uuidString)"
      if let url = URL(string: urlString) {
        await UIApplication.shared.open(url)
      }
    #endif

    return .result(value: "Opening \(account.name)")
  }

  #if os(macOS)
    @MainActor
    private func dispatchMacOS() throws {
      if !ProfileWindowLocator.activateExistingWindow(for: profile.id) {
        guard let opener = ScriptingContext.openProfileWindow else {
          throw AutomationError.operationFailed("App not ready to open a profile window")
        }
        opener(profile.id)
      }
      ScriptingContext.setPendingNavigation?(
        PendingNavigation(profileId: profile.id, destination: .account(account.id)))
    }
  #endif
}
