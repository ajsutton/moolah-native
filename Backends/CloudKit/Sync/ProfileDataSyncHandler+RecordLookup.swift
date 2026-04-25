@preconcurrency import CloudKit
import Foundation
import SwiftData

extension ProfileDataSyncHandler {
  // MARK: - Batch Record Lookup

  /// Looks up records grouped by their CKRecord recordType. Each group does
  /// one IN-predicate fetch over its own SwiftData type, so two different
  /// record types that happen to share a UUID don't collide in the result —
  /// the previous UUID-only lookup returned the same `CKRecord` for both,
  /// which CloudKit then rejected with `.invalidArguments` (issue #416 +
  /// follow-up). Returns `[recordType: [UUID: CKRecord]]`.
  func buildBatchRecordLookup(
    byRecordType groups: [String: Set<UUID>]
  ) -> [String: [UUID: CKRecord]] {
    let context = ModelContext(modelContainer)
    var result: [String: [UUID: CKRecord]] = [:]
    for (recordType, uuids) in groups {
      guard !uuids.isEmpty else { continue }
      result[recordType] = batchFetchByType(
        recordType: recordType, uuids: uuids, context: context)
    }
    return result
  }

  // MARK: - Record Lookup for Upload

  /// Looks up a single record by `CKRecord.ID` and builds the `CKRecord` for
  /// upload. Dispatches by the recordType prefix encoded in the recordName
  /// (`<recordType>|<UUID>`); unprefixed recordNames are treated as string
  /// IDs and routed to the InstrumentRecord lookup.
  func recordToSave(for recordID: CKRecord.ID) -> CKRecord? {
    let context = ModelContext(modelContainer)
    if let recordType = recordID.prefixedRecordType, let uuid = recordID.uuid {
      return fetchAndBuild(recordType: recordType, uuid: uuid, context: context)
    }
    return fetchInstrument(id: recordID.recordName, context: context)
      .map(buildCKRecord)
  }

  // MARK: - Per-Type Dispatch

  /// Single-record dispatcher. Returns nil for unknown recordType strings.
  private func fetchAndBuild(
    recordType: String, uuid: UUID, context: ModelContext
  ) -> CKRecord? {
    switch recordType {
    case AccountRecord.recordType:
      return fetchAccount(id: uuid, context: context).map(buildCKRecord)
    case TransactionRecord.recordType:
      return fetchTransaction(id: uuid, context: context).map(buildCKRecord)
    case TransactionLegRecord.recordType:
      return fetchTransactionLeg(id: uuid, context: context).map(buildCKRecord)
    case CategoryRecord.recordType:
      return fetchCategory(id: uuid, context: context).map(buildCKRecord)
    case EarmarkRecord.recordType:
      return fetchEarmark(id: uuid, context: context).map(buildCKRecord)
    case EarmarkBudgetItemRecord.recordType:
      return fetchEarmarkBudgetItem(id: uuid, context: context).map(buildCKRecord)
    case InvestmentValueRecord.recordType:
      return fetchInvestmentValue(id: uuid, context: context).map(buildCKRecord)
    case CSVImportProfileRecord.recordType:
      return fetchCSVImportProfile(id: uuid, context: context).map(buildCKRecord)
    case ImportRuleRecord.recordType:
      return fetchImportRule(id: uuid, context: context).map(buildCKRecord)
    default:
      logger.warning(
        "Unknown recordType '\(recordType, privacy: .public)' in prefixed recordID — skipping"
      )
      return nil
    }
  }

  /// Batch-fetch dispatcher. One IN-predicate fetch per type, mapped into
  /// `[UUID: CKRecord]` via `buildCKRecord`. Per-type because `#Predicate`
  /// cannot be generic.
  private func batchFetchByType(
    recordType: String, uuids: Set<UUID>, context: ModelContext
  ) -> [UUID: CKRecord] {
    switch recordType {
    case AccountRecord.recordType:
      return mapBuilt(fetchAccountsBatch(uuids: uuids, context: context))
    case TransactionRecord.recordType:
      return mapBuilt(fetchTransactionsBatch(uuids: uuids, context: context))
    case TransactionLegRecord.recordType:
      return mapBuilt(fetchTransactionLegsBatch(uuids: uuids, context: context))
    case CategoryRecord.recordType:
      return mapBuilt(fetchCategoriesBatch(uuids: uuids, context: context))
    case EarmarkRecord.recordType:
      return mapBuilt(fetchEarmarksBatch(uuids: uuids, context: context))
    case EarmarkBudgetItemRecord.recordType:
      return mapBuilt(fetchEarmarkBudgetItemsBatch(uuids: uuids, context: context))
    case InvestmentValueRecord.recordType:
      return mapBuilt(fetchInvestmentValuesBatch(uuids: uuids, context: context))
    case CSVImportProfileRecord.recordType:
      return mapBuilt(fetchCSVImportProfilesBatch(uuids: uuids, context: context))
    case ImportRuleRecord.recordType:
      return mapBuilt(fetchImportRulesBatch(uuids: uuids, context: context))
    default:
      logger.warning(
        "Unknown recordType '\(recordType, privacy: .public)' in batch lookup — skipping"
      )
      return [:]
    }
  }

  /// Reduces a fetched batch into a `[UUID: CKRecord]` keyed by the model's
  /// own `id`, with each value built via `buildCKRecord`.
  private func mapBuilt<T>(_ records: [T]) -> [UUID: CKRecord]
  where
    T: IdentifiableRecord & CloudKitRecordConvertible & SystemFieldsCacheable
  {
    var built: [UUID: CKRecord] = [:]
    built.reserveCapacity(records.count)
    for record in records {
      built[record.id] = buildCKRecord(for: record)
    }
    return built
  }

  // MARK: - Per-Type Batch Fetches
  //
  // `#Predicate` requires a concrete model type, so each type gets its own
  // tiny batch fetcher. They're all the same shape: IN-predicate over
  // `uuids` against `id`.

  private func fetchAccountsBatch(uuids: Set<UUID>, context: ModelContext) -> [AccountRecord] {
    Self.fetchOrLog(
      FetchDescriptor<AccountRecord>(predicate: #Predicate { uuids.contains($0.id) }),
      context: context)
  }

  private func fetchTransactionsBatch(
    uuids: Set<UUID>, context: ModelContext
  ) -> [TransactionRecord] {
    Self.fetchOrLog(
      FetchDescriptor<TransactionRecord>(predicate: #Predicate { uuids.contains($0.id) }),
      context: context)
  }

  private func fetchTransactionLegsBatch(
    uuids: Set<UUID>, context: ModelContext
  ) -> [TransactionLegRecord] {
    Self.fetchOrLog(
      FetchDescriptor<TransactionLegRecord>(predicate: #Predicate { uuids.contains($0.id) }),
      context: context)
  }

  private func fetchCategoriesBatch(uuids: Set<UUID>, context: ModelContext) -> [CategoryRecord] {
    Self.fetchOrLog(
      FetchDescriptor<CategoryRecord>(predicate: #Predicate { uuids.contains($0.id) }),
      context: context)
  }

  private func fetchEarmarksBatch(uuids: Set<UUID>, context: ModelContext) -> [EarmarkRecord] {
    Self.fetchOrLog(
      FetchDescriptor<EarmarkRecord>(predicate: #Predicate { uuids.contains($0.id) }),
      context: context)
  }

  private func fetchEarmarkBudgetItemsBatch(
    uuids: Set<UUID>, context: ModelContext
  ) -> [EarmarkBudgetItemRecord] {
    Self.fetchOrLog(
      FetchDescriptor<EarmarkBudgetItemRecord>(predicate: #Predicate { uuids.contains($0.id) }),
      context: context)
  }

  private func fetchInvestmentValuesBatch(
    uuids: Set<UUID>, context: ModelContext
  ) -> [InvestmentValueRecord] {
    Self.fetchOrLog(
      FetchDescriptor<InvestmentValueRecord>(predicate: #Predicate { uuids.contains($0.id) }),
      context: context)
  }

  private func fetchCSVImportProfilesBatch(
    uuids: Set<UUID>, context: ModelContext
  ) -> [CSVImportProfileRecord] {
    Self.fetchOrLog(
      FetchDescriptor<CSVImportProfileRecord>(predicate: #Predicate { uuids.contains($0.id) }),
      context: context)
  }

  private func fetchImportRulesBatch(
    uuids: Set<UUID>, context: ModelContext
  ) -> [ImportRuleRecord] {
    Self.fetchOrLog(
      FetchDescriptor<ImportRuleRecord>(predicate: #Predicate { uuids.contains($0.id) }),
      context: context)
  }

  // MARK: - Per-Type Fetch Methods

  func fetchAccount(id: UUID, context: ModelContext) -> AccountRecord? {
    let descriptor = FetchDescriptor<AccountRecord>(predicate: #Predicate { $0.id == id })
    return Self.fetchOrLog(descriptor, context: context).first
  }

  func fetchTransaction(id: UUID, context: ModelContext) -> TransactionRecord? {
    let descriptor = FetchDescriptor<TransactionRecord>(predicate: #Predicate { $0.id == id })
    return Self.fetchOrLog(descriptor, context: context).first
  }

  func fetchCategory(id: UUID, context: ModelContext) -> CategoryRecord? {
    let descriptor = FetchDescriptor<CategoryRecord>(predicate: #Predicate { $0.id == id })
    return Self.fetchOrLog(descriptor, context: context).first
  }

  func fetchEarmark(id: UUID, context: ModelContext) -> EarmarkRecord? {
    let descriptor = FetchDescriptor<EarmarkRecord>(predicate: #Predicate { $0.id == id })
    return Self.fetchOrLog(descriptor, context: context).first
  }

  func fetchEarmarkBudgetItem(id: UUID, context: ModelContext) -> EarmarkBudgetItemRecord? {
    let descriptor = FetchDescriptor<EarmarkBudgetItemRecord>(
      predicate: #Predicate { $0.id == id })
    return Self.fetchOrLog(descriptor, context: context).first
  }

  func fetchInvestmentValue(id: UUID, context: ModelContext) -> InvestmentValueRecord? {
    let descriptor = FetchDescriptor<InvestmentValueRecord>(predicate: #Predicate { $0.id == id })
    return Self.fetchOrLog(descriptor, context: context).first
  }

  func fetchInstrument(id: String, context: ModelContext) -> InstrumentRecord? {
    let descriptor = FetchDescriptor<InstrumentRecord>(predicate: #Predicate { $0.id == id })
    return Self.fetchOrLog(descriptor, context: context).first
  }

  func fetchTransactionLeg(id: UUID, context: ModelContext) -> TransactionLegRecord? {
    let descriptor = FetchDescriptor<TransactionLegRecord>(predicate: #Predicate { $0.id == id })
    return Self.fetchOrLog(descriptor, context: context).first
  }

  func fetchCSVImportProfile(id: UUID, context: ModelContext) -> CSVImportProfileRecord? {
    let descriptor = FetchDescriptor<CSVImportProfileRecord>(
      predicate: #Predicate { $0.id == id })
    return Self.fetchOrLog(descriptor, context: context).first
  }

  func fetchImportRule(id: UUID, context: ModelContext) -> ImportRuleRecord? {
    let descriptor = FetchDescriptor<ImportRuleRecord>(predicate: #Predicate { $0.id == id })
    return Self.fetchOrLog(descriptor, context: context).first
  }
}
