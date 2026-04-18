import AppIntents
import Foundation

struct AddInvestmentValueIntent: AppIntent {
  static let title: LocalizedStringResource = "Set Investment Value"
  static let description = IntentDescription(
    "Records the current market value for an investment account.")

  @Parameter(title: "Profile")
  var profile: ProfileEntity

  @Parameter(title: "Account")
  var account: AccountEntity

  @Parameter(title: "Value")
  var value: Double

  @MainActor
  func perform() async throws -> some IntentResult & ReturnsValue<String> {
    guard let service = AutomationServiceLocator.shared.service else {
      throw AutomationError.operationFailed("App not ready")
    }

    try await service.setInvestmentValue(
      profileIdentifier: profile.id.uuidString,
      accountName: account.name,
      date: Date(),
      value: Decimal(value)
    )

    return .result(value: "Updated investment value for \(account.name)")
  }
}
