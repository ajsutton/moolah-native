import Foundation

protocol CategoryRepository: Sendable {
  func fetchAll() async throws -> [Category]
}
