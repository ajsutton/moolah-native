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

  /// Full path for a category, e.g. "Income:Salary:Janet".
  func path(for category: Category) -> String {
    var parts: [String] = [category.name]
    var current = category
    while let parentId = current.parentId, let parent = by(id: parentId) {
      parts.insert(parent.name, at: 0)
      current = parent
    }
    return parts.joined(separator: ":")
  }

  /// All descendants of a given category, depth-first; excludes the category itself.
  func descendants(of parentId: UUID) -> [Category] {
    var result: [Category] = []
    for child in children(of: parentId) {
      result.append(child)
      result.append(contentsOf: descendants(of: child.id))
    }
    return result
  }

  /// An entry in the flattened category list.
  struct FlatEntry: Sendable {
    let category: Category
    let path: String
  }

  /// All categories flattened with full paths, sorted alphabetically by path.
  func flattenedByPath() -> [FlatEntry] {
    var result: [FlatEntry] = []
    func collect(_ parentId: UUID?) {
      let children = parentId.map { self.children(of: $0) } ?? roots
      for child in children {
        result.append(FlatEntry(category: child, path: path(for: child)))
        collect(child.id)
      }
    }
    collect(nil)
    return result.sorted { $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending }
  }
}
