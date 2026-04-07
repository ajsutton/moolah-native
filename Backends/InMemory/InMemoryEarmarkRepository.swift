import Foundation

actor InMemoryEarmarkRepository: EarmarkRepository {
  private var earmarks: [UUID: Earmark]

  init(initialEarmarks: [Earmark] = []) {
    self.earmarks = Dictionary(uniqueKeysWithValues: initialEarmarks.map { ($0.id, $0) })
  }

  func fetchAll() async throws -> [Earmark] {
    return Array(earmarks.values).sorted()
  }

  // For test setup
  func setEarmarks(_ earmarks: [Earmark]) {
    self.earmarks = Dictionary(uniqueKeysWithValues: earmarks.map { ($0.id, $0) })
  }
}
