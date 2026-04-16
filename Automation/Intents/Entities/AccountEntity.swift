import AppIntents
import Foundation

struct AccountEntity: AppEntity {
  nonisolated(unsafe) static var typeDisplayRepresentation = TypeDisplayRepresentation(
    name: "Account")
  nonisolated(unsafe) static var defaultQuery = AccountQuery()

  var id: UUID
  var name: String
  var accountType: String
  var balance: Double

  var displayRepresentation: DisplayRepresentation {
    DisplayRepresentation(title: "\(name)", subtitle: "\(accountType)")
  }

  init(from account: Account) {
    self.id = account.id
    self.name = account.name
    self.accountType = account.type.displayName
    self.balance = account.displayBalance.doubleValue
  }
}

struct AccountQuery: EntityQuery {
  @IntentParameter(title: "Profile")
  var profile: ProfileEntity?

  @MainActor
  func entities(for identifiers: [UUID]) async throws -> [AccountEntity] {
    guard let service = AutomationServiceLocator.shared.service else { return [] }
    guard let profile else { return [] }
    let accounts = try service.listAccounts(profileIdentifier: profile.id.uuidString)
    return
      accounts
      .filter { identifiers.contains($0.id) }
      .map { AccountEntity(from: $0) }
  }

  @MainActor
  func suggestedEntities() async throws -> [AccountEntity] {
    guard let service = AutomationServiceLocator.shared.service else { return [] }
    guard let profile else {
      // If no profile specified, show accounts from all open profiles
      let profiles = service.listOpenProfiles()
      return try profiles.flatMap { profile in
        try service.listAccounts(profileIdentifier: profile.id.uuidString)
          .map { AccountEntity(from: $0) }
      }
    }
    let accounts = try service.listAccounts(profileIdentifier: profile.id.uuidString)
    return accounts.map { AccountEntity(from: $0) }
  }
}
