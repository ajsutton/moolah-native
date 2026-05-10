import Foundation

extension Array where Element: Hashable {
  /// Returns elements in order of first appearance, removing duplicates.
  /// Uses `Set`-based dedup; runs in O(n) and preserves stable ordering.
  func uniqued() -> [Element] {
    var seen = Set<Element>()
    return filter { seen.insert($0).inserted }
  }
}
