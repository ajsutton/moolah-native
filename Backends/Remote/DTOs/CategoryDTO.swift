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

  struct ListWrapper: Codable {
    let categories: [CategoryDTO]
  }
}
