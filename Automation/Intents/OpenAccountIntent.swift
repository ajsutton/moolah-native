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

    let profileEncoded =
      profile.name.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed) ?? profile.name
    let urlString = "moolah://\(profileEncoded)/account/\(account.id.uuidString)"
    if let url = URL(string: urlString) {
      #if os(macOS)
        NSWorkspace.shared.open(url)
      #else
        await UIApplication.shared.open(url)
      #endif
    }

    return .result(value: "Opening \(account.name)")
  }
}
