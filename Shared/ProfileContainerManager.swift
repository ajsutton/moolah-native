import CloudKit
import Foundation
import OSLog
import Observation
import SwiftData

@Observable
@MainActor
final class ProfileContainerManager {
  let indexContainer: ModelContainer
  private let dataSchema: Schema
  private let inMemory: Bool
  private var containers: [UUID: ModelContainer] = [:]

  init(
    indexContainer: ModelContainer,
    dataSchema: Schema,
    inMemory: Bool = false
  ) {
    self.indexContainer = indexContainer
    self.dataSchema = dataSchema
    self.inMemory = inMemory
  }

  func container(for profileId: UUID) throws -> ModelContainer {
    if let existing = containers[profileId] {
      return existing
    }
    let config: ModelConfiguration
    if inMemory {
      config = ModelConfiguration(isStoredInMemoryOnly: true)
    } else {
      let storeName = "Moolah-\(profileId.uuidString)"
      let url = URL.applicationSupportDirectory
        .appending(path: "Moolah-\(profileId.uuidString).store")
      config = ModelConfiguration(storeName, url: url, cloudKitDatabase: .none)
    }
    let container = try ModelContainer(for: dataSchema, configurations: [config])
    containers[profileId] = container
    return container
  }

  /// Returns whether a cached container exists for the given profile.
  func hasContainer(for profileId: UUID) -> Bool {
    containers[profileId] != nil
  }

  private let logger = Logger(subsystem: "com.moolah.app", category: "ProfileContainerManager")

  func deleteStore(for profileId: UUID) {
    containers.removeValue(forKey: profileId)

    guard !inMemory else { return }

    let basePath = "Moolah-\(profileId.uuidString).store"
    let baseURL = URL.applicationSupportDirectory.appending(path: basePath)
    let fm = FileManager.default
    for suffix in ["", "-shm", "-wal"] {
      let url = baseURL.deletingLastPathComponent()
        .appending(path: baseURL.lastPathComponent + suffix)
      try? fm.removeItem(at: url)
    }

    // Delete the sync state file
    let syncStateURL = URL.applicationSupportDirectory
      .appending(path: "Moolah-\(profileId.uuidString).syncstate")
    try? fm.removeItem(at: syncStateURL)

    // Delete the CloudKit zone for this profile
    deleteCloudKitZone(for: profileId)
  }

  private func deleteCloudKitZone(for profileId: UUID) {
    let zoneID = CKRecordZone.ID(
      zoneName: "profile-\(profileId.uuidString)",
      ownerName: CKCurrentUserDefaultName
    )
    Task {
      do {
        try await CKContainer.default().privateCloudDatabase.deleteRecordZone(withID: zoneID)
        logger.info("Deleted CloudKit zone for profile \(profileId)")
      } catch {
        logger.error("Failed to delete CloudKit zone for profile \(profileId): \(error)")
      }
    }
  }

  /// Returns all known profile IDs from the index container.
  func allProfileIds() -> [UUID] {
    let context = ModelContext(indexContainer)
    let records = (try? context.fetch(FetchDescriptor<ProfileRecord>())) ?? []
    return records.map(\.id)
  }

  /// Deletes old per-engine sync state files from before the unified coordinator.
  func deleteOldSyncStateFiles() {
    let fm = FileManager.default
    let appSupport = URL.applicationSupportDirectory
    // Delete profile-index state file
    try? fm.removeItem(at: appSupport.appending(path: "Moolah-v2-profile-index.syncstate"))
    // Delete per-profile state files
    for profileId in allProfileIds() {
      try? fm.removeItem(at: appSupport.appending(path: "Moolah-\(profileId.uuidString).syncstate"))
    }
  }

  /// Creates a test-only manager with in-memory stores.
  static func forTesting() throws -> ProfileContainerManager {
    let indexSchema = Schema([ProfileRecord.self])
    let indexConfig = ModelConfiguration(isStoredInMemoryOnly: true)
    let indexContainer = try ModelContainer(for: indexSchema, configurations: [indexConfig])

    let dataSchema = Schema([
      AccountRecord.self,
      TransactionRecord.self,
      TransactionLegRecord.self,
      InstrumentRecord.self,
      CategoryRecord.self,
      EarmarkRecord.self,
      EarmarkBudgetItemRecord.self,
      InvestmentValueRecord.self,
      CSVImportProfileRecord.self,
      ImportRuleRecord.self,
    ])

    return ProfileContainerManager(
      indexContainer: indexContainer,
      dataSchema: dataSchema,
      inMemory: true
    )
  }
}
