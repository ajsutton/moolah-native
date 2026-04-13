import CloudKit
import CoreData
import Foundation
import OSLog
import SwiftData

/// Observes local SwiftData saves and queues the corresponding changes
/// in the sync engine for upload to CloudKit.
@MainActor
final class ChangeTracker {
  private let syncEngine: ProfileSyncEngine
  private let modelContainer: ModelContainer
  private let logger = Logger(subsystem: "com.moolah.app", category: "ChangeTracker")
  private nonisolated(unsafe) var observer: NSObjectProtocol?

  init(syncEngine: ProfileSyncEngine, modelContainer: ModelContainer) {
    self.syncEngine = syncEngine
    self.modelContainer = modelContainer
  }

  func startTracking() {
    guard observer == nil else { return }

    observer = NotificationCenter.default.addObserver(
      forName: .NSManagedObjectContextDidSave,
      object: nil,
      queue: .main
    ) { [weak self] notification in
      // Only process per-profile data entities — ignore ProfileRecord saves from
      // the index container which are handled by ProfileIndexSyncEngine.
      let profileDataEntities: Set<String> = [
        "AccountRecord", "TransactionRecord", "CategoryRecord",
        "EarmarkRecord", "EarmarkBudgetItemRecord", "InvestmentValueRecord",
      ]

      func filterAndExtractIDs(_ key: String) -> [UUID] {
        guard let objects = notification.userInfo?[key] as? Set<NSManagedObject> else { return [] }
        return
          objects
          .filter { profileDataEntities.contains($0.entity.name ?? "") }
          .compactMap { $0.value(forKey: "id") as? UUID }
      }

      let insertedIDs = filterAndExtractIDs(NSInsertedObjectsKey)
      let updatedIDs = filterAndExtractIDs(NSUpdatedObjectsKey)
      let deletedIDs = filterAndExtractIDs(NSDeletedObjectsKey)

      guard !insertedIDs.isEmpty || !updatedIDs.isEmpty || !deletedIDs.isEmpty else { return }

      MainActor.assumeIsolated {
        // Skip saves triggered by applying remote changes — those records
        // came from CloudKit and don't need to be re-uploaded.
        guard self?.syncEngine.isApplyingRemoteChanges != true else { return }
        self?.processSave(inserted: insertedIDs, updated: updatedIDs, deleted: deletedIDs)
      }
    }
  }

  func stopTracking() {
    if let observer {
      NotificationCenter.default.removeObserver(observer)
    }
    observer = nil
  }

  deinit {
    if let observer {
      NotificationCenter.default.removeObserver(observer)
    }
  }

  // MARK: - Private

  private func processSave(inserted: [UUID], updated: [UUID], deleted: [UUID]) {
    let zoneID = syncEngine.zoneID

    for id in inserted {
      let recordID = CKRecord.ID(recordName: id.uuidString, zoneID: zoneID)
      syncEngine.addPendingChange(.saveRecord(recordID))
    }

    for id in updated {
      let recordID = CKRecord.ID(recordName: id.uuidString, zoneID: zoneID)
      syncEngine.addPendingChange(.saveRecord(recordID))
    }

    for id in deleted {
      let recordID = CKRecord.ID(recordName: id.uuidString, zoneID: zoneID)
      syncEngine.addPendingChange(.deleteRecord(recordID))
    }
  }
}
