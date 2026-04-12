import CloudKit
import Foundation
import OSLog
import SwiftData

/// Manages CKSyncEngine for the profile index zone (`profile-index`).
/// This syncs the list of profiles across devices, separate from per-profile data.
@MainActor
final class ProfileIndexSyncEngine: Sendable {
  let zoneID: CKRecordZone.ID
  let modelContainer: ModelContainer

  /// Callback invoked after remote changes are applied to the profile index.
  /// Used to trigger `profileStore.loadCloudProfiles()`.
  var onRemoteChangesApplied: (() -> Void)?

  private let logger = Logger(subsystem: "com.moolah.app", category: "ProfileIndexSyncEngine")
  private var pendingSaves: Set<CKRecord.ID> = []
  private var pendingDeletions: Set<CKRecord.ID> = []
  private var syncEngine: CKSyncEngine?
  private(set) var isRunning = false

  init(modelContainer: ModelContainer) {
    self.modelContainer = modelContainer
    self.zoneID = CKRecordZone.ID(
      zoneName: "profile-index",
      ownerName: CKCurrentUserDefaultName
    )
  }

  // MARK: - Lifecycle

  func start() {
    guard !isRunning else { return }

    let configuration = CKSyncEngine.Configuration(
      database: CKContainer.default().privateCloudDatabase,
      stateSerialization: loadStateSerialization(),
      delegate: self
    )
    syncEngine = CKSyncEngine(configuration)
    isRunning = true
    logger.info("Started profile index sync engine")
  }

  func stop() {
    syncEngine = nil
    isRunning = false
    logger.info("Stopped profile index sync engine")
  }

  // MARK: - Pending Changes

  func addPendingSave(for profileId: UUID) {
    let recordID = CKRecord.ID(recordName: profileId.uuidString, zoneID: zoneID)
    pendingSaves.insert(recordID)
    pendingDeletions.remove(recordID)
    syncEngine?.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
  }

  func addPendingDeletion(for profileId: UUID) {
    let recordID = CKRecord.ID(recordName: profileId.uuidString, zoneID: zoneID)
    pendingDeletions.insert(recordID)
    pendingSaves.remove(recordID)
    syncEngine?.state.add(pendingRecordZoneChanges: [.deleteRecord(recordID)])
  }

  // MARK: - Applying Remote Changes

  func applyRemoteChanges(saved: [CKRecord], deleted: [CKRecord.ID]) {
    let context = ModelContext(modelContainer)

    for ckRecord in saved {
      guard ckRecord.recordType == ProfileRecord.recordType else { continue }
      guard let profileId = UUID(uuidString: ckRecord.recordID.recordName) else { continue }

      let values = ProfileRecord.fieldValues(from: ckRecord)
      let descriptor = FetchDescriptor<ProfileRecord>(
        predicate: #Predicate { $0.id == profileId }
      )
      if let existing = try? context.fetch(descriptor).first {
        existing.label = values.label
        existing.currencyCode = values.currencyCode
        existing.financialYearStartMonth = values.financialYearStartMonth
        existing.createdAt = values.createdAt
      } else {
        context.insert(values)
      }
    }

    for recordID in deleted {
      guard let profileId = UUID(uuidString: recordID.recordName) else { continue }
      let descriptor = FetchDescriptor<ProfileRecord>(
        predicate: #Predicate { $0.id == profileId }
      )
      if let existing = try? context.fetch(descriptor).first {
        context.delete(existing)
      }
    }

    do {
      try context.save()
      onRemoteChangesApplied?()
    } catch {
      logger.error("Failed to save remote profile changes: \(error)")
    }
  }

  // MARK: - State Persistence

  private var stateFileURL: URL {
    URL.applicationSupportDirectory.appending(path: "Moolah-profile-index.syncstate")
  }

  private func loadStateSerialization() -> CKSyncEngine.State.Serialization? {
    guard let data = try? Data(contentsOf: stateFileURL) else { return nil }
    return try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: data)
  }

  private func saveStateSerialization(_ serialization: CKSyncEngine.State.Serialization) {
    do {
      let data = try JSONEncoder().encode(serialization)
      try data.write(to: stateFileURL, options: .atomic)
    } catch {
      logger.error("Failed to save profile index sync state: \(error)")
    }
  }

  // MARK: - Record Lookup

  private func recordToSave(for recordID: CKRecord.ID) -> CKRecord? {
    guard let profileId = UUID(uuidString: recordID.recordName) else { return nil }
    let context = ModelContext(modelContainer)
    let descriptor = FetchDescriptor<ProfileRecord>(
      predicate: #Predicate { $0.id == profileId }
    )
    guard let record = try? context.fetch(descriptor).first else { return nil }
    return record.toCKRecord(in: zoneID)
  }
}

// MARK: - CKSyncEngineDelegate

extension ProfileIndexSyncEngine: CKSyncEngineDelegate {
  nonisolated func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
    await MainActor.run {
      handleEventOnMain(event)
    }
  }

  private func handleEventOnMain(_ event: CKSyncEngine.Event) {
    switch event {
    case .stateUpdate(let stateUpdate):
      saveStateSerialization(stateUpdate.stateSerialization)

    case .fetchedRecordZoneChanges(let changes):
      let savedRecords = changes.modifications.map(\.record)
      let deletedRecordIDs = changes.deletions.map(\.recordID)
      guard !savedRecords.isEmpty || !deletedRecordIDs.isEmpty else { return }
      applyRemoteChanges(saved: savedRecords, deleted: deletedRecordIDs)

    case .sentRecordZoneChanges(let sentChanges):
      for saved in sentChanges.savedRecords {
        pendingSaves.remove(saved.recordID)
      }
      for deleted in sentChanges.deletedRecordIDs {
        pendingDeletions.remove(deleted)
      }

    case .accountChange, .fetchedDatabaseChanges, .sentDatabaseChanges,
      .willFetchChanges, .willFetchRecordZoneChanges, .didFetchChanges,
      .didFetchRecordZoneChanges, .willSendChanges, .didSendChanges:
      break

    @unknown default:
      break
    }
  }

  nonisolated func nextRecordZoneChangeBatch(
    _ context: CKSyncEngine.SendChangesContext,
    syncEngine: CKSyncEngine
  ) async -> CKSyncEngine.RecordZoneChangeBatch? {
    await MainActor.run {
      let scope = context.options.scope
      let pendingChanges = syncEngine.state.pendingRecordZoneChanges
        .filter { scope.contains($0) }

      guard !pendingChanges.isEmpty else { return nil }

      return CKSyncEngine.RecordZoneChangeBatch(
        recordsToSave: pendingChanges.compactMap { change -> CKRecord? in
          guard case .saveRecord(let recordID) = change else { return nil }
          return self.recordToSave(for: recordID)
        },
        recordIDsToDelete: pendingChanges.compactMap { change -> CKRecord.ID? in
          guard case .deleteRecord(let recordID) = change else { return nil }
          return recordID
        },
        atomicByZone: true
      )
    }
  }
}
