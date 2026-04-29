import CloudKit
import Foundation
import GRDB
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
  /// Per-profile GRDB queue cache. Required so `ProfileSession.init` and
  /// the import path see the same queue when the manager is in-memory
  /// (`ProfileDatabase.openInMemory()` returns a fresh queue every
  /// call). On-disk profiles all open the same `data.sqlite` file
  /// regardless of whether the cache hits, but caching avoids a redundant
  /// migrator pass.
  private var databases: [UUID: DatabaseQueue] = [:]

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

  /// Opens (and caches) the per-profile GRDB queue. In-memory managers
  /// must serve the same queue across every call so `ProfileSession`
  /// and the import path share writes; on-disk managers re-open the
  /// same `data.sqlite` either way but caching avoids redundant
  /// migrator runs.
  func database(for profileId: UUID) throws -> DatabaseQueue {
    if let existing = databases[profileId] {
      return existing
    }
    let database: DatabaseQueue
    if inMemory {
      database = try ProfileDatabase.openInMemory()
    } else {
      let url = ProfileSession.profileDatabaseDirectory(for: profileId)
        .appendingPathComponent("data.sqlite")
      database = try ProfileDatabase.open(at: url)
    }
    databases[profileId] = database
    return database
  }

  private let logger = Logger(subsystem: "com.moolah.app", category: "ProfileContainerManager")

  func deleteStore(for profileId: UUID) {
    containers.removeValue(forKey: profileId)
    databases.removeValue(forKey: profileId)

    guard !inMemory else { return }

    let basePath = "Moolah-\(profileId.uuidString).store"
    let baseURL = URL.moolahScopedApplicationSupport.appending(path: basePath)
    let fileManager = FileManager.default
    for suffix in ["", "-shm", "-wal"] {
      let url = baseURL.deletingLastPathComponent()
        .appending(path: baseURL.lastPathComponent + suffix)
      removeIfPresent(url, fileManager: fileManager, label: "SwiftData store file")
    }

    // Delete the sync state file
    let syncStateURL = URL.moolahScopedApplicationSupport
      .appending(path: "Moolah-\(profileId.uuidString).syncstate")
    removeIfPresent(syncStateURL, fileManager: fileManager, label: "sync state file")

    // Delete the per-profile GRDB directory (data.sqlite + -wal/-shm
    // sidecars) added in the rate-storage-grdb refactor. Removing the
    // directory cleans up sidecars without enumerating each suffix.
    let dbDirectory = ProfileSession.profileDatabaseDirectory(for: profileId)
    removeIfPresent(dbDirectory, fileManager: fileManager, label: "GRDB profile directory")

    // Delete the CloudKit zone for this profile
    deleteCloudKitZone(for: profileId)
  }

  /// Best-effort removal: a missing path is normal (e.g. WAL sidecar absent
  /// for a clean-shutdown store), so swallow `NSFileNoSuchFileError` quietly
  /// and log every other failure at `.warning`. Replaces a silent `try?`
  /// per `CODE_GUIDE.md` §8.
  private func removeIfPresent(_ url: URL, fileManager: FileManager, label: String) {
    do {
      try fileManager.removeItem(at: url)
    } catch let error as NSError
      where error.domain == NSCocoaErrorDomain
      && error.code == NSFileNoSuchFileError
    {
      // Path was already absent — fine.
    } catch {
      logger.warning(
        "Failed to delete \(label, privacy: .public) at \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
      )
    }
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
