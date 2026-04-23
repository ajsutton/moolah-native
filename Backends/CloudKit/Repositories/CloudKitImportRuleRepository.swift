import Foundation
import SwiftData

final class CloudKitImportRuleRepository: ImportRuleRepository, @unchecked Sendable {
  private let modelContainer: ModelContainer
  var onRecordChanged: (UUID) -> Void = { _ in }
  var onRecordDeleted: (UUID) -> Void = { _ in }

  init(modelContainer: ModelContainer) {
    self.modelContainer = modelContainer
  }

  @MainActor private var context: ModelContext { modelContainer.mainContext }

  func fetchAll() async throws -> [ImportRule] {
    try await MainActor.run {
      let descriptor = FetchDescriptor<ImportRuleRecord>(
        sortBy: [SortDescriptor(\.position)])
      return try context.fetch(descriptor).map { $0.toDomain() }
    }
  }

  func create(_ rule: ImportRule) async throws -> ImportRule {
    try await MainActor.run {
      let record = ImportRuleRecord.from(rule)
      context.insert(record)
      try context.save()
      onRecordChanged(rule.id)
      return record.toDomain()
    }
  }

  func update(_ rule: ImportRule) async throws -> ImportRule {
    let ruleId = rule.id
    let descriptor = FetchDescriptor<ImportRuleRecord>(
      predicate: #Predicate { $0.id == ruleId })
    return try await MainActor.run {
      guard let record = try context.fetch(descriptor).first else {
        throw BackendError.serverError(404)
      }
      let updated = ImportRuleRecord.from(rule)
      record.name = updated.name
      record.enabled = updated.enabled
      record.position = updated.position
      record.matchMode = updated.matchMode
      record.conditionsJSON = updated.conditionsJSON
      record.actionsJSON = updated.actionsJSON
      record.accountScope = updated.accountScope
      try context.save()
      onRecordChanged(rule.id)
      return record.toDomain()
    }
  }

  func delete(id: UUID) async throws {
    let descriptor = FetchDescriptor<ImportRuleRecord>(
      predicate: #Predicate { $0.id == id })
    try await MainActor.run {
      guard let record = try context.fetch(descriptor).first else {
        throw BackendError.serverError(404)
      }
      context.delete(record)
      try context.save()
      onRecordDeleted(id)
    }
  }

  /// Atomically renumber `position` across every existing rule. Throws if the
  /// passed ids do not exactly match the set of stored rule ids (no adds, no
  /// drops). No fix-up on mismatch: callers re-fetch and re-order.
  ///
  /// Only ids whose position actually changed are queued for upload — a reorder
  /// that leaves every position unchanged is a no-op to CloudKit.
  func reorder(_ orderedIds: [UUID]) async throws {
    try await MainActor.run {
      let all = try context.fetch(FetchDescriptor<ImportRuleRecord>())
      let storedIds = Set(all.map(\.id))
      let requestedIds = Set(orderedIds)
      guard storedIds == requestedIds, all.count == orderedIds.count else {
        throw BackendError.serverError(409)
      }
      let indexById = Dictionary(
        uniqueKeysWithValues: orderedIds.enumerated().map { ($1, $0) })
      var changedIds: [UUID] = []
      for record in all {
        let newPosition = indexById[record.id] ?? record.position
        if record.position != newPosition {
          record.position = newPosition
          changedIds.append(record.id)
        }
      }
      try context.save()
      for id in changedIds { onRecordChanged(id) }
    }
  }
}
