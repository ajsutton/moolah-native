@preconcurrency import CloudKit
import Foundation
import OSLog
import SwiftData
import os

/// Manages CKSyncEngine for a single profile's data zone.
/// Each profile gets its own CloudKit record zone (`profile-{profileId}`),
/// ensuring complete data isolation between profiles.
@MainActor
final class ProfileSyncEngine: Sendable {
  nonisolated let profileId: UUID
  nonisolated let zoneID: CKRecordZone.ID
  nonisolated let modelContainer: ModelContainer

  /// Callback invoked after remote changes are applied to the local store.
  /// Used by ProfileSession to trigger selective store reloads.
  /// The argument is the set of changed CloudKit record types.
  var onRemoteChangesApplied: ((Set<String>) -> Void)?

  private nonisolated let logger = Logger(
    subsystem: "com.moolah.app", category: "ProfileSyncEngine")
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

  /// Debounce task for writing the system fields cache to disk.
  /// Coalesces rapid successive writes into a single disk operation.
  private var systemFieldsSaveTask: Task<Void, Never>?

  var hasPendingChanges: Bool {
    syncEngine.map { !$0.state.pendingRecordZoneChanges.isEmpty } ?? false
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
  /// Zone creation is async — the engine starts immediately but records won't
  /// send successfully until the zone exists. On first launch this is fine because
  /// `queueAllExistingRecords` runs synchronously and the zone creation completes
  /// before CKSyncEngine schedules its first send.
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
      logger.info("First launch — scanning for existing records to queue")
      queueAllExistingRecords()
    } else {
      logger.info(
        "Resuming with saved state — \(self.syncEngine?.state.pendingRecordZoneChanges.count ?? 0) pending changes"
      )
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

  /// Scans all record types in the local store and queues them for upload.
  /// Called on first start when there's no saved sync state.
  ///
  /// Note: SwiftData models don't support KVC (`value(forKey:)`), so we must
  /// use concrete FetchDescriptors per type — same constraint as `recordToSave`.
  private func queueAllExistingRecords() {
    let signpostID = OSSignpostID(log: Signposts.sync)
    os_signpost(
      .begin, log: Signposts.sync, name: "queueAllExistingRecords", signpostID: signpostID)
    defer {
      os_signpost(
        .end, log: Signposts.sync, name: "queueAllExistingRecords", signpostID: signpostID)
    }
    let context = ModelContext(modelContainer)
    var total = 0

    // Queue in dependency order (matches migration import order):
    // 1. Categories (no dependencies)
    // 2. Accounts (no dependencies)
    // 3. Earmarks (no dependencies)
    // 4. Budget items (reference earmarks + categories)
    // 5. Investment values (reference accounts)
    // 6. Transactions last (reference accounts, categories, earmarks)
    if let records = try? context.fetch(FetchDescriptor<CategoryRecord>()) {
      for r in records {
        queuePendingSave(for: r.id)
        total += 1
      }
    }
    if let records = try? context.fetch(FetchDescriptor<AccountRecord>()) {
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
    if let records = try? context.fetch(FetchDescriptor<TransactionRecord>()) {
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
    queueSave(id: id)
  }

  /// Creates the CloudKit record zone if it doesn't already exist.
  private func ensureZoneExists() async {
    do {
      let zone = CKRecordZone(zoneID: zoneID)
      _ = try await CKContainer.default().privateCloudDatabase.save(zone)
      logger.info("Ensured zone exists: \(self.zoneID.zoneName)")
    } catch let error as CKError where error.code == .serverRecordChanged {
      // Zone already exists — this is fine
      logger.info("Zone already exists: \(self.zoneID.zoneName)")
    } catch {
      logger.error("Failed to ensure zone exists: \(error)")
    }
  }

  /// Stops the sync engine. Call during profile deactivation or app termination.
  func stop() {
    systemFieldsSaveTask?.cancel()
    flushSystemFieldsCache()
    syncEngine = nil
    isRunning = false
    logger.info("Stopped sync engine for profile \(self.profileId)")
  }

  // MARK: - Background Sync

  /// Tells CKSyncEngine to send all pending changes now.
  func sendChanges() async {
    let signpostID = OSSignpostID(log: Signposts.sync)
    os_signpost(.begin, log: Signposts.sync, name: "sendChanges", signpostID: signpostID)
    defer { os_signpost(.end, log: Signposts.sync, name: "sendChanges", signpostID: signpostID) }
    guard let syncEngine, isRunning else { return }
    do {
      try await syncEngine.sendChanges()
    } catch {
      logger.error("Failed to send changes: \(error)")
    }
  }

  /// Tells CKSyncEngine to fetch remote changes now.
  func fetchChanges() async {
    let signpostID = OSSignpostID(log: Signposts.sync)
    os_signpost(.begin, log: Signposts.sync, name: "fetchChanges", signpostID: signpostID)
    defer { os_signpost(.end, log: Signposts.sync, name: "fetchChanges", signpostID: signpostID) }
    guard let syncEngine, isRunning else { return }
    do {
      try await syncEngine.fetchChanges()
    } catch {
      logger.error("Failed to fetch changes: \(error)")
    }
  }

  // MARK: - Pending Changes

  /// Queues a record for upload to CloudKit.
  /// CKSyncEngine's pending list may accumulate duplicates; these are
  /// deduplicated in `nextRecordZoneChangeBatch` before sending.
  func queueSave(id: UUID) {
    let recordID = CKRecord.ID(recordName: id.uuidString, zoneID: zoneID)
    syncEngine?.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
  }

  /// Queues a record for deletion from CloudKit.
  func queueDeletion(id: UUID) {
    let recordID = CKRecord.ID(recordName: id.uuidString, zoneID: zoneID)
    syncEngine?.state.add(pendingRecordZoneChanges: [.deleteRecord(recordID)])
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
    deleted: [(CKRecord.ID, String)],  // (recordID, recordType)
    preExtractedSystemFields: [(String, Data)]? = nil
  ) {
    let signpostID = OSSignpostID(log: Signposts.sync)
    os_signpost(
      .begin, log: Signposts.sync, name: "applyRemoteChanges", signpostID: signpostID,
      "%{public}d saves, %{public}d deletes", saved.count, deleted.count)
    defer {
      os_signpost(.end, log: Signposts.sync, name: "applyRemoteChanges", signpostID: signpostID)
    }

    isApplyingRemoteChanges = true
    defer { isApplyingRemoteChanges = false }

    let typeCounts = Dictionary(grouping: saved, by: { $0.recordType })
      .mapValues(\.count)
    logger.info("applyRemoteChanges: \(saved.count) saves \(typeCounts), \(deleted.count) deletes")

    // Cache system fields from received records so that if the ChangeTracker
    // later re-queues them for upload (e.g. after recomputeAllBalances updates
    // cachedBalance), the upload uses the correct change tag instead of creating
    // a new server record.
    // Use pre-extracted system fields (computed off MainActor) if available.
    if let preExtracted = preExtractedSystemFields {
      for (recordName, data) in preExtracted {
        systemFieldsCache[recordName] = data
      }
    } else {
      for ckRecord in saved {
        systemFieldsCache[ckRecord.recordID.recordName] = ckRecord.encodedSystemFields
      }
    }
    saveSystemFieldsCache()

    let context = modelContainer.mainContext

    os_signpost(
      .begin, log: Signposts.sync, name: "applyBatchSaves", signpostID: signpostID,
      "%{public}d records", saved.count)
    Self.applyBatchSaves(saved, context: context)
    os_signpost(.end, log: Signposts.sync, name: "applyBatchSaves", signpostID: signpostID)

    os_signpost(
      .begin, log: Signposts.sync, name: "applyBatchDeletions", signpostID: signpostID,
      "%{public}d records", deleted.count)
    Self.applyBatchDeletions(deleted, context: context)
    os_signpost(.end, log: Signposts.sync, name: "applyBatchDeletions", signpostID: signpostID)

    // Invalidate cached balances when transactions arrive from other devices.
    // The local cache is stale — it will be recomputed on next fetchAll().
    let hasTransactionChanges =
      saved.contains { $0.recordType == TransactionRecord.recordType }
      || deleted.contains { $0.1 == TransactionRecord.recordType }
    if hasTransactionChanges {
      os_signpost(
        .begin, log: Signposts.balance, name: "invalidateCachedBalances", signpostID: signpostID)
      let affectedAccountIds = Self.extractAffectedAccountIds(saved: saved, deleted: deleted)
      Self.invalidateCachedBalances(accountIds: affectedAccountIds, context: context)
      os_signpost(
        .end, log: Signposts.balance, name: "invalidateCachedBalances", signpostID: signpostID)
    }

    do {
      os_signpost(.begin, log: Signposts.sync, name: "contextSave", signpostID: signpostID)
      try context.save()
      os_signpost(.end, log: Signposts.sync, name: "contextSave", signpostID: signpostID)
      let changedTypes = Set(saved.map(\.recordType) + deleted.map(\.1))
      onRemoteChangesApplied?(changedTypes)
    } catch {
      os_signpost(.end, log: Signposts.sync, name: "contextSave", signpostID: signpostID)
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
    systemFieldsSaveTask?.cancel()
    systemFieldsSaveTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(1))
      guard !Task.isCancelled, let self else { return }
      self.flushSystemFieldsCache()
    }
  }

  private func flushSystemFieldsCache() {
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
      onRemoteChangesApplied?(
        Set([
          AccountRecord.recordType, TransactionRecord.recordType,
          CategoryRecord.recordType, EarmarkRecord.recordType,
          EarmarkBudgetItemRecord.recordType, InvestmentValueRecord.recordType,
        ]))
    } catch {
      logger.error("Failed to delete local data: \(error)")
    }
  }

  // MARK: - Batch Processing (Static)

  private nonisolated static let batchLogger = Logger(
    subsystem: "com.moolah.app", category: "ProfileSyncEngine")

  /// Groups saved records by type and batch-upserts each group.
  /// Uses one fetch per record type instead of one fetch per record.
  private nonisolated static func applyBatchSaves(_ records: [CKRecord], context: ModelContext) {
    let grouped = Dictionary(grouping: records, by: { $0.recordType })
    for (recordType, ckRecords) in grouped {
      switch recordType {
      case AccountRecord.recordType:
        batchUpsertAccounts(ckRecords, context: context)
      case TransactionRecord.recordType:
        batchUpsertTransactions(ckRecords, context: context)
      case CategoryRecord.recordType:
        batchUpsertCategories(ckRecords, context: context)
      case EarmarkRecord.recordType:
        batchUpsertEarmarks(ckRecords, context: context)
      case EarmarkBudgetItemRecord.recordType:
        batchUpsertEarmarkBudgetItems(ckRecords, context: context)
      case InvestmentValueRecord.recordType:
        batchUpsertInvestmentValues(ckRecords, context: context)
      default:
        batchLogger.warning("applyBatchSaves: unknown record type '\(recordType)' — skipping")
      }
    }
  }

  /// Handles batch deletions. Groups by record type and issues one fetch per type.
  private nonisolated static func applyBatchDeletions(
    _ deletions: [(CKRecord.ID, String)], context: ModelContext
  ) {
    var grouped: [String: [UUID]] = [:]
    for (recordID, recordType) in deletions {
      guard let uuid = UUID(uuidString: recordID.recordName) else { continue }
      grouped[recordType, default: []].append(uuid)
    }

    for (recordType, ids) in grouped {
      switch recordType {
      case AccountRecord.recordType:
        let records =
          (try? context.fetch(
            FetchDescriptor<AccountRecord>(predicate: #Predicate { ids.contains($0.id) })
          )) ?? []
        for record in records { context.delete(record) }
      case TransactionRecord.recordType:
        let records =
          (try? context.fetch(
            FetchDescriptor<TransactionRecord>(predicate: #Predicate { ids.contains($0.id) })
          )) ?? []
        for record in records { context.delete(record) }
      case CategoryRecord.recordType:
        let records =
          (try? context.fetch(
            FetchDescriptor<CategoryRecord>(predicate: #Predicate { ids.contains($0.id) })
          )) ?? []
        for record in records { context.delete(record) }
      case EarmarkRecord.recordType:
        let records =
          (try? context.fetch(
            FetchDescriptor<EarmarkRecord>(predicate: #Predicate { ids.contains($0.id) })
          )) ?? []
        for record in records { context.delete(record) }
      case EarmarkBudgetItemRecord.recordType:
        let records =
          (try? context.fetch(
            FetchDescriptor<EarmarkBudgetItemRecord>(predicate: #Predicate { ids.contains($0.id) })
          )) ?? []
        for record in records { context.delete(record) }
      case InvestmentValueRecord.recordType:
        let records =
          (try? context.fetch(
            FetchDescriptor<InvestmentValueRecord>(predicate: #Predicate { ids.contains($0.id) })
          )) ?? []
        for record in records { context.delete(record) }
      default:
        batchLogger.warning(
          "applyBatchDeletions: unknown record type '\(recordType)' — skipping")
      }
    }
  }

  // MARK: - Balance Cache Invalidation

  /// Extracts the set of account IDs referenced by transaction CKRecords.
  /// Returns an empty set when deletions are present (meaning: invalidate all accounts).
  private nonisolated static func extractAffectedAccountIds(
    saved: [CKRecord],
    deleted: [(CKRecord.ID, String)]
  ) -> Set<UUID> {
    var ids = Set<UUID>()
    for ckRecord in saved where ckRecord.recordType == TransactionRecord.recordType {
      if let s = ckRecord["accountId"] as? String, let id = UUID(uuidString: s) {
        ids.insert(id)
      }
      if let s = ckRecord["toAccountId"] as? String, let id = UUID(uuidString: s) {
        ids.insert(id)
      }
    }
    // For deletions we don't have the record content, so invalidate all
    if deleted.contains(where: { $0.1 == TransactionRecord.recordType }) {
      return []  // Empty set = invalidate all
    }
    return ids
  }

  /// Sets cachedBalance to nil on the specified accounts so it will be recomputed on next load.
  /// Pass an empty set to invalidate all accounts (deletion case).
  /// Called when remote transaction changes arrive that may affect balances.
  nonisolated private static func invalidateCachedBalances(
    accountIds: Set<UUID>, context: ModelContext
  ) {
    if accountIds.isEmpty {
      // Invalidate all — deletion case
      guard let accounts = try? context.fetch(FetchDescriptor<AccountRecord>()) else { return }
      for account in accounts { account.cachedBalance = nil }
    } else {
      let ids = Array(accountIds)
      guard
        let accounts = try? context.fetch(
          FetchDescriptor<AccountRecord>(predicate: #Predicate { ids.contains($0.id) })
        )
      else { return }
      for account in accounts { account.cachedBalance = nil }
    }
  }

  // MARK: - Per-Type Batch Upsert

  nonisolated private static func batchUpsertAccounts(
    _ ckRecords: [CKRecord], context: ModelContext
  ) {
    let pairs: [(UUID, CKRecord)] = ckRecords.compactMap { ck in
      guard let id = UUID(uuidString: ck.recordID.recordName) else { return nil }
      return (id, ck)
    }
    let incomingIds = pairs.map(\.0)
    let existing: [AccountRecord]
    do {
      existing = try context.fetch(
        FetchDescriptor<AccountRecord>(predicate: #Predicate { incomingIds.contains($0.id) }))
    } catch {
      batchLogger.error("batchUpsertAccounts: fetch failed: \(error)")
      existing = []
    }
    // Use a mutable dictionary so inserts within this batch are also tracked.
    // Without this, duplicate UUIDs in the same incoming batch would all be inserted.
    var byID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
    var insertCount = 0
    var updateCount = 0

    for (id, ckRecord) in pairs {
      let values = AccountRecord.fieldValues(from: ckRecord)
      if let existing = byID[id] {
        existing.name = values.name
        existing.type = values.type
        existing.position = values.position
        existing.isHidden = values.isHidden
        existing.currencyCode = values.currencyCode
        // cachedBalance NOT updated from sync — computed locally from transactions
        updateCount += 1
      } else {
        context.insert(values)
        byID[id] = values
        insertCount += 1
      }
    }
    batchLogger.info(
      "batchUpsertAccounts: \(pairs.count) incoming, \(existing.count) matched, \(insertCount) inserted, \(updateCount) updated"
    )
  }

  nonisolated private static func batchUpsertTransactions(
    _ ckRecords: [CKRecord], context: ModelContext
  ) {
    let pairs: [(UUID, CKRecord)] = ckRecords.compactMap { ck in
      guard let id = UUID(uuidString: ck.recordID.recordName) else { return nil }
      return (id, ck)
    }
    let incomingIds = pairs.map(\.0)
    let existing =
      (try? context.fetch(
        FetchDescriptor<TransactionRecord>(predicate: #Predicate { incomingIds.contains($0.id) })))
      ?? []
    var byID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })

    for (id, ckRecord) in pairs {
      let values = TransactionRecord.fieldValues(from: ckRecord)
      if let existing = byID[id] {
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
        byID[id] = values
      }
    }
  }

  nonisolated private static func batchUpsertCategories(
    _ ckRecords: [CKRecord], context: ModelContext
  ) {
    let pairs: [(UUID, CKRecord)] = ckRecords.compactMap { ck in
      guard let id = UUID(uuidString: ck.recordID.recordName) else { return nil }
      return (id, ck)
    }
    let incomingIds = pairs.map(\.0)
    let existing =
      (try? context.fetch(
        FetchDescriptor<CategoryRecord>(predicate: #Predicate { incomingIds.contains($0.id) })))
      ?? []
    var byID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })

    for (id, ckRecord) in pairs {
      let values = CategoryRecord.fieldValues(from: ckRecord)
      if let existing = byID[id] {
        existing.name = values.name
        existing.parentId = values.parentId
      } else {
        context.insert(values)
        byID[id] = values
      }
    }
  }

  nonisolated private static func batchUpsertEarmarks(
    _ ckRecords: [CKRecord], context: ModelContext
  ) {
    let pairs: [(UUID, CKRecord)] = ckRecords.compactMap { ck in
      guard let id = UUID(uuidString: ck.recordID.recordName) else { return nil }
      return (id, ck)
    }
    let incomingIds = pairs.map(\.0)
    let existing =
      (try? context.fetch(
        FetchDescriptor<EarmarkRecord>(predicate: #Predicate { incomingIds.contains($0.id) })))
      ?? []
    var byID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })

    for (id, ckRecord) in pairs {
      let values = EarmarkRecord.fieldValues(from: ckRecord)
      if let existing = byID[id] {
        existing.name = values.name
        existing.position = values.position
        existing.isHidden = values.isHidden
        existing.savingsTarget = values.savingsTarget
        existing.currencyCode = values.currencyCode
        existing.savingsStartDate = values.savingsStartDate
        existing.savingsEndDate = values.savingsEndDate
      } else {
        context.insert(values)
        byID[id] = values
      }
    }
  }

  nonisolated private static func batchUpsertEarmarkBudgetItems(
    _ ckRecords: [CKRecord], context: ModelContext
  ) {
    let pairs: [(UUID, CKRecord)] = ckRecords.compactMap { ck in
      guard let id = UUID(uuidString: ck.recordID.recordName) else { return nil }
      return (id, ck)
    }
    let incomingIds = pairs.map(\.0)
    let existing =
      (try? context.fetch(
        FetchDescriptor<EarmarkBudgetItemRecord>(
          predicate: #Predicate { incomingIds.contains($0.id) }))) ?? []
    var byID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })

    for (id, ckRecord) in pairs {
      let values = EarmarkBudgetItemRecord.fieldValues(from: ckRecord)
      if let existing = byID[id] {
        existing.earmarkId = values.earmarkId
        existing.categoryId = values.categoryId
        existing.amount = values.amount
        existing.currencyCode = values.currencyCode
      } else {
        context.insert(values)
        byID[id] = values
      }
    }
  }

  nonisolated private static func batchUpsertInvestmentValues(
    _ ckRecords: [CKRecord], context: ModelContext
  ) {
    let pairs: [(UUID, CKRecord)] = ckRecords.compactMap { ck in
      guard let id = UUID(uuidString: ck.recordID.recordName) else { return nil }
      return (id, ck)
    }
    let incomingIds = pairs.map(\.0)
    let existing =
      (try? context.fetch(
        FetchDescriptor<InvestmentValueRecord>(
          predicate: #Predicate { incomingIds.contains($0.id) }))) ?? []
    var byID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })

    for (id, ckRecord) in pairs {
      let values = InvestmentValueRecord.fieldValues(from: ckRecord)
      if let existing = byID[id] {
        existing.accountId = values.accountId
        existing.date = values.date
        existing.value = values.value
        existing.currencyCode = values.currencyCode
      } else {
        context.insert(values)
        byID[id] = values
      }
    }
  }
}

// MARK: - CKSyncEngineDelegate

extension ProfileSyncEngine: CKSyncEngineDelegate {
  nonisolated func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
    // Pre-extract system fields off MainActor (NSKeyedArchiver is expensive)
    let preExtracted: [(String, Data)]?
    if case .fetchedRecordZoneChanges(let changes) = event {
      preExtracted = changes.modifications.map { mod in
        (mod.record.recordID.recordName, mod.record.encodedSystemFields)
      }
    } else {
      preExtracted = nil
    }

    await MainActor.run {
      handleEventOnMain(event, syncEngine: syncEngine, preExtractedSystemFields: preExtracted)
    }
  }

  private func handleEventOnMain(
    _ event: CKSyncEngine.Event,
    syncEngine: CKSyncEngine,
    preExtractedSystemFields: [(String, Data)]? = nil
  ) {
    switch event {
    case .stateUpdate(let stateUpdate):
      saveStateSerialization(stateUpdate.stateSerialization)

    case .accountChange(let accountChange):
      handleAccountChange(accountChange)

    case .fetchedDatabaseChanges(let fetchedChanges):
      handleFetchedDatabaseChanges(fetchedChanges)

    case .fetchedRecordZoneChanges(let changes):
      let saved = changes.modifications.map(\.record)
      let deleted: [(CKRecord.ID, String)] = changes.deletions.map {
        ($0.recordID, $0.recordType)
      }
      guard !saved.isEmpty || !deleted.isEmpty else { break }
      applyRemoteChanges(
        saved: saved,
        deleted: deleted,
        preExtractedSystemFields: preExtractedSystemFields
      )

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
    let signpostID = OSSignpostID(log: Signposts.sync)
    os_signpost(
      .begin, log: Signposts.sync, name: "nextRecordZoneChangeBatch", signpostID: signpostID)
    defer {
      os_signpost(
        .end, log: Signposts.sync, name: "nextRecordZoneChangeBatch", signpostID: signpostID)
    }
    let scope = context.options.scope
    // CKSyncEngine's pending list can contain duplicate recordIDs if the same
    // record was queued multiple times (e.g. queueAllExistingRecords + repository mutation).
    // Deduplicate by recordID to avoid creating duplicate server records.
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

    // CloudKit limits batches to ~400 records. CKSyncEngine calls this method
    // repeatedly until we return nil, so we process a chunk each time.
    let batchLimit = 400
    let batch = Array(pendingChanges.prefix(batchLimit))

    // Collect UUIDs that need saving so we can batch-load records
    let saveRecordIDs: [(CKRecord.ID, UUID)] = batch.compactMap { change in
      guard case .saveRecord(let recordID) = change,
        let uuid = UUID(uuidString: recordID.recordName)
      else { return nil }
      return (recordID, uuid)
    }

    // Batch-load records by type (6 fetches total, not N*6)
    os_signpost(
      .begin, log: Signposts.sync, name: "buildBatchRecordLookup", signpostID: signpostID,
      "%{public}d UUIDs", saveRecordIDs.count)
    let recordLookup = buildBatchRecordLookup(for: Set(saveRecordIDs.map(\.1)))
    os_signpost(.end, log: Signposts.sync, name: "buildBatchRecordLookup", signpostID: signpostID)

    logger.info(
      "Preparing batch: \(batch.count) changes (\(saveRecordIDs.count) saves), \(pendingChanges.count) total pending"
    )

    return CKSyncEngine.RecordZoneChangeBatch(
      recordsToSave: saveRecordIDs.compactMap { recordID, uuid in
        recordLookup[uuid]
      },
      recordIDsToDelete: batch.compactMap { change -> CKRecord.ID? in
        guard case .deleteRecord(let recordID) = change else { return nil }
        return recordID
      },
      atomicByZone: true
    )
  }

  /// Looks up records by UUID for a batch of pending changes.
  /// For small batches (≤400), does individual lookups per record.
  /// For large batches, loads all records per type and filters.
  private func buildBatchRecordLookup(for uuids: Set<UUID>) -> [UUID: CKRecord] {
    let context = ModelContext(modelContainer)
    var lookup: [UUID: CKRecord] = [:]

    // For typical batch sizes (≤400), individual lookups are fast enough
    // and avoid loading entire tables into memory.
    // Check the most common record types first (transactions and investment
    // values make up the vast majority of records).
    for uuid in uuids {
      if let r = try? context.fetch(
        FetchDescriptor<TransactionRecord>(
          predicate: #Predicate { $0.id == uuid })
      ).first {
        lookup[uuid] = buildCKRecord(for: r)
        continue
      }
      if let r = try? context.fetch(
        FetchDescriptor<InvestmentValueRecord>(
          predicate: #Predicate { $0.id == uuid })
      ).first {
        lookup[uuid] = buildCKRecord(for: r)
        continue
      }
      if let r = try? context.fetch(
        FetchDescriptor<AccountRecord>(
          predicate: #Predicate { $0.id == uuid })
      ).first {
        lookup[uuid] = buildCKRecord(for: r)
        continue
      }
      if let r = try? context.fetch(
        FetchDescriptor<CategoryRecord>(
          predicate: #Predicate { $0.id == uuid })
      ).first {
        lookup[uuid] = buildCKRecord(for: r)
        continue
      }
      if let r = try? context.fetch(
        FetchDescriptor<EarmarkRecord>(
          predicate: #Predicate { $0.id == uuid })
      ).first {
        lookup[uuid] = buildCKRecord(for: r)
        continue
      }
      if let r = try? context.fetch(
        FetchDescriptor<EarmarkBudgetItemRecord>(
          predicate: #Predicate { $0.id == uuid })
      ).first {
        lookup[uuid] = buildCKRecord(for: r)
        continue
      }
    }

    let missing = uuids.count - lookup.count
    if missing > 0 {
      logger.warning("Batch lookup: \(missing) of \(uuids.count) records not found in local store")
    }

    return lookup
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

  private func handleSentRecordZoneChanges(
    _ sentChanges: CKSyncEngine.Event.SentRecordZoneChanges
  ) {
    // Cache system fields for successfully sent records (Rule 5).
    // This preserves the change tag for subsequent uploads.
    for saved in sentChanges.savedRecords {
      systemFieldsCache[saved.recordID.recordName] = saved.encodedSystemFields
    }
    saveSystemFieldsCache()

    for deleted in sentChanges.deletedRecordIDs {
      systemFieldsCache.removeValue(forKey: deleted.recordName)
    }

    // Handle failed saves with specific error recovery (Rules 3, 6, 9)
    // Collect zone-missing records to handle in a single zone creation
    var zoneNotFoundSaves: [CKRecord.ID] = []
    var zoneNotFoundDeletes: [CKRecord.ID] = []

    for failure in sentChanges.failedRecordSaves {
      let recordID = failure.record.recordID

      switch failure.error.code {
      case .zoneNotFound, .userDeletedZone:
        zoneNotFoundSaves.append(recordID)

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
        // Re-queue for retry on unexpected errors. CKSyncEngine handles transient
        // errors (network, rate limiting) automatically, but other errors drop the
        // record from the queue. Re-queuing ensures we don't silently lose data.
        logger.error(
          "Save error (code=\(failure.error.code.rawValue)) for \(recordID.recordName): \(failure.error) — re-queuing"
        )
        syncEngine?.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
      }
    }

    // Handle failed deletes
    for (recordID, error) in sentChanges.failedRecordDeletes {
      if error.code == .zoneNotFound || error.code == .userDeletedZone {
        zoneNotFoundDeletes.append(recordID)
      } else {
        logger.error(
          "Failed to delete record \(recordID.recordName): \(error)")
      }
    }

    // Create zone once and re-queue all affected records
    if !zoneNotFoundSaves.isEmpty || !zoneNotFoundDeletes.isEmpty {
      let saveCount = zoneNotFoundSaves.count
      let deleteCount = zoneNotFoundDeletes.count
      logger.info(
        "Zone missing — creating zone and re-queuing \(saveCount) saves, \(deleteCount) deletes")
      Task {
        do {
          let zone = CKRecordZone(zoneID: self.zoneID)
          try await CKContainer.default().privateCloudDatabase.save(zone)
          self.logger.info("Created zone \(self.zoneID.zoneName)")
          let pendingSaves: [CKSyncEngine.PendingRecordZoneChange] =
            zoneNotFoundSaves.map { .saveRecord($0) }
          let pendingDeletes: [CKSyncEngine.PendingRecordZoneChange] =
            zoneNotFoundDeletes.map { .deleteRecord($0) }
          self.syncEngine?.state.add(
            pendingRecordZoneChanges: pendingSaves + pendingDeletes)
        } catch {
          self.logger.error("Failed to create zone: \(error)")
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
