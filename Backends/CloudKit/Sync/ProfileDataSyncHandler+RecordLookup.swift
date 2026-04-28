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
    case CSVImportProfileRow.recordType:
      return fetchCSVImportProfileRow(id: uuid).map { row in
        buildCKRecord(from: row, encodedSystemFields: row.encodedSystemFields)
      }
    case ImportRuleRow.recordType:
      return fetchImportRuleRow(id: uuid).map { row in
        buildCKRecord(from: row, encodedSystemFields: row.encodedSystemFields)
      }
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
    let ids = Array(uuids)
    switch recordType {
    case AccountRecord.recordType:
      return mapBuilt(fetchAccountsBatch(ids: ids, context: context))
    case TransactionRecord.recordType:
      return mapBuilt(fetchTransactionsBatch(ids: ids, context: context))
    case TransactionLegRecord.recordType:
      return mapBuilt(fetchTransactionLegsBatch(ids: ids, context: context))
    case CategoryRecord.recordType:
      return mapBuilt(fetchCategoriesBatch(ids: ids, context: context))
    case EarmarkRecord.recordType:
      return mapBuilt(fetchEarmarksBatch(ids: ids, context: context))
    case EarmarkBudgetItemRecord.recordType:
      return mapBuilt(fetchEarmarkBudgetItemsBatch(ids: ids, context: context))
    case InvestmentValueRecord.recordType:
      return mapBuilt(fetchInvestmentValuesBatch(ids: ids, context: context))
    case CSVImportProfileRow.recordType:
      return mapBuiltRows(fetchCSVImportProfileRowsBatch(ids: ids))
    case ImportRuleRow.recordType:
      return mapBuiltRows(fetchImportRuleRowsBatch(ids: ids))
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

  /// Value-type counterpart of `mapBuilt(_:)` for GRDB row structs.
  /// Mirrors the SwiftData path but reads `encodedSystemFields` from
  /// the row directly (Rows don't conform to `SystemFieldsCacheable` —
  /// see the protocol's doc comment).
  private func mapBuiltRows<T>(_ rows: [T]) -> [UUID: CKRecord]
  where T: IdentifiableRecord & CloudKitRecordConvertible {
    var built: [UUID: CKRecord] = [:]
    built.reserveCapacity(rows.count)
    for row in rows {
      let cached: Data?
      if let cacheable = row as? CSVImportProfileRow {
        cached = cacheable.encodedSystemFields
      } else if let cacheable = row as? ImportRuleRow {
        cached = cacheable.encodedSystemFields
      } else {
        cached = nil
      }
      built[row.id] = buildCKRecord(from: row, encodedSystemFields: cached)
    }
    return built
  }

  // MARK: - Per-Type Batch Fetches
  //
  // `#Predicate` requires a concrete model type, so each type gets its own
  // tiny batch fetcher. They're all the same shape: IN-predicate over
  // `ids` against `id`. SwiftData's `#Predicate` macro requires
  // `[UUID].contains(_:)` (Array, not Set) — the equivalent
  // `Set<UUID>.contains` silently returns no matches at runtime, so the
  // batch fetcher would treat every record as "deleted locally" and the
  // upload would never happen.

  private func fetchAccountsBatch(ids: [UUID], context: ModelContext) -> [AccountRecord] {
    Self.fetchOrLog(
      FetchDescriptor<AccountRecord>(predicate: #Predicate { ids.contains($0.id) }),
      context: context)
  }

  private func fetchTransactionsBatch(
    ids: [UUID], context: ModelContext
  ) -> [TransactionRecord] {
    Self.fetchOrLog(
      FetchDescriptor<TransactionRecord>(predicate: #Predicate { ids.contains($0.id) }),
      context: context)
  }

  private func fetchTransactionLegsBatch(
    ids: [UUID], context: ModelContext
  ) -> [TransactionLegRecord] {
    Self.fetchOrLog(
      FetchDescriptor<TransactionLegRecord>(predicate: #Predicate { ids.contains($0.id) }),
      context: context)
  }

  private func fetchCategoriesBatch(ids: [UUID], context: ModelContext) -> [CategoryRecord] {
    Self.fetchOrLog(
      FetchDescriptor<CategoryRecord>(predicate: #Predicate { ids.contains($0.id) }),
      context: context)
  }

  private func fetchEarmarksBatch(ids: [UUID], context: ModelContext) -> [EarmarkRecord] {
    Self.fetchOrLog(
      FetchDescriptor<EarmarkRecord>(predicate: #Predicate { ids.contains($0.id) }),
      context: context)
  }

  private func fetchEarmarkBudgetItemsBatch(
    ids: [UUID], context: ModelContext
  ) -> [EarmarkBudgetItemRecord] {
    Self.fetchOrLog(
      FetchDescriptor<EarmarkBudgetItemRecord>(predicate: #Predicate { ids.contains($0.id) }),
      context: context)
  }

  private func fetchInvestmentValuesBatch(
    ids: [UUID], context: ModelContext
  ) -> [InvestmentValueRecord] {
    Self.fetchOrLog(
      FetchDescriptor<InvestmentValueRecord>(predicate: #Predicate { ids.contains($0.id) }),
      context: context)
  }

  private func fetchCSVImportProfileRowsBatch(ids: [UUID]) -> [CSVImportProfileRow] {
    do {
      return try grdbRepositories.csvImportProfiles.fetchRowsSync(ids: ids)
    } catch {
      logger.error(
        """
        GRDB batch fetch failed for CSVImportProfileRow: \
        \(error.localizedDescription, privacy: .public)
        """)
      return []
    }
  }

  private func fetchImportRuleRowsBatch(ids: [UUID]) -> [ImportRuleRow] {
    do {
      return try grdbRepositories.importRules.fetchRowsSync(ids: ids)
    } catch {
      logger.error(
        """
        GRDB batch fetch failed for ImportRuleRow: \
        \(error.localizedDescription, privacy: .public)
        """)
      return []
    }
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

  func fetchCSVImportProfileRow(id: UUID) -> CSVImportProfileRow? {
    do {
      return try grdbRepositories.csvImportProfiles.fetchRowSync(id: id)
    } catch {
      logger.error(
        """
        GRDB fetch failed for CSVImportProfileRow \(id, privacy: .public): \
        \(error.localizedDescription, privacy: .public)
        """)
      return nil
    }
  }

  func fetchImportRuleRow(id: UUID) -> ImportRuleRow? {
    do {
      return try grdbRepositories.importRules.fetchRowSync(id: id)
    } catch {
      logger.error(
        """
        GRDB fetch failed for ImportRuleRow \(id, privacy: .public): \
        \(error.localizedDescription, privacy: .public)
        """)
      return nil
    }
  }
}
