import CloudKit
import Foundation
import OSLog
import SwiftData

/// Manages CKSyncEngine for a single profile's data zone.
/// Each profile gets its own CloudKit record zone (`profile-{profileId}`),
/// ensuring complete data isolation between profiles.
@MainActor
final class ProfileSyncEngine: Sendable {
  nonisolated let profileId: UUID
  nonisolated let zoneID: CKRecordZone.ID
  nonisolated let modelContainer: ModelContainer

  /// Callback invoked after remote changes are applied to the local store.
  /// Used by ProfileSession to trigger store reloads.
  var onRemoteChangesApplied: (() -> Void)?

  private nonisolated let logger = Logger(
    subsystem: "com.moolah.app", category: "ProfileSyncEngine")
  private var pendingSaves: Set<CKRecord.ID> = []
  private var pendingDeletions: Set<CKRecord.ID> = []
  private var syncEngine: CKSyncEngine?

  /// Whether the underlying CKSyncEngine has been started.
  private(set) var isRunning = false

  /// True while applying remote changes from CloudKit to local SwiftData.
  /// ChangeTracker checks this to avoid re-uploading records just received.
  private(set) var isApplyingRemoteChanges = false

  /// Tracks whether this engine started without saved state (first launch).
  /// Used to distinguish the synthetic `.signIn` event from a real one.
  private var isFirstLaunch = false

  /// Cache of CKRecord system fields (change tags) keyed by record name.
  /// Preserved across uploads to avoid `.serverRecordChanged` conflicts.
  private var systemFieldsCache: [String: Data] = [:]

  var hasPendingChanges: Bool {
    !pendingSaves.isEmpty || !pendingDeletions.isEmpty
  }

  init(profileId: UUID, modelContainer: ModelContainer) {
    self.profileId = profileId
    self.modelContainer = modelContainer
    self.zoneID = CKRecordZone.ID(
      zoneName: "profile-\(profileId.uuidString)",
      ownerName: CKCurrentUserDefaultName
    )
  }

  // MARK: - Lifecycle

  /// Starts the CKSyncEngine. Call this after the profile is fully set up.
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
    logger.info("Started sync engine for profile \(self.profileId)")

    // On first start (no saved state), queue all existing records for upload.
    // This handles the case where data was imported before the sync engine started
    // (e.g., migration imports data, then ProfileSession creates the sync engine).
    if isFirstLaunch {
      queueAllExistingRecords()
    }
  }

  /// Scans all record types in the local store and queues them for upload.
  /// Called on first start when there's no saved sync state.
  ///
  /// Note: SwiftData models don't support KVC (`value(forKey:)`), so we must
  /// use concrete FetchDescriptors per type — same constraint as `recordToSave`.
  private func queueAllExistingRecords() {
    let context = ModelContext(modelContainer)
    var total = 0

    if let records = try? context.fetch(FetchDescriptor<AccountRecord>()) {
      for r in records {
        queuePendingSave(for: r.id)
        total += 1
      }
    }
    if let records = try? context.fetch(FetchDescriptor<TransactionRecord>()) {
      for r in records {
        queuePendingSave(for: r.id)
        total += 1
      }
    }
    if let records = try? context.fetch(FetchDescriptor<CategoryRecord>()) {
      for r in records {
        queuePendingSave(for: r.id)
        total += 1
      }
    }
    if let records = try? context.fetch(FetchDescriptor<EarmarkRecord>()) {
      for r in records {
        queuePendingSave(for: r.id)
        total += 1
      }
    }
    if let records = try? context.fetch(FetchDescriptor<EarmarkBudgetItemRecord>()) {
      for r in records {
        queuePendingSave(for: r.id)
        total += 1
      }
    }
    if let records = try? context.fetch(FetchDescriptor<InvestmentValueRecord>()) {
      for r in records {
        queuePendingSave(for: r.id)
        total += 1
      }
    }

    if total > 0 {
      logger.info("Queued \(total) existing records for initial upload")
    }
  }

  private func queuePendingSave(for id: UUID) {
    let recordID = CKRecord.ID(recordName: id.uuidString, zoneID: zoneID)
    addPendingChange(.saveRecord(recordID))
  }

  /// Stops the sync engine. Call during profile deactivation or app termination.
  func stop() {
    syncEngine = nil
    isRunning = false
    logger.info("Stopped sync engine for profile \(self.profileId)")
  }

  // MARK: - Background Sync

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

  enum PendingChange {
    case saveRecord(CKRecord.ID)
    case deleteRecord(CKRecord.ID)
  }

  func addPendingChange(_ change: PendingChange) {
    switch change {
    case .saveRecord(let recordID):
      pendingSaves.insert(recordID)
      pendingDeletions.remove(recordID)
    case .deleteRecord(let recordID):
      pendingDeletions.insert(recordID)
      pendingSaves.remove(recordID)
    }

    // Tell the sync engine it has work to do
    if let syncEngine {
      switch change {
      case .saveRecord(let recordID):
        syncEngine.state.add(pendingRecordZoneChanges: [
          .saveRecord(recordID)
        ])
      case .deleteRecord(let recordID):
        syncEngine.state.add(pendingRecordZoneChanges: [
          .deleteRecord(recordID)
        ])
      }
    }
  }

  // MARK: - Building CKRecords

  /// Builds a CKRecord from a local SwiftData record for upload.
  /// If cached system fields exist for this record, uses them as the base
  /// to preserve the change tag and avoid `.serverRecordChanged` conflicts.
  func buildCKRecord<T: CloudKitRecordConvertible>(for record: T) -> CKRecord {
    let freshRecord = record.toCKRecord(in: zoneID)
    return applySystemFieldsCache(to: freshRecord)
  }

  /// If we have cached system fields for this record, creates a CKRecord from
  /// the cached data (preserving the change tag) and copies field values onto it.
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

  // MARK: - Applying Remote Changes

  /// Applies remote changes (inserts/updates/deletions) to the local SwiftData store.
  /// Called when the sync engine receives changes from CloudKit.
  func applyRemoteChanges(
    saved: [CKRecord],
    deleted: [(CKRecord.ID, String)]  // (recordID, recordType)
  ) {
    isApplyingRemoteChanges = true
    defer { isApplyingRemoteChanges = false }

    let context = ModelContext(modelContainer)

    for ckRecord in saved {
      applyRemoteSave(ckRecord, context: context)
    }

    for (recordID, recordType) in deleted {
      applyRemoteDeletion(recordID: recordID, recordType: recordType, context: context)
    }

    do {
      try context.save()
      onRemoteChangesApplied?()
    } catch {
      logger.error("Failed to save remote changes: \(error)")
    }
  }

  // MARK: - State Persistence

  private var stateFileURL: URL {
    URL.applicationSupportDirectory
      .appending(path: "Moolah-\(profileId.uuidString).syncstate")
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
      logger.error("Failed to save sync state: \(error)")
    }
  }

  private func deleteStateSerialization() {
    try? FileManager.default.removeItem(at: stateFileURL)
  }

  // MARK: - System Fields Cache

  private var systemFieldsCacheURL: URL {
    URL.applicationSupportDirectory
      .appending(path: "Moolah-\(profileId.uuidString).systemfields")
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

  /// Deletes all local records for this profile's zone.
  /// Called on account sign-out, account switch, and zone deletion.
  private func deleteLocalData() {
    let context = ModelContext(modelContainer)

    func deleteAll<T: PersistentModel>(_ type: T.Type) {
      if let records = try? context.fetch(FetchDescriptor<T>()) {
        for record in records {
          context.delete(record)
        }
      }
    }

    deleteAll(AccountRecord.self)
    deleteAll(TransactionRecord.self)
    deleteAll(CategoryRecord.self)
    deleteAll(EarmarkRecord.self)
    deleteAll(EarmarkBudgetItemRecord.self)
    deleteAll(InvestmentValueRecord.self)

    do {
      try context.save()
      logger.info("Deleted all local data for profile \(self.profileId)")
      onRemoteChangesApplied?()
    } catch {
      logger.error("Failed to delete local data: \(error)")
    }
  }

  // MARK: - Private Helpers

  private func applyRemoteSave(_ ckRecord: CKRecord, context: ModelContext) {
    let recordType = ckRecord.recordType
    let recordName = ckRecord.recordID.recordName

    guard let recordId = UUID(uuidString: recordName) else {
      logger.warning("Invalid record name (not UUID): \(recordName)")
      return
    }

    switch recordType {
    case AccountRecord.recordType:
      upsertAccount(from: ckRecord, id: recordId, context: context)
    case TransactionRecord.recordType:
      upsertTransaction(from: ckRecord, id: recordId, context: context)
    case CategoryRecord.recordType:
      upsertCategory(from: ckRecord, id: recordId, context: context)
    case EarmarkRecord.recordType:
      upsertEarmark(from: ckRecord, id: recordId, context: context)
    case EarmarkBudgetItemRecord.recordType:
      upsertEarmarkBudgetItem(from: ckRecord, id: recordId, context: context)
    case InvestmentValueRecord.recordType:
      upsertInvestmentValue(from: ckRecord, id: recordId, context: context)
    default:
      logger.warning("Unknown record type: \(recordType)")
    }
  }

  private func applyRemoteDeletion(
    recordID: CKRecord.ID, recordType: String, context: ModelContext
  ) {
    guard let recordId = UUID(uuidString: recordID.recordName) else { return }

    switch recordType {
    case AccountRecord.recordType:
      if let record = fetchAccount(id: recordId, context: context) { context.delete(record) }
    case TransactionRecord.recordType:
      if let record = fetchTransaction(id: recordId, context: context) { context.delete(record) }
    case CategoryRecord.recordType:
      if let record = fetchCategory(id: recordId, context: context) { context.delete(record) }
    case EarmarkRecord.recordType:
      if let record = fetchEarmark(id: recordId, context: context) { context.delete(record) }
    case EarmarkBudgetItemRecord.recordType:
      if let record = fetchEarmarkBudgetItem(id: recordId, context: context) {
        context.delete(record)
      }
    case InvestmentValueRecord.recordType:
      if let record = fetchInvestmentValue(id: recordId, context: context) {
        context.delete(record)
      }
    default:
      logger.warning("Unknown record type for deletion: \(recordType)")
    }
  }

  // MARK: - Upsert Helpers

  private func upsertAccount(from ckRecord: CKRecord, id: UUID, context: ModelContext) {
    let values = AccountRecord.fieldValues(from: ckRecord)
    let descriptor = FetchDescriptor<AccountRecord>(predicate: #Predicate { $0.id == id })
    if let existing = try? context.fetch(descriptor).first {
      existing.name = values.name
      existing.type = values.type
      existing.position = values.position
      existing.isHidden = values.isHidden
      existing.currencyCode = values.currencyCode
      existing.cachedBalance = values.cachedBalance
    } else {
      context.insert(values)
    }
  }

  private func upsertTransaction(from ckRecord: CKRecord, id: UUID, context: ModelContext) {
    let values = TransactionRecord.fieldValues(from: ckRecord)
    let descriptor = FetchDescriptor<TransactionRecord>(predicate: #Predicate { $0.id == id })
    if let existing = try? context.fetch(descriptor).first {
      existing.type = values.type
      existing.date = values.date
      existing.accountId = values.accountId
      existing.toAccountId = values.toAccountId
      existing.amount = values.amount
      existing.currencyCode = values.currencyCode
      existing.payee = values.payee
      existing.notes = values.notes
      existing.categoryId = values.categoryId
      existing.earmarkId = values.earmarkId
      existing.recurPeriod = values.recurPeriod
      existing.recurEvery = values.recurEvery
    } else {
      context.insert(values)
    }
  }

  private func upsertCategory(from ckRecord: CKRecord, id: UUID, context: ModelContext) {
    let values = CategoryRecord.fieldValues(from: ckRecord)
    let descriptor = FetchDescriptor<CategoryRecord>(predicate: #Predicate { $0.id == id })
    if let existing = try? context.fetch(descriptor).first {
      existing.name = values.name
      existing.parentId = values.parentId
    } else {
      context.insert(values)
    }
  }

  private func upsertEarmark(from ckRecord: CKRecord, id: UUID, context: ModelContext) {
    let values = EarmarkRecord.fieldValues(from: ckRecord)
    let descriptor = FetchDescriptor<EarmarkRecord>(predicate: #Predicate { $0.id == id })
    if let existing = try? context.fetch(descriptor).first {
      existing.name = values.name
      existing.position = values.position
      existing.isHidden = values.isHidden
      existing.savingsTarget = values.savingsTarget
      existing.currencyCode = values.currencyCode
      existing.savingsStartDate = values.savingsStartDate
      existing.savingsEndDate = values.savingsEndDate
    } else {
      context.insert(values)
    }
  }

  private func upsertEarmarkBudgetItem(from ckRecord: CKRecord, id: UUID, context: ModelContext) {
    let values = EarmarkBudgetItemRecord.fieldValues(from: ckRecord)
    let descriptor = FetchDescriptor<EarmarkBudgetItemRecord>(
      predicate: #Predicate { $0.id == id })
    if let existing = try? context.fetch(descriptor).first {
      existing.earmarkId = values.earmarkId
      existing.categoryId = values.categoryId
      existing.amount = values.amount
      existing.currencyCode = values.currencyCode
    } else {
      context.insert(values)
    }
  }

  private func upsertInvestmentValue(from ckRecord: CKRecord, id: UUID, context: ModelContext) {
    let values = InvestmentValueRecord.fieldValues(from: ckRecord)
    let descriptor = FetchDescriptor<InvestmentValueRecord>(predicate: #Predicate { $0.id == id })
    if let existing = try? context.fetch(descriptor).first {
      existing.accountId = values.accountId
      existing.date = values.date
      existing.value = values.value
      existing.currencyCode = values.currencyCode
    } else {
      context.insert(values)
    }
  }
}

// MARK: - CKSyncEngineDelegate

extension ProfileSyncEngine: CKSyncEngineDelegate {
  nonisolated func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
    await MainActor.run {
      handleEventOnMain(event, syncEngine: syncEngine)
    }
  }

  private func handleEventOnMain(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) {
    switch event {
    case .stateUpdate(let stateUpdate):
      saveStateSerialization(stateUpdate.stateSerialization)

    case .accountChange(let accountChange):
      handleAccountChange(accountChange)

    case .fetchedDatabaseChanges(let fetchedChanges):
      handleFetchedDatabaseChanges(fetchedChanges)

    case .fetchedRecordZoneChanges(let fetchedChanges):
      handleFetchedRecordZoneChanges(fetchedChanges)

    case .sentRecordZoneChanges(let sentChanges):
      handleSentRecordZoneChanges(sentChanges)

    case .sentDatabaseChanges:
      break

    case .willFetchChanges, .willFetchRecordZoneChanges, .didFetchChanges,
      .didFetchRecordZoneChanges, .willSendChanges, .didSendChanges:
      break

    @unknown default:
      logger.debug("Unknown sync engine event")
    }
  }

  nonisolated func nextRecordZoneChangeBatch(
    _ context: CKSyncEngine.SendChangesContext,
    syncEngine: CKSyncEngine
  ) async -> CKSyncEngine.RecordZoneChangeBatch? {
    await MainActor.run {
      nextRecordZoneChangeBatchOnMain(context, syncEngine: syncEngine)
    }
  }

  private func nextRecordZoneChangeBatchOnMain(
    _ context: CKSyncEngine.SendChangesContext,
    syncEngine: CKSyncEngine
  ) -> CKSyncEngine.RecordZoneChangeBatch? {
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

  // MARK: - Event Handlers

  private func handleAccountChange(_ change: CKSyncEngine.Event.AccountChange) {
    switch change.changeType {
    case .signIn:
      // CKSyncEngine fires a synthetic .signIn on first launch (no saved state).
      // Only re-upload on a real sign-in (engine had saved state from a prior session).
      if isFirstLaunch {
        logger.info("Synthetic sign-in on first launch — skipping re-upload")
        isFirstLaunch = false
      } else {
        logger.info("Account signed in — re-uploading all local data")
        queueAllExistingRecords()
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
        logger.warning("Profile zone was deleted remotely — removing local data")
        deleteLocalData()

      case .purged:
        logger.warning("Profile zone was purged (user cleared iCloud data)")
        deleteLocalData()
        deleteStateSerialization()
        deleteSystemFieldsCache()

      case .encryptedDataReset:
        logger.warning("Encrypted data reset — re-uploading local data")
        deleteStateSerialization()
        deleteSystemFieldsCache()
        queueAllExistingRecords()

      @unknown default:
        logger.warning("Unknown zone deletion reason")
      }
    }
  }

  private func handleFetchedRecordZoneChanges(
    _ changes: CKSyncEngine.Event.FetchedRecordZoneChanges
  ) {
    let savedRecords = changes.modifications.map(\.record)
    let deletedRecords: [(CKRecord.ID, String)] = changes.deletions.map {
      ($0.recordID, $0.recordType)
    }

    guard !savedRecords.isEmpty || !deletedRecords.isEmpty else { return }

    applyRemoteChanges(saved: savedRecords, deleted: deletedRecords)
  }

  private func handleSentRecordZoneChanges(
    _ sentChanges: CKSyncEngine.Event.SentRecordZoneChanges
  ) {
    // Cache system fields for successfully sent records (Rule 5).
    // This preserves the change tag for subsequent uploads.
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
    for failure in sentChanges.failedRecordSaves {
      let recordID = failure.record.recordID
      logger.error(
        "Failed to save record \(recordID.recordName): \(failure.error)")

      switch failure.error.code {
      case .zoneNotFound:
        logger.info("Zone not found — creating zone and retrying")
        Task {
          do {
            let zone = CKRecordZone(zoneID: self.zoneID)
            try await CKContainer.default().privateCloudDatabase.save(zone)
            self.logger.info("Created zone \(self.zoneID.zoneName)")
            self.syncEngine?.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
          } catch {
            self.logger.error("Failed to create zone: \(error)")
          }
        }

      case .serverRecordChanged:
        // Conflict: another device modified this record. Accept the server's
        // system fields (server-wins) and re-queue with the updated change tag.
        if let serverRecord = failure.error.serverRecord {
          systemFieldsCache[serverRecord.recordID.recordName] = serverRecord.encodedSystemFields
          saveSystemFieldsCache()
          syncEngine?.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
        }

      case .unknownItem:
        // Record was deleted on server. Clear cached system fields and re-upload.
        systemFieldsCache.removeValue(forKey: recordID.recordName)
        saveSystemFieldsCache()
        syncEngine?.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])

      case .quotaExceeded:
        // iCloud storage full. Re-queue so it can retry when space is available.
        logger.error("iCloud quota exceeded — sync paused for record \(recordID.recordName)")
        syncEngine?.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])

      case .limitExceeded:
        // Batch too large. Re-queue and the engine will retry with smaller batches.
        syncEngine?.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])

      default:
        break
      }
    }

    // Handle failed deletes
    for (recordID, error) in sentChanges.failedRecordDeletes {
      logger.error(
        "Failed to delete record \(recordID.recordName): \(error)")

      if error.code == .zoneNotFound {
        Task {
          do {
            let zone = CKRecordZone(zoneID: self.zoneID)
            try await CKContainer.default().privateCloudDatabase.save(zone)
            self.syncEngine?.state.add(pendingRecordZoneChanges: [.deleteRecord(recordID)])
          } catch {
            self.logger.error("Failed to create zone for delete retry: \(error)")
          }
        }
      }
    }
  }

  // MARK: - Record Lookup for Upload

  // Note: SwiftData's #Predicate macro does not work with generic type parameters —
  // it crashes at runtime because the keypath can't be resolved to a concrete Core Data
  // attribute. Each record type must use its own concrete FetchDescriptor.

  private func recordToSave(for recordID: CKRecord.ID) -> CKRecord? {
    guard let uuid = UUID(uuidString: recordID.recordName) else { return nil }
    let context = ModelContext(modelContainer)

    // Try each record type until we find the one with this ID.
    // buildCKRecord applies cached system fields to preserve change tags.
    if let record = fetchAccount(id: uuid, context: context) {
      return buildCKRecord(for: record)
    }
    if let record = fetchTransaction(id: uuid, context: context) {
      return buildCKRecord(for: record)
    }
    if let record = fetchCategory(id: uuid, context: context) {
      return buildCKRecord(for: record)
    }
    if let record = fetchEarmark(id: uuid, context: context) {
      return buildCKRecord(for: record)
    }
    if let record = fetchEarmarkBudgetItem(id: uuid, context: context) {
      return buildCKRecord(for: record)
    }
    if let record = fetchInvestmentValue(id: uuid, context: context) {
      return buildCKRecord(for: record)
    }

    logger.warning("Could not find local record for ID: \(recordID.recordName)")
    return nil
  }

  private func fetchAccount(id: UUID, context: ModelContext) -> AccountRecord? {
    let descriptor = FetchDescriptor<AccountRecord>(predicate: #Predicate { $0.id == id })
    return try? context.fetch(descriptor).first
  }

  private func fetchTransaction(id: UUID, context: ModelContext) -> TransactionRecord? {
    let descriptor = FetchDescriptor<TransactionRecord>(predicate: #Predicate { $0.id == id })
    return try? context.fetch(descriptor).first
  }

  private func fetchCategory(id: UUID, context: ModelContext) -> CategoryRecord? {
    let descriptor = FetchDescriptor<CategoryRecord>(predicate: #Predicate { $0.id == id })
    return try? context.fetch(descriptor).first
  }

  private func fetchEarmark(id: UUID, context: ModelContext) -> EarmarkRecord? {
    let descriptor = FetchDescriptor<EarmarkRecord>(predicate: #Predicate { $0.id == id })
    return try? context.fetch(descriptor).first
  }

  private func fetchEarmarkBudgetItem(id: UUID, context: ModelContext) -> EarmarkBudgetItemRecord? {
    let descriptor = FetchDescriptor<EarmarkBudgetItemRecord>(
      predicate: #Predicate { $0.id == id })
    return try? context.fetch(descriptor).first
  }

  private func fetchInvestmentValue(id: UUID, context: ModelContext) -> InvestmentValueRecord? {
    let descriptor = FetchDescriptor<InvestmentValueRecord>(predicate: #Predicate { $0.id == id })
    return try? context.fetch(descriptor).first
  }
}
