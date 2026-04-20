import Foundation
import SwiftData

final class CloudKitCSVImportProfileRepository: CSVImportProfileRepository, @unchecked Sendable {
  private let modelContainer: ModelContainer
  var onRecordChanged: (UUID) -> Void = { _ in }
  var onRecordDeleted: (UUID) -> Void = { _ in }

  init(modelContainer: ModelContainer) {
    self.modelContainer = modelContainer
  }

  @MainActor
  private var context: ModelContext { modelContainer.mainContext }

  func fetchAll() async throws -> [CSVImportProfile] {
    try await MainActor.run {
      let descriptor = FetchDescriptor<CSVImportProfileRecord>(
        sortBy: [SortDescriptor(\.createdAt)])
      return try context.fetch(descriptor).map { $0.toDomain() }
    }
  }

  func create(_ profile: CSVImportProfile) async throws -> CSVImportProfile {
    try await MainActor.run {
      let record = CSVImportProfileRecord.from(profile)
      context.insert(record)
      try context.save()
      onRecordChanged(profile.id)
      return record.toDomain()
    }
  }

  func update(_ profile: CSVImportProfile) async throws -> CSVImportProfile {
    let profileId = profile.id
    let descriptor = FetchDescriptor<CSVImportProfileRecord>(
      predicate: #Predicate { $0.id == profileId })
    return try await MainActor.run {
      guard let record = try context.fetch(descriptor).first else {
        throw BackendError.serverError(404)
      }
      record.accountId = profile.accountId
      record.parserIdentifier = profile.parserIdentifier
      record.headerSignature = profile.headerSignature.joined(
        separator: CSVImportProfileRecord.separator)
      record.filenamePattern = profile.filenamePattern
      record.deleteAfterImport = profile.deleteAfterImport
      record.lastUsedAt = profile.lastUsedAt
      try context.save()
      onRecordChanged(profile.id)
      return record.toDomain()
    }
  }

  func delete(id: UUID) async throws {
    let descriptor = FetchDescriptor<CSVImportProfileRecord>(
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
}
