import Foundation
import SwiftData

@Model
final class CategoryRecord {
  #Unique<CategoryRecord>([\.id])

  var id: UUID
  var profileId: UUID
  var name: String
  var parentId: UUID?

  init(id: UUID = UUID(), profileId: UUID, name: String, parentId: UUID? = nil) {
    self.id = id
    self.profileId = profileId
    self.name = name
    self.parentId = parentId
  }

  func toDomain() -> Category {
    Category(id: id, name: name, parentId: parentId)
  }

  static func from(_ category: Category, profileId: UUID) -> CategoryRecord {
    CategoryRecord(
      id: category.id, profileId: profileId, name: category.name, parentId: category.parentId)
  }
}
