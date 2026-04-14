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
  private var syncEngine: CKSyncEngine?
  private(set) var isRunning = false
  private var isApplyingRemoteChanges = false
  private var isFirstLaunch = false

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
    // Clean up legacy system fields cache file (now stored on model records)
    let legacyCacheURL = URL.applicationSupportDirectory
      .appending(path: "Moolah-profile-index.systemfields")
    try? FileManager.default.removeItem(at: legacyCacheURL)
    logger.info("Started profile index sync engine")

    // On first start, queue any existing profiles for upload
    if isFirstLaunch {
      queueAllExistingProfiles()
    }

    // Ensure the zone exists, then trigger a send.
    // CKSyncEngine does not create zones automatically. If it attempts to send
    // before the zone exists, records fail with invalidArguments/zoneNotFound
    // and the engine stops retrying. After zone creation, we explicitly send
    // to flush any pending records.
    Task {
      await ensureZoneExists()
      if self.hasPendingChanges {
        self.logger.info("Zone ready — sending pending changes")
        await self.sendChanges()
      }
    }
  }

  private func ensureZoneExists() async {
    do {
      let zone = CKRecordZone(zoneID: zoneID)
      _ = try await CKContainer.default().privateCloudDatabase.save(zone)
      logger.info("Ensured zone exists: \(self.zoneID.zoneName)")
    } catch {
      logger.error("Failed to ensure zone exists: \(error)")
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
    syncEngine = nil
    isRunning = false
    logger.info("Stopped profile index sync engine")
  }

  // MARK: - Background Sync

  var hasPendingChanges: Bool {
    syncEngine.map { !$0.state.pendingRecordZoneChanges.isEmpty } ?? false
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

  // MARK: - Pending Changes

  func addPendingSave(for profileId: UUID) {
    let recordID = CKRecord.ID(recordName: profileId.uuidString, zoneID: zoneID)
    syncEngine?.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
  }

  func addPendingDeletion(for profileId: UUID) {
    let recordID = CKRecord.ID(recordName: profileId.uuidString, zoneID: zoneID)
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

      let systemFieldsData = ckRecord.encodedSystemFields
      let values = ProfileRecord.fieldValues(from: ckRecord)
      let descriptor = FetchDescriptor<ProfileRecord>(
        predicate: #Predicate { $0.id == profileId }
      )
      if let existing = try? context.fetch(descriptor).first {
        existing.label = values.label
        existing.currencyCode = values.currencyCode
        existing.financialYearStartMonth = values.financialYearStartMonth
        existing.createdAt = values.createdAt
        existing.encodedSystemFields = systemFieldsData
      } else {
        values.encodedSystemFields = systemFieldsData
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

  // MARK: - System Fields Management

  /// Clears encoded system fields on all ProfileRecords.
  /// Called on encrypted data reset where we keep data but must re-upload fresh.
  private func clearAllSystemFields() {
    let context = ModelContext(modelContainer)
    if let records = try? context.fetch(FetchDescriptor<ProfileRecord>()) {
      for record in records {
        record.encodedSystemFields = nil
      }
      try? context.save()
    }
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
    return buildCKRecord(for: record)
  }

  /// Builds a CKRecord from a local ProfileRecord for upload.
  /// If cached system fields exist on the model, applies fields directly onto the
  /// cached record to preserve the change tag and avoid `.serverRecordChanged` conflicts.
  private func buildCKRecord(for record: ProfileRecord) -> CKRecord {
    let freshRecord = record.toCKRecord(in: zoneID)
    if let cachedData = record.encodedSystemFields,
      let cachedRecord = CKRecord.fromEncodedSystemFields(cachedData)
    {
      for key in freshRecord.allKeys() {
        cachedRecord[key] = freshRecord[key]
      }
      return cachedRecord
    }
    return freshRecord
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

    case .switchAccounts:
      logger.info("Account switched — full reset")
      deleteLocalData()
      deleteStateSerialization()

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

      case .encryptedDataReset:
        logger.warning("Encrypted data reset — re-uploading profiles")
        deleteStateSerialization()
        clearAllSystemFields()
        queueAllExistingProfiles()

      @unknown default:
        logger.warning("Unknown zone deletion reason")
      }
    }
  }

  private func handleSentRecordZoneChanges(
    _ sentChanges: CKSyncEngine.Event.SentRecordZoneChanges
  ) {
    // Update system fields on model records after successful upload.
    // This preserves the change tag for subsequent uploads.
    if !sentChanges.savedRecords.isEmpty {
      let context = ModelContext(modelContainer)
      for saved in sentChanges.savedRecords {
        updateEncodedSystemFields(
          saved.recordID, data: saved.encodedSystemFields, context: context)
      }
      try? context.save()
    }

    // Classify and recover from failed saves/deletes
    let failures = SyncErrorRecovery.classify(sentChanges, logger: logger)

    // Update system fields from server records on conflict, clear on unknownItem
    if !failures.conflicts.isEmpty || !failures.unknownItems.isEmpty {
      let context = ModelContext(modelContainer)
      for (_, serverRecord) in failures.conflicts {
        updateEncodedSystemFields(
          serverRecord.recordID, data: serverRecord.encodedSystemFields, context: context)
      }
      for (recordID, _) in failures.unknownItems {
        clearEncodedSystemFields(recordID, context: context)
      }
      try? context.save()
    }

    SyncErrorRecovery.recover(
      failures, syncEngine: syncEngine, zoneID: zoneID, logger: logger)
  }

  /// Updates `encodedSystemFields` on the ProfileRecord matching the given record ID.
  private func updateEncodedSystemFields(
    _ recordID: CKRecord.ID, data: Data, context: ModelContext
  ) {
    guard let profileId = UUID(uuidString: recordID.recordName) else { return }
    let descriptor = FetchDescriptor<ProfileRecord>(
      predicate: #Predicate { $0.id == profileId }
    )
    if let record = try? context.fetch(descriptor).first {
      record.encodedSystemFields = data
    }
  }

  /// Clears `encodedSystemFields` on the ProfileRecord matching the given record ID.
  /// Called on `.unknownItem` — the server deleted the record, so the stale change tag
  /// must be cleared so the next upload creates a fresh record.
  private func clearEncodedSystemFields(
    _ recordID: CKRecord.ID, context: ModelContext
  ) {
    guard let profileId = UUID(uuidString: recordID.recordName) else { return }
    let descriptor = FetchDescriptor<ProfileRecord>(
      predicate: #Predicate { $0.id == profileId }
    )
    if let record = try? context.fetch(descriptor).first {
      record.encodedSystemFields = nil
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

      let batchLimit = 400
      let batch = Array(pendingChanges.prefix(batchLimit))

      return CKSyncEngine.RecordZoneChangeBatch(
        recordsToSave: batch.compactMap { change -> CKRecord? in
          guard case .saveRecord(let recordID) = change else { return nil }
          return self.recordToSave(for: recordID)
        },
        recordIDsToDelete: batch.compactMap { change -> CKRecord.ID? in
          guard case .deleteRecord(let recordID) = change else { return nil }
          return recordID
        },
        atomicByZone: true
      )
    }
  }
}
