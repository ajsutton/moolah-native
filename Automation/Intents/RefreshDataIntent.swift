import AppIntents
import Foundation

struct RefreshDataIntent: AppIntent {
  static let title: LocalizedStringResource = "Refresh Data"
  static let description = IntentDescription(
    "Refreshes all data from the server for a profile.")

  @Parameter(title: "Profile", default: nil)
  var profile: ProfileEntity?

  @MainActor
  func perform() async throws -> some IntentResult & ReturnsValue<String> {
    guard let service = AutomationServiceLocator.shared.service else {
      throw AutomationError.operationFailed("App not ready")
    }

    if let profile {
      try await service.refresh(profileIdentifier: profile.id.uuidString)
      return .result(value: "Refreshed data for \(profile.name)")
    }

    // Refresh all open profiles
    let profiles = service.listOpenProfiles()
    for openProfile in profiles {
      try await service.refresh(profileIdentifier: openProfile.id.uuidString)
    }
    return .result(value: "Refreshed data for \(profiles.count) profile(s)")
  }
}
