import Foundation

protocol EarmarkRepository: Sendable {
  func fetchAll() async throws -> [Earmark]
}
