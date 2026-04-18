import AppIntents
import Foundation

struct ProfileEntity: AppEntity {
  static let typeDisplayRepresentation = TypeDisplayRepresentation(
    name: "Profile")
  static let defaultQuery = ProfileQuery()

  var id: UUID
  var name: String
  var currency: String

  var displayRepresentation: DisplayRepresentation {
    DisplayRepresentation(title: "\(name)", subtitle: "\(currency)")
  }

  init(from profile: Profile) {
    self.id = profile.id
    self.name = profile.label
    self.currency = profile.currencyCode
  }
}

struct ProfileQuery: EntityQuery {
  @MainActor
  func entities(for identifiers: [UUID]) async throws -> [ProfileEntity] {
    guard let service = AutomationServiceLocator.shared.service else { return [] }
    return service.listOpenProfiles()
      .filter { identifiers.contains($0.id) }
      .map { ProfileEntity(from: $0) }
  }

  @MainActor
  func suggestedEntities() async throws -> [ProfileEntity] {
    guard let service = AutomationServiceLocator.shared.service else { return [] }
    return service.listOpenProfiles().map { ProfileEntity(from: $0) }
  }
}
