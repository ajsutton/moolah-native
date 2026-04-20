import Foundation

protocol ImportRuleRepository: Sendable {
  func fetchAll() async throws -> [ImportRule]
  func create(_ rule: ImportRule) async throws -> ImportRule
  func update(_ rule: ImportRule) async throws -> ImportRule
  func delete(id: UUID) async throws

  /// Atomically renumber `position` across every existing rule so that the
  /// passed ids take the positions 0…n-1 in order. Throws if `orderedIds`
  /// does not exactly match the set of stored rule ids.
  func reorder(_ orderedIds: [UUID]) async throws
}
