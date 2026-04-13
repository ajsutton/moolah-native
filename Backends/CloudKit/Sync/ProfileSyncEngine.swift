import CloudKit
import Foundation
import OSLog
import SwiftData

/// Manages CKSyncEngine for a single profile's data zone.
/// Each profile gets its own CloudKit record zone (`profile-{profileId}`),
/// ensuring complete data isolation between profiles.
@MainActor
final class ProfileSyncEngine: Sendable {
  let profileId: UUID
  let zoneID: CKRecordZone.ID
  let modelContainer: ModelContainer

  /// Callback invoked after remote changes are applied to the local store.
  /// Used by ProfileSession to trigger store reloads.
  var onRemoteChangesApplied: (() -> Void)?

  private let logger = Logger(subsystem: "com.moolah.app", category: "ProfileSyncEngine")
  private var pendingSaves: Set<CKRecord.ID> = []
  private var pendingDeletions: Set<CKRecord.ID> = []
  private var syncEngine: CKSyncEngine?

  /// Whether the underlying CKSyncEngine has been started.
  private(set) var isRunning = false

  /// True while applying remote changes from CloudKit to local SwiftData.
  /// ChangeTracker checks this to avoid re-uploading records just received.
  private(set) var isApplyingRemoteChanges = false

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

    let configuration = CKSyncEngine.Configuration(
      database: CKContainer.default().privateCloudDatabase,
      stateSerialization: loadStateSerialization(),
      delegate: self
    )
    syncEngine = CKSyncEngine(configuration)
    isRunning = true
    logger.info("Started sync engine for profile \(self.profileId)")
  }

  /// Stops the sync engine. Call during profile deactivation or app termination.
  func stop() {
    syncEngine = nil
    isRunning = false
    logger.info("Stopped sync engine for profile \(self.profileId)")
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
  func buildCKRecord<T: CloudKitRecordConvertible>(for record: T) -> CKRecord {
    record.toCKRecord(in: zoneID)
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
    case .signIn, .switchAccounts:
      logger.info("Account changed, will re-sync")
    case .signOut:
      logger.info("Account signed out")
    @unknown default:
      break
    }
  }

  private func handleFetchedDatabaseChanges(
    _ changes: CKSyncEngine.Event.FetchedDatabaseChanges
  ) {
    for deletion in changes.deletions where deletion.zoneID == zoneID {
      logger.warning("Profile zone was deleted remotely")
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
    // Remove successfully sent records from pending
    for saved in sentChanges.savedRecords {
      pendingSaves.remove(saved.recordID)
    }
    for deleted in sentChanges.deletedRecordIDs {
      pendingDeletions.remove(deleted)
    }

    // Handle failures
    for failure in sentChanges.failedRecordSaves {
      logger.error(
        "Failed to save record \(failure.record.recordID.recordName): \(failure.error)")

      // If the zone doesn't exist yet, create it and re-queue the record
      if failure.error.code == .zoneNotFound {
        logger.info("Zone not found — creating zone and retrying")
        let recordID = failure.record.recordID
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
      }
    }
    for (recordID, error) in sentChanges.failedRecordDeletes {
      logger.error(
        "Failed to delete record \(recordID.recordName): \(error)")
    }
  }

  // MARK: - Record Lookup for Upload

  // Note: SwiftData's #Predicate macro does not work with generic type parameters —
  // it crashes at runtime because the keypath can't be resolved to a concrete Core Data
  // attribute. Each record type must use its own concrete FetchDescriptor.

  private func recordToSave(for recordID: CKRecord.ID) -> CKRecord? {
    guard let uuid = UUID(uuidString: recordID.recordName) else { return nil }
    let context = ModelContext(modelContainer)

    // Try each record type until we find the one with this ID
    if let record = fetchAccount(id: uuid, context: context) {
      return record.toCKRecord(in: zoneID)
    }
    if let record = fetchTransaction(id: uuid, context: context) {
      return record.toCKRecord(in: zoneID)
    }
    if let record = fetchCategory(id: uuid, context: context) {
      return record.toCKRecord(in: zoneID)
    }
    if let record = fetchEarmark(id: uuid, context: context) {
      return record.toCKRecord(in: zoneID)
    }
    if let record = fetchEarmarkBudgetItem(id: uuid, context: context) {
      return record.toCKRecord(in: zoneID)
    }
    if let record = fetchInvestmentValue(id: uuid, context: context) {
      return record.toCKRecord(in: zoneID)
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
