import AppIntents
import Foundation

struct GetAccountBalanceIntent: AppIntent {
  static let title: LocalizedStringResource = "Get Account Balance"
  static let description = IntentDescription(
    "Returns the balance of a specific account.")

  @Parameter(title: "Profile") var profile: ProfileEntity

  @Parameter(title: "Account") var account: AccountEntity

  @MainActor
  func perform() async throws -> some IntentResult & ReturnsValue<String> {
    guard let service = AutomationServiceLocator.shared.service else {
      throw AutomationError.operationFailed("App not ready")
    }
    let session = try service.resolveSession(for: profile.id.uuidString)
    let displayBalance = try await session.accountStore.displayBalance(for: account.id)
    return .result(value: displayBalance.formatted)
  }
}
