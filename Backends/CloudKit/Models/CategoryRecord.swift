import Foundation
import SwiftData

@Model
final class CategoryRecord {

  var id: UUID = UUID()
  var name: String = ""
  var parentId: UUID?

  init(id: UUID = UUID(), name: String, parentId: UUID? = nil) {
    self.id = id
    self.name = name
    self.parentId = parentId
  }

  func toDomain() -> Category {
    Category(id: id, name: name, parentId: parentId)
  }

  static func from(_ category: Category) -> CategoryRecord {
    CategoryRecord(
      id: category.id, name: category.name, parentId: category.parentId)
  }
}
