import AppIntents
import Foundation

struct ListAccountsIntent: AppIntent {
  nonisolated(unsafe) static var title: LocalizedStringResource = "List Accounts"
  nonisolated(unsafe) static var description = IntentDescription(
    "Lists accounts and their balances for a profile.")

  @Parameter(title: "Profile")
  var profile: ProfileEntity

  @Parameter(title: "Account Type", default: nil)
  var accountType: AccountTypeEnum?

  @MainActor
  func perform() async throws -> some IntentResult & ReturnsValue<String> {
    guard let service = AutomationServiceLocator.shared.service else {
      throw AutomationError.operationFailed("App not ready")
    }
    var accounts = try service.listAccounts(profileIdentifier: profile.id.uuidString)
    accounts = accounts.filter { !$0.isHidden }

    if let accountType {
      accounts = accounts.filter { $0.type == accountType.toDomainType }
    }

    if accounts.isEmpty {
      return .result(value: "No accounts found.")
    }

    let lines = accounts.map { account in
      "\(account.name): \(account.displayBalance.formatted) (\(account.type.displayName))"
    }
    return .result(value: lines.joined(separator: "\n"))
  }
}

enum AccountTypeEnum: String, AppEnum {
  case bank
  case creditCard
  case asset
  case investment

  nonisolated(unsafe) static var typeDisplayRepresentation = TypeDisplayRepresentation(
    name: "Account Type")

  nonisolated(unsafe) static var caseDisplayRepresentations:
    [AccountTypeEnum: DisplayRepresentation] = [
      .bank: "Bank Account",
      .creditCard: "Credit Card",
      .asset: "Asset",
      .investment: "Investment",
    ]

  var toDomainType: AccountType {
    switch self {
    case .bank: .bank
    case .creditCard: .creditCard
    case .asset: .asset
    case .investment: .investment
    }
  }
}
