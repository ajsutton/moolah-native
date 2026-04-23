import AppIntents
import Foundation

struct CreateEarmarkIntent: AppIntent {
  static let title: LocalizedStringResource = "Create Earmark"
  static let description = IntentDescription(
    "Creates a new earmark (savings goal).")

  @Parameter(title: "Profile") var profile: ProfileEntity

  @Parameter(title: "Name") var name: String

  @Parameter(title: "Target Amount", default: nil) var targetAmount: Double?

  @MainActor
  func perform() async throws -> some IntentResult & ReturnsValue<String> {
    guard let service = AutomationServiceLocator.shared.service else {
      throw AutomationError.operationFailed("App not ready")
    }

    let target = targetAmount.map { Decimal($0) }
    let earmark = try await service.createEarmark(
      profileIdentifier: profile.id.uuidString,
      name: name,
      targetAmount: target
    )

    return .result(value: "Created earmark: \(earmark.name)")
  }
}
