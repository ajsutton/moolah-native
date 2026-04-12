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
      // Extract data while on the notification's thread (main queue)
      let inserted = notification.userInfo?[NSInsertedObjectsKey] as? Set<NSManagedObject>
      let updated = notification.userInfo?[NSUpdatedObjectsKey] as? Set<NSManagedObject>
      let deleted = notification.userInfo?[NSDeletedObjectsKey] as? Set<NSManagedObject>

      // Extract UUIDs synchronously while objects are still valid
      let insertedIDs = inserted?.compactMap { $0.value(forKey: "id") as? UUID } ?? []
      let updatedIDs = updated?.compactMap { $0.value(forKey: "id") as? UUID } ?? []
      let deletedIDs = deleted?.compactMap { $0.value(forKey: "id") as? UUID } ?? []

      MainActor.assumeIsolated {
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
