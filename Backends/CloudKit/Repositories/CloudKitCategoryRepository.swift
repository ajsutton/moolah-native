import Foundation
import SwiftData
import os

final class CloudKitCategoryRepository: CategoryRepository, @unchecked Sendable {
  private let modelContainer: ModelContainer
  var onRecordChanged: (UUID) -> Void = { _ in }
  var onRecordDeleted: (UUID) -> Void = { _ in }

  init(modelContainer: ModelContainer) {
    self.modelContainer = modelContainer
  }

  @MainActor private var context: ModelContext {
    modelContainer.mainContext
  }

  func fetchAll() async throws -> [Category] {
    let signpostID = OSSignpostID(log: Signposts.repository)
    os_signpost(
      .begin, log: Signposts.repository, name: "CategoryRepo.fetchAll", signpostID: signpostID)
    defer {
      os_signpost(
        .end, log: Signposts.repository, name: "CategoryRepo.fetchAll", signpostID: signpostID)
    }
    let descriptor = FetchDescriptor<CategoryRecord>(
      sortBy: [SortDescriptor(\.name)]
    )
    return try await MainActor.run {
      let records = try context.fetch(descriptor)
      return records.map { $0.toDomain() }
    }
  }

  func create(_ category: Category) async throws -> Category {
    let signpostID = OSSignpostID(log: Signposts.repository)
    os_signpost(
      .begin, log: Signposts.repository, name: "CategoryRepo.create", signpostID: signpostID)
    defer {
      os_signpost(
        .end, log: Signposts.repository, name: "CategoryRepo.create", signpostID: signpostID)
    }
    let record = CategoryRecord.from(category)
    try await MainActor.run {
      context.insert(record)
      try context.save()
      onRecordChanged(category.id)
    }
    return category
  }

  func update(_ category: Category) async throws -> Category {
    let signpostID = OSSignpostID(log: Signposts.repository)
    os_signpost(
      .begin, log: Signposts.repository, name: "CategoryRepo.update", signpostID: signpostID)
    defer {
      os_signpost(
        .end, log: Signposts.repository, name: "CategoryRepo.update", signpostID: signpostID)
    }
    let categoryId = category.id
    let descriptor = FetchDescriptor<CategoryRecord>(
      predicate: #Predicate { $0.id == categoryId }
    )
    try await MainActor.run {
      guard let record = try context.fetch(descriptor).first else {
        throw BackendError.serverError(404)
      }
      record.name = category.name
      record.parentId = category.parentId
      try context.save()
      onRecordChanged(category.id)
    }
    return category
  }

  func delete(id: UUID, withReplacement replacementId: UUID?) async throws {
    let signpostID = OSSignpostID(log: Signposts.repository)
    os_signpost(
      .begin, log: Signposts.repository, name: "CategoryRepo.delete", signpostID: signpostID)
    defer {
      os_signpost(
        .end, log: Signposts.repository, name: "CategoryRepo.delete", signpostID: signpostID)
    }
    try await MainActor.run {
      try performDelete(id: id, replacementId: replacementId)
    }
  }

  /// Main-actor portion of `delete(id:withReplacement:)`. All SwiftData
  /// access happens here so the async wrapper stays a thin signpost shim.
  @MainActor
  private func performDelete(id: UUID, replacementId: UUID?) throws {
    let targetId = id
    let descriptor = FetchDescriptor<CategoryRecord>(
      predicate: #Predicate { $0.id == targetId }
    )
    guard let record = try context.fetch(descriptor).first else {
      throw BackendError.serverError(404)
    }

    let children = try orphanChildren(of: targetId)
    let affectedLegs = try reassignLegs(from: id, to: replacementId)
    let (deletedBudgetIds, updatedBudgetIds) = try reassignBudgets(
      from: id, to: replacementId)

    context.delete(record)
    try context.save()

    // Queue sync changes for all affected records
    onRecordDeleted(id)
    for child in children { onRecordChanged(child.id) }
    for leg in affectedLegs { onRecordChanged(leg.id) }
    for budgetId in deletedBudgetIds { onRecordDeleted(budgetId) }
    for budgetId in updatedBudgetIds { onRecordChanged(budgetId) }
  }

  /// Orphan child categories of `targetId` (server always sets parent_id = NULL).
  @MainActor
  private func orphanChildren(of targetId: UUID) throws -> [CategoryRecord] {
    let childDescriptor = FetchDescriptor<CategoryRecord>(
      predicate: #Predicate { $0.parentId == targetId }
    )
    let children = try context.fetch(childDescriptor)
    for child in children {
      child.parentId = nil
    }
    return children
  }

  /// Update transaction legs referencing `deletedId` to point at `replacementId`.
  @MainActor
  private func reassignLegs(
    from deletedId: UUID, to replacementId: UUID?
  ) throws -> [TransactionLegRecord] {
    let legDescriptor = FetchDescriptor<TransactionLegRecord>(
      predicate: #Predicate { $0.categoryId == deletedId }
    )
    let affectedLegs = try context.fetch(legDescriptor)
    for leg in affectedLegs {
      leg.categoryId = replacementId
    }
    return affectedLegs
  }

  /// Reassign budget items that referenced the deleted category. Returns the
  /// ids of the budgets that were deleted (because their earmark already
  /// had a budget line for `replacementId`) and the ids that were updated.
  @MainActor
  private func reassignBudgets(
    from deletedId: UUID, to replacementId: UUID?
  ) throws -> (deleted: [UUID], updated: [UUID]) {
    let budgetDescriptor = FetchDescriptor<EarmarkBudgetItemRecord>(
      predicate: #Predicate { $0.categoryId == deletedId }
    )
    let affectedBudgets = try context.fetch(budgetDescriptor)
    var deletedBudgetIds: [UUID] = []
    var updatedBudgetIds: [UUID] = []
    for budget in affectedBudgets {
      guard let replacementId else {
        deletedBudgetIds.append(budget.id)
        context.delete(budget)
        continue
      }
      // If the replacement already has a budget for this earmark, drop
      // the old one; otherwise rewrite this one to point at it.
      let budgetEarmarkId = budget.earmarkId
      let existingDescriptor = FetchDescriptor<EarmarkBudgetItemRecord>(
        predicate: #Predicate {
          $0.earmarkId == budgetEarmarkId && $0.categoryId == replacementId
        }
      )
      if try context.fetch(existingDescriptor).first != nil {
        deletedBudgetIds.append(budget.id)
        context.delete(budget)
      } else {
        updatedBudgetIds.append(budget.id)
        budget.categoryId = replacementId
      }
    }
    return (deletedBudgetIds, updatedBudgetIds)
  }
}
