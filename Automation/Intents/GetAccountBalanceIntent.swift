import AppIntents
import Foundation

struct GetAccountBalanceIntent: AppIntent {
  nonisolated(unsafe) static var title: LocalizedStringResource = "Get Account Balance"
  nonisolated(unsafe) static var description = IntentDescription(
    "Returns the balance of a specific account.")

  @Parameter(title: "Profile")
  var profile: ProfileEntity

  @Parameter(title: "Account")
  var account: AccountEntity

  @MainActor
  func perform() async throws -> some IntentResult & ReturnsValue<String> {
    guard let service = AutomationServiceLocator.shared.service else {
      throw AutomationError.operationFailed("App not ready")
    }
    let session = try service.resolveSession(for: profile.id.uuidString)
    let displayBalance = session.accountStore.displayBalance(for: account.id)
    return .result(value: displayBalance.formatted)
  }
}
