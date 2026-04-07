import Foundation

struct Category: Codable, Sendable, Identifiable, Hashable {
  let id: UUID
  var name: String
  var parentId: UUID?

  init(id: UUID = UUID(), name: String, parentId: UUID? = nil) {
    self.id = id
    self.name = name
    self.parentId = parentId
  }
}

/// A lookup structure for categories, supporting hierarchy traversal.
struct Categories: Sendable {
  private let byId: [UUID: Category]
  private let childrenOf: [UUID?: [Category]]

  init(from categories: [Category]) {
    byId = categories.reduce(into: [:]) { $0[$1.id] = $1 }
    childrenOf = Dictionary(grouping: categories, by: \.parentId)
  }

  func by(id: UUID) -> Category? {
    byId[id]
  }

  /// Top-level categories (those with no parent).
  var roots: [Category] {
    (childrenOf[nil] ?? []).sorted { $0.name < $1.name }
  }

  /// Direct children of a given category.
  func children(of parentId: UUID) -> [Category] {
    (childrenOf[parentId] ?? []).sorted { $0.name < $1.name }
  }
}
