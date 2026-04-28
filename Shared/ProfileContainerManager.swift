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
  /// `true` when the manager was created via `.forTesting()` — every
  /// SwiftData container is in-memory and so must the per-profile GRDB
  /// queue be (otherwise UI tests would write `data.sqlite` files to the
  /// host's Application Support).
  let inMemory: Bool
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
      let url = URL.moolahScopedApplicationSupport
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
    let baseURL = URL.moolahScopedApplicationSupport.appending(path: basePath)
    let fileManager = FileManager.default
    for suffix in ["", "-shm", "-wal"] {
      let url = baseURL.deletingLastPathComponent()
        .appending(path: baseURL.lastPathComponent + suffix)
      try? fileManager.removeItem(at: url)
    }

    // Delete the sync state file
    let syncStateURL = URL.moolahScopedApplicationSupport
      .appending(path: "Moolah-\(profileId.uuidString).syncstate")
    try? fileManager.removeItem(at: syncStateURL)

    // Delete the per-profile GRDB directory (data.sqlite + -wal/-shm
    // sidecars) added in the rate-storage-grdb refactor. Removing the
    // directory cleans up sidecars without enumerating each suffix.
    let dbDirectory = ProfileSession.profileDatabaseDirectory(for: profileId)
    try? fileManager.removeItem(at: dbDirectory)

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
        try await CloudKitContainer.app.privateCloudDatabase.deleteRecordZone(withID: zoneID)
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
