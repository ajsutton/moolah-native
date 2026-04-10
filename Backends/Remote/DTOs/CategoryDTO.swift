import Foundation

struct CategoryDTO: Codable {
  let id: ServerUUID
  let name: String
  let parentId: ServerUUID?

  func toDomain() -> Category {
    Category(
      id: id.uuid,
      name: name,
      parentId: parentId?.uuid
    )
  }

  static func fromDomain(_ category: Category) -> CategoryDTO {
    CategoryDTO(
      id: ServerUUID(category.id),
      name: category.name,
      parentId: category.parentId.map(ServerUUID.init)
    )
  }

  struct ListWrapper: Codable {
    let categories: [CategoryDTO]
  }
}
