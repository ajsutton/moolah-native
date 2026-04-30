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

  /// Every category in the subtree rooted at `parentId`, in depth-first
  /// pre-order with siblings sorted by name (inherited from `children(of:)`).
  ///
  /// The category identified by `parentId` is not included — callers that
  /// need to operate on the whole subtree (e.g. selecting parent + descendants
  /// for a multi-category filter) must add the root id themselves. Returns an
  /// empty array when `parentId` has no children or is not found.
  func descendants(of parentId: UUID) -> [Category] {
    var result: [Category] = []
    for child in children(of: parentId) {
      result.append(child)
      result.append(contentsOf: descendants(of: child.id))
    }
    return result
  }

  /// Human-readable summary of a multi-category selection. Returns
  /// `"All"` when nothing is selected (or every selected id is orphaned),
  /// the full path when exactly one selected id is still present, and
  /// `"\(N) selected"` when two or more selected ids are still present.
  func selectionSummary(for selectedIds: Set<UUID>) -> String {
    let presentIds = selectedIds.filter { byId[$0] != nil }
    switch presentIds.count {
    case 0:
      return "All"
    case 1:
      let id = presentIds.first!  // safe: count == 1
      return path(for: byId[id]!)
    default:
      return "\(presentIds.count) selected"
    }
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
