import Foundation

/// In-memory rules repository for the REST backend (see RemoteCSVImportProfileRepository
/// for rationale).
actor RemoteImportRuleRepository: ImportRuleRepository {
  private var rules: [UUID: ImportRule] = [:]

  func fetchAll() async throws -> [ImportRule] {
    rules.values.sorted { $0.position < $1.position }
  }

  func create(_ rule: ImportRule) async throws -> ImportRule {
    rules[rule.id] = rule
    return rule
  }

  func update(_ rule: ImportRule) async throws -> ImportRule {
    guard rules[rule.id] != nil else {
      throw BackendError.serverError(404)
    }
    rules[rule.id] = rule
    return rule
  }

  func delete(id: UUID) async throws {
    guard rules.removeValue(forKey: id) != nil else {
      throw BackendError.serverError(404)
    }
  }

  func reorder(_ orderedIds: [UUID]) async throws {
    let storedIds = Set(rules.keys)
    let requestedIds = Set(orderedIds)
    guard storedIds == requestedIds, rules.count == orderedIds.count else {
      throw BackendError.serverError(409)
    }
    for (index, id) in orderedIds.enumerated() {
      if var rule = rules[id] {
        rule.position = index
        rules[id] = rule
      }
    }
  }
}
