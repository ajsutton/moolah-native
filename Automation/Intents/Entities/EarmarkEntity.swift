import AppIntents
import Foundation

struct EarmarkEntity: AppEntity {
  static let typeDisplayRepresentation = TypeDisplayRepresentation(
    name: "Earmark")
  static let defaultQuery = EarmarkQuery()

  var id: UUID
  var name: String
  var balance: Double

  var displayRepresentation: DisplayRepresentation {
    DisplayRepresentation(title: "\(name)")
  }

  init(from earmark: Earmark) {
    self.id = earmark.id
    self.name = earmark.name
    self.balance = 0
  }
}

struct EarmarkQuery: EntityQuery {
  @IntentParameter(title: "Profile")
  var profile: ProfileEntity?

  @MainActor
  func entities(for identifiers: [UUID]) async throws -> [EarmarkEntity] {
    guard let service = AutomationServiceLocator.shared.service else { return [] }
    guard let profile else { return [] }
    let earmarks = try service.listEarmarks(profileIdentifier: profile.id.uuidString)
    return
      earmarks
      .filter { identifiers.contains($0.id) }
      .filter { !$0.isHidden }
      .map { EarmarkEntity(from: $0) }
  }

  @MainActor
  func suggestedEntities() async throws -> [EarmarkEntity] {
    guard let service = AutomationServiceLocator.shared.service else { return [] }
    guard let profile else {
      let profiles = service.listOpenProfiles()
      return try profiles.flatMap { profile in
        try service.listEarmarks(profileIdentifier: profile.id.uuidString)
          .filter { !$0.isHidden }
          .map { EarmarkEntity(from: $0) }
      }
    }
    let earmarks = try service.listEarmarks(profileIdentifier: profile.id.uuidString)
    return earmarks.filter { !$0.isHidden }.map { EarmarkEntity(from: $0) }
  }
}
