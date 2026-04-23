import AppIntents
import Foundation

struct CategoryEntity: AppEntity {
  static let typeDisplayRepresentation = TypeDisplayRepresentation(
    name: "Category")
  static let defaultQuery = CategoryQuery()

  var id: UUID
  var name: String

  var displayRepresentation: DisplayRepresentation {
    DisplayRepresentation(title: "\(name)")
  }

  init(from category: Category) {
    self.id = category.id
    self.name = category.name
  }
}

struct CategoryQuery: EntityQuery {
  @IntentParameter(title: "Profile") var profile: ProfileEntity?

  @MainActor
  func entities(for identifiers: [UUID]) async throws -> [CategoryEntity] {
    guard let service = AutomationServiceLocator.shared.service else { return [] }
    guard let profile else { return [] }
    let categories = try service.listCategories(profileIdentifier: profile.id.uuidString)
    return
      categories
      .filter { identifiers.contains($0.id) }
      .map { CategoryEntity(from: $0) }
  }

  @MainActor
  func suggestedEntities() async throws -> [CategoryEntity] {
    guard let service = AutomationServiceLocator.shared.service else { return [] }
    guard let profile else {
      let profiles = service.listOpenProfiles()
      return try profiles.flatMap { profile in
        try service.listCategories(profileIdentifier: profile.id.uuidString)
          .map { CategoryEntity(from: $0) }
      }
    }
    let categories = try service.listCategories(profileIdentifier: profile.id.uuidString)
    return categories.map { CategoryEntity(from: $0) }
  }
}
