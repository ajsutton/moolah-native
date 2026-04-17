import AppIntents
import Foundation

struct GetNetWorthIntent: AppIntent {
  nonisolated(unsafe) static var title: LocalizedStringResource = "Get Net Worth"
  nonisolated(unsafe) static var description = IntentDescription(
    "Returns the net worth for a profile.")

  @Parameter(title: "Profile")
  var profile: ProfileEntity

  @MainActor
  func perform() async throws -> some IntentResult & ReturnsValue<String> {
    guard let service = AutomationServiceLocator.shared.service else {
      throw AutomationError.operationFailed("App not ready")
    }
    let netWorth = try await service.getNetWorth(profileIdentifier: profile.id.uuidString)
    return .result(value: netWorth.formatted)
  }
}
