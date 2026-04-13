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

  @MainActor
  private var context: ModelContext {
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
    let targetId = id

    let descriptor = FetchDescriptor<CategoryRecord>(
      predicate: #Predicate { $0.id == targetId }
    )

    try await MainActor.run {
      guard let record = try context.fetch(descriptor).first else {
        throw BackendError.serverError(404)
      }

      // Orphan children (server always sets parent_id = NULL)
      let childDescriptor = FetchDescriptor<CategoryRecord>(
        predicate: #Predicate { $0.parentId == targetId }
      )
      let children = try context.fetch(childDescriptor)
      for child in children {
        child.parentId = nil
      }

      // Update transactions that reference this category
      let deletedId = id
      let txnDescriptor = FetchDescriptor<TransactionRecord>(
        predicate: #Predicate { $0.categoryId == deletedId }
      )
      let affectedTxns = try context.fetch(txnDescriptor)
      for txn in affectedTxns {
        txn.categoryId = replacementId
      }

      // Update budget items that reference this category
      let budgetDescriptor = FetchDescriptor<EarmarkBudgetItemRecord>(
        predicate: #Predicate { $0.categoryId == deletedId }
      )
      let affectedBudgets = try context.fetch(budgetDescriptor)
      var deletedBudgetIds: [UUID] = []
      var updatedBudgetIds: [UUID] = []
      for budget in affectedBudgets {
        if let replacementId {
          // If replacement already has a budget for this earmark, drop the old one
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
        } else {
          deletedBudgetIds.append(budget.id)
          context.delete(budget)
        }
      }

      context.delete(record)
      try context.save()

      // Queue sync changes for all affected records
      onRecordDeleted(id)
      for child in children { onRecordChanged(child.id) }
      for txn in affectedTxns { onRecordChanged(txn.id) }
      for budgetId in deletedBudgetIds { onRecordDeleted(budgetId) }
      for budgetId in updatedBudgetIds { onRecordChanged(budgetId) }
    }
  }
}
