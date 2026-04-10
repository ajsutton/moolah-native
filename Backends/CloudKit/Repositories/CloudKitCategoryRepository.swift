import Foundation
import SwiftData

final class CloudKitCategoryRepository: CategoryRepository, @unchecked Sendable {
  private let modelContainer: ModelContainer
  private let profileId: UUID

  init(modelContainer: ModelContainer, profileId: UUID) {
    self.modelContainer = modelContainer
    self.profileId = profileId
  }

  @MainActor
  private var context: ModelContext {
    modelContainer.mainContext
  }

  func fetchAll() async throws -> [Category] {
    let profileId = self.profileId
    let descriptor = FetchDescriptor<CategoryRecord>(
      predicate: #Predicate { $0.profileId == profileId },
      sortBy: [SortDescriptor(\.name)]
    )
    return try await MainActor.run {
      let records = try context.fetch(descriptor)
      return records.map { $0.toDomain() }
    }
  }

  func create(_ category: Category) async throws -> Category {
    let record = CategoryRecord.from(category, profileId: profileId)
    try await MainActor.run {
      context.insert(record)
      try context.save()
    }
    return category
  }

  func update(_ category: Category) async throws -> Category {
    let categoryId = category.id
    let profileId = self.profileId
    let descriptor = FetchDescriptor<CategoryRecord>(
      predicate: #Predicate { $0.id == categoryId && $0.profileId == profileId }
    )
    try await MainActor.run {
      guard let record = try context.fetch(descriptor).first else {
        throw BackendError.serverError(404)
      }
      record.name = category.name
      record.parentId = category.parentId
      try context.save()
    }
    return category
  }

  func delete(id: UUID, withReplacement replacementId: UUID?) async throws {
    let profileId = self.profileId
    let targetId = id

    let descriptor = FetchDescriptor<CategoryRecord>(
      predicate: #Predicate { $0.id == targetId && $0.profileId == profileId }
    )

    try await MainActor.run {
      guard let record = try context.fetch(descriptor).first else {
        throw BackendError.serverError(404)
      }

      // Update children to point to replacement (or nil)
      let childDescriptor = FetchDescriptor<CategoryRecord>(
        predicate: #Predicate { $0.parentId == targetId && $0.profileId == profileId }
      )
      let children = try context.fetch(childDescriptor)
      for child in children {
        child.parentId = replacementId
      }

      context.delete(record)
      try context.save()
    }
  }
}
