import CloudKit
import CoreData
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
  private nonisolated(unsafe) var saveObserver: NSObjectProtocol?
  private var isApplyingRemoteChanges = false
  private var isFirstLaunch = false
  private var systemFieldsCache: [String: Data] = [:]

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

    let savedState = loadStateSerialization()
    isFirstLaunch = savedState == nil
    let configuration = CKSyncEngine.Configuration(
      database: CKContainer.default().privateCloudDatabase,
      stateSerialization: savedState,
      delegate: self
    )
    syncEngine = CKSyncEngine(configuration)
    isRunning = true
    systemFieldsCache = loadSystemFieldsCache()
    logger.info("Started profile index sync engine")

    // On first start, queue any existing profiles for upload
    if isFirstLaunch {
      queueAllExistingProfiles()
    }
  }

  /// Queues all existing ProfileRecords for upload on first start.
  private func queueAllExistingProfiles() {
    let context = ModelContext(modelContainer)
    let descriptor = FetchDescriptor<ProfileRecord>()
    guard let records = try? context.fetch(descriptor), !records.isEmpty else { return }
    for record in records {
      addPendingSave(for: record.id)
    }
    logger.info("Queued \(records.count) existing profiles for initial upload")
  }

  func stop() {
    stopTracking()
    syncEngine = nil
    isRunning = false
    logger.info("Stopped profile index sync engine")
  }

  /// Observes local SwiftData saves on the index container and queues
  /// inserted/updated/deleted ProfileRecords for upload to CloudKit.
  func startTracking() {
    guard saveObserver == nil else { return }

    saveObserver = NotificationCenter.default.addObserver(
      forName: .NSManagedObjectContextDidSave,
      object: nil,
      queue: .main
    ) { [weak self] notification in
      // Only process changes to ProfileRecord entities — ignore per-profile data saves
      let profileEntityName = "ProfileRecord"

      let inserted = (notification.userInfo?[NSInsertedObjectsKey] as? Set<NSManagedObject>)?
        .filter { $0.entity.name == profileEntityName }
      let updated = (notification.userInfo?[NSUpdatedObjectsKey] as? Set<NSManagedObject>)?
        .filter { $0.entity.name == profileEntityName }
      let deleted = (notification.userInfo?[NSDeletedObjectsKey] as? Set<NSManagedObject>)?
        .filter { $0.entity.name == profileEntityName }

      // Note: KVC is safe here because these are NSManagedObject instances from
      // the Core Data notification, not SwiftData PersistentModel instances.
      let insertedIDs = inserted?.compactMap { $0.value(forKey: "id") as? UUID } ?? []
      let updatedIDs = updated?.compactMap { $0.value(forKey: "id") as? UUID } ?? []
      let deletedIDs = deleted?.compactMap { $0.value(forKey: "id") as? UUID } ?? []

      guard !insertedIDs.isEmpty || !updatedIDs.isEmpty || !deletedIDs.isEmpty else { return }

      MainActor.assumeIsolated {
        guard self?.isApplyingRemoteChanges != true else { return }
        self?.processLocalSave(inserted: insertedIDs, updated: updatedIDs, deleted: deletedIDs)
      }
    }
  }

  func stopTracking() {
    if let saveObserver {
      NotificationCenter.default.removeObserver(saveObserver)
    }
    saveObserver = nil
  }

  // MARK: - Background Sync

  var hasPendingChanges: Bool {
    !pendingSaves.isEmpty || !pendingDeletions.isEmpty
  }

  /// Tells CKSyncEngine to send all pending changes now.
  func sendChanges() async {
    guard let syncEngine, isRunning else { return }
    do {
      try await syncEngine.sendChanges()
    } catch {
      logger.error("Failed to send changes: \(error)")
    }
  }

  /// Tells CKSyncEngine to fetch remote changes now.
  func fetchChanges() async {
    guard let syncEngine, isRunning else { return }
    do {
      try await syncEngine.fetchChanges()
    } catch {
      logger.error("Failed to fetch changes: \(error)")
    }
  }

  // MARK: - Local Change Processing

  private func processLocalSave(inserted: [UUID], updated: [UUID], deleted: [UUID]) {
    for id in inserted {
      addPendingSave(for: id)
    }
    for id in updated {
      addPendingSave(for: id)
    }
    for id in deleted {
      addPendingDeletion(for: id)
    }
  }

  // MARK: - Pending Changes

  func addPendingSave(for profileId: UUID) {
    let recordID = CKRecord.ID(recordName: profileId.uuidString, zoneID: zoneID)
    guard pendingSaves.insert(recordID).inserted else { return }
    pendingDeletions.remove(recordID)
    syncEngine?.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
  }

  func addPendingDeletion(for profileId: UUID) {
    let recordID = CKRecord.ID(recordName: profileId.uuidString, zoneID: zoneID)
    guard pendingDeletions.insert(recordID).inserted else { return }
    pendingSaves.remove(recordID)
    syncEngine?.state.add(pendingRecordZoneChanges: [.deleteRecord(recordID)])
  }

  // MARK: - Applying Remote Changes

  func applyRemoteChanges(saved: [CKRecord], deleted: [CKRecord.ID]) {
    isApplyingRemoteChanges = true
    defer { isApplyingRemoteChanges = false }

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

  private func deleteStateSerialization() {
    try? FileManager.default.removeItem(at: stateFileURL)
  }

  // MARK: - System Fields Cache

  private var systemFieldsCacheURL: URL {
    URL.applicationSupportDirectory.appending(path: "Moolah-profile-index.systemfields")
  }

  private func loadSystemFieldsCache() -> [String: Data] {
    guard let data = try? Data(contentsOf: systemFieldsCacheURL),
      let cache = try? PropertyListDecoder().decode([String: Data].self, from: data)
    else { return [:] }
    return cache
  }

  private func saveSystemFieldsCache() {
    do {
      let data = try PropertyListEncoder().encode(systemFieldsCache)
      try data.write(to: systemFieldsCacheURL, options: .atomic)
    } catch {
      logger.error("Failed to save system fields cache: \(error)")
    }
  }

  private func deleteSystemFieldsCache() {
    systemFieldsCache = [:]
    try? FileManager.default.removeItem(at: systemFieldsCacheURL)
  }

  // MARK: - Local Data Deletion

  /// Deletes all local ProfileRecords.
  /// Called on account sign-out, account switch, and zone deletion.
  private func deleteLocalData() {
    let context = ModelContext(modelContainer)
    if let records = try? context.fetch(FetchDescriptor<ProfileRecord>()) {
      for record in records {
        context.delete(record)
      }
    }
    do {
      try context.save()
      logger.info("Deleted all local profile index data")
      onRemoteChangesApplied?()
    } catch {
      logger.error("Failed to delete local profile data: \(error)")
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
    let freshRecord = record.toCKRecord(in: zoneID)
    return applySystemFieldsCache(to: freshRecord)
  }

  private func applySystemFieldsCache(to freshRecord: CKRecord) -> CKRecord {
    let recordName = freshRecord.recordID.recordName
    guard let cachedData = systemFieldsCache[recordName],
      let cachedRecord = CKRecord.fromEncodedSystemFields(cachedData)
    else {
      return freshRecord
    }
    for key in freshRecord.allKeys() {
      cachedRecord[key] = freshRecord[key]
    }
    return cachedRecord
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

    case .accountChange(let accountChange):
      handleAccountChange(accountChange)

    case .fetchedDatabaseChanges(let changes):
      handleFetchedDatabaseChanges(changes)

    case .fetchedRecordZoneChanges(let changes):
      let savedRecords = changes.modifications.map(\.record)
      let deletedRecordIDs = changes.deletions.map(\.recordID)
      guard !savedRecords.isEmpty || !deletedRecordIDs.isEmpty else { return }
      applyRemoteChanges(saved: savedRecords, deleted: deletedRecordIDs)

    case .sentRecordZoneChanges(let sentChanges):
      handleSentRecordZoneChanges(sentChanges)

    case .sentDatabaseChanges,
      .willFetchChanges, .willFetchRecordZoneChanges, .didFetchChanges,
      .didFetchRecordZoneChanges, .willSendChanges, .didSendChanges:
      break

    @unknown default:
      break
    }
  }

  // MARK: - Event Handlers

  private func handleAccountChange(_ change: CKSyncEngine.Event.AccountChange) {
    switch change.changeType {
    case .signIn:
      if isFirstLaunch {
        logger.info("Synthetic sign-in on first launch — skipping re-upload")
        isFirstLaunch = false
      } else {
        logger.info("Account signed in — re-uploading all profiles")
        queueAllExistingProfiles()
      }

    case .signOut:
      logger.info("Account signed out — deleting local data and sync state")
      deleteLocalData()
      deleteStateSerialization()
      deleteSystemFieldsCache()

    case .switchAccounts:
      logger.info("Account switched — full reset")
      deleteLocalData()
      deleteStateSerialization()
      deleteSystemFieldsCache()

    @unknown default:
      break
    }
  }

  private func handleFetchedDatabaseChanges(
    _ changes: CKSyncEngine.Event.FetchedDatabaseChanges
  ) {
    for deletion in changes.deletions where deletion.zoneID == zoneID {
      switch deletion.reason {
      case .deleted:
        logger.warning("Profile-index zone was deleted remotely — removing local data")
        deleteLocalData()

      case .purged:
        logger.warning("Profile-index zone was purged (user cleared iCloud data)")
        deleteLocalData()
        deleteStateSerialization()
        deleteSystemFieldsCache()

      case .encryptedDataReset:
        logger.warning("Encrypted data reset — re-uploading profiles")
        deleteStateSerialization()
        deleteSystemFieldsCache()
        queueAllExistingProfiles()

      @unknown default:
        logger.warning("Unknown zone deletion reason")
      }
    }
  }

  private func handleSentRecordZoneChanges(
    _ sentChanges: CKSyncEngine.Event.SentRecordZoneChanges
  ) {
    // Cache system fields for successfully sent records (Rule 5)
    for saved in sentChanges.savedRecords {
      pendingSaves.remove(saved.recordID)
      systemFieldsCache[saved.recordID.recordName] = saved.encodedSystemFields
    }
    saveSystemFieldsCache()

    for deleted in sentChanges.deletedRecordIDs {
      pendingDeletions.remove(deleted)
      systemFieldsCache.removeValue(forKey: deleted.recordName)
    }

    // Handle failed saves with specific error recovery (Rules 3, 6, 9)
    for failed in sentChanges.failedRecordSaves {
      let recordID = failed.record.recordID
      logger.error(
        "Failed to send profile record \(recordID.recordName, privacy: .public): \(failed.error, privacy: .public)"
      )

      switch failed.error.code {
      case .zoneNotFound:
        Task {
          do {
            let zone = CKRecordZone(zoneID: self.zoneID)
            try await CKContainer.default().privateCloudDatabase.save(zone)
            self.logger.info("Created profile-index zone, retrying send")
            self.syncEngine?.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
          } catch {
            self.logger.error("Failed to create profile-index zone: \(error, privacy: .public)")
          }
        }

      case .serverRecordChanged:
        if let serverRecord = failed.error.serverRecord {
          systemFieldsCache[serverRecord.recordID.recordName] = serverRecord.encodedSystemFields
          saveSystemFieldsCache()
          syncEngine?.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
        }

      case .unknownItem:
        systemFieldsCache.removeValue(forKey: recordID.recordName)
        saveSystemFieldsCache()
        syncEngine?.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])

      case .quotaExceeded:
        logger.error("iCloud quota exceeded — sync paused for profile \(recordID.recordName)")
        syncEngine?.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])

      case .limitExceeded:
        syncEngine?.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])

      default:
        break
      }
    }

    // Handle failed deletes
    for (recordID, error) in sentChanges.failedRecordDeletes {
      logger.error(
        "Failed to delete profile record \(recordID.recordName, privacy: .public): \(error, privacy: .public)"
      )

      if error.code == .zoneNotFound {
        Task {
          do {
            let zone = CKRecordZone(zoneID: self.zoneID)
            try await CKContainer.default().privateCloudDatabase.save(zone)
            self.syncEngine?.state.add(pendingRecordZoneChanges: [.deleteRecord(recordID)])
          } catch {
            self.logger.error("Failed to create zone for delete retry: \(error, privacy: .public)")
          }
        }
      }
    }
  }

  nonisolated func nextRecordZoneChangeBatch(
    _ context: CKSyncEngine.SendChangesContext,
    syncEngine: CKSyncEngine
  ) async -> CKSyncEngine.RecordZoneChangeBatch? {
    await MainActor.run {
      let scope = context.options.scope
      var seenSaves = Set<CKRecord.ID>()
      var seenDeletes = Set<CKRecord.ID>()
      let pendingChanges = syncEngine.state.pendingRecordZoneChanges
        .filter { scope.contains($0) }
        .filter { change in
          switch change {
          case .saveRecord(let id): return seenSaves.insert(id).inserted
          case .deleteRecord(let id): return seenDeletes.insert(id).inserted
          @unknown default: return true
          }
        }

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
