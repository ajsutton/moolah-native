import Foundation

struct CategoryDTO: Codable {
  let id: String
  let name: String
  let parentId: String?

  func toDomain() -> Category {
    Category(
      id: FlexibleUUID.parse(id) ?? UUID(),
      name: name,
      parentId: parentId.flatMap { FlexibleUUID.parse($0) }
    )
  }

  static func fromDomain(_ category: Category) -> CategoryDTO {
    CategoryDTO(
      id: category.id.uuidString,
      name: category.name,
      parentId: category.parentId?.uuidString
    )
  }

  struct ListWrapper: Codable {
    let categories: [CategoryDTO]
  }
}
