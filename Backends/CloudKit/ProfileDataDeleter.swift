import Foundation
import SwiftData

/// Deletes a profile's ProfileRecord from the index store.
/// The per-profile data store is deleted separately via ProfileContainerManager.
struct ProfileDataDeleter {
  let modelContext: ModelContext

  @MainActor
  func deleteProfileRecord(for profileId: UUID) {
    let descriptor = FetchDescriptor<ProfileRecord>(
      predicate: #Predicate { $0.id == profileId }
    )
    if let records = try? modelContext.fetch(descriptor) {
      for record in records { modelContext.delete(record) }
    }
    try? modelContext.save()
  }
}
