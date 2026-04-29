@preconcurrency import CloudKit
import Foundation

extension ProfileDataSyncHandler {
  // MARK: - Batch Record Lookup

  /// Looks up records grouped by their CKRecord recordType. Each group
  /// runs one batch fetch over its own GRDB repo so two different record
  /// types that happen to share a UUID don't collide in the result.
  /// Returns `[recordType: [UUID: CKRecord]]`.
  func buildBatchRecordLookup(
    byRecordType groups: [String: Set<UUID>]
  ) -> [String: [UUID: CKRecord]] {
    var result: [String: [UUID: CKRecord]] = [:]
    for (recordType, uuids) in groups {
      guard !uuids.isEmpty else { continue }
      result[recordType] = batchFetchByType(recordType: recordType, uuids: uuids)
    }
    return result
  }

  // MARK: - Record Lookup for Upload

  /// Looks up a single record by `CKRecord.ID` and builds the `CKRecord`
  /// for upload. Dispatches by the recordType prefix encoded in the
  /// recordName (`<recordType>|<UUID>`); unprefixed recordNames are
  /// treated as string IDs and routed to the Instrument lookup.
  func recordToSave(for recordID: CKRecord.ID) -> CKRecord? {
    if let recordType = recordID.prefixedRecordType, let uuid = recordID.uuid {
      return fetchAndBuild(recordType: recordType, uuid: uuid)
    }
    return fetchInstrumentRow(id: recordID.recordName).map { row in
      buildCKRecord(from: row, encodedSystemFields: row.encodedSystemFields)
    }
  }

  // MARK: - Per-Type Dispatch

  /// Single-record dispatcher. Returns nil for unknown recordType strings.
  private func fetchAndBuild(recordType: String, uuid: UUID) -> CKRecord? {
    switch recordType {
    case AccountRow.recordType:
      return fetchAccountRow(id: uuid).map { row in
        buildCKRecord(from: row, encodedSystemFields: row.encodedSystemFields)
      }
    case TransactionRow.recordType:
      return fetchTransactionRow(id: uuid).map { row in
        buildCKRecord(from: row, encodedSystemFields: row.encodedSystemFields)
      }
    case TransactionLegRow.recordType:
      return fetchTransactionLegRow(id: uuid).map { row in
        buildCKRecord(from: row, encodedSystemFields: row.encodedSystemFields)
      }
    case CategoryRow.recordType:
      return fetchCategoryRow(id: uuid).map { row in
        buildCKRecord(from: row, encodedSystemFields: row.encodedSystemFields)
      }
    case EarmarkRow.recordType:
      return fetchEarmarkRow(id: uuid).map { row in
        buildCKRecord(from: row, encodedSystemFields: row.encodedSystemFields)
      }
    case EarmarkBudgetItemRow.recordType:
      return fetchEarmarkBudgetItemRow(id: uuid).map { row in
        buildCKRecord(from: row, encodedSystemFields: row.encodedSystemFields)
      }
    case InvestmentValueRow.recordType:
      return fetchInvestmentValueRow(id: uuid).map { row in
        buildCKRecord(from: row, encodedSystemFields: row.encodedSystemFields)
      }
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

  /// Batch-fetch dispatcher. One batch fetch per type, mapped into
  /// `[UUID: CKRecord]` via `buildCKRecord`.
  private func batchFetchByType(
    recordType: String, uuids: Set<UUID>
  ) -> [UUID: CKRecord] {
    let ids = Array(uuids)
    switch recordType {
    case AccountRow.recordType:
      return mapBuiltRows(fetchRowsBatch { try grdbRepositories.accounts.fetchRowsSync(ids: ids) })
    case TransactionRow.recordType:
      return mapBuiltRows(
        fetchRowsBatch { try grdbRepositories.transactions.fetchRowsSync(ids: ids) })
    case TransactionLegRow.recordType:
      return mapBuiltRows(
        fetchRowsBatch { try grdbRepositories.transactionLegs.fetchRowsSync(ids: ids) })
    case CategoryRow.recordType:
      return mapBuiltRows(
        fetchRowsBatch { try grdbRepositories.categories.fetchRowsSync(ids: ids) })
    case EarmarkRow.recordType:
      return mapBuiltRows(
        fetchRowsBatch { try grdbRepositories.earmarks.fetchRowsSync(ids: ids) })
    case EarmarkBudgetItemRow.recordType:
      return mapBuiltRows(
        fetchRowsBatch { try grdbRepositories.earmarkBudgetItems.fetchRowsSync(ids: ids) })
    case InvestmentValueRow.recordType:
      return mapBuiltRows(
        fetchRowsBatch { try grdbRepositories.investmentValues.fetchRowsSync(ids: ids) })
    case CSVImportProfileRow.recordType:
      return mapBuiltRows(
        fetchRowsBatch { try grdbRepositories.csvImportProfiles.fetchRowsSync(ids: ids) })
    case ImportRuleRow.recordType:
      return mapBuiltRows(
        fetchRowsBatch { try grdbRepositories.importRules.fetchRowsSync(ids: ids) })
    default:
      logger.warning(
        "Unknown recordType '\(recordType, privacy: .public)' in batch lookup — skipping"
      )
      return [:]
    }
  }

  /// Reduces a fetched batch of GRDB rows into `[UUID: CKRecord]` keyed
  /// by the row's own `id`, with each value built via
  /// `buildCKRecord(from:encodedSystemFields:)`.
  private func mapBuiltRows<T>(_ rows: [T]) -> [UUID: CKRecord]
  where T: IdentifiableRecord & CloudKitRecordConvertible & ValueTypeSystemFieldsReadable {
    var built: [UUID: CKRecord] = [:]
    built.reserveCapacity(rows.count)
    for row in rows {
      built[row.id] = buildCKRecord(
        from: row, encodedSystemFields: row.encodedSystemFields)
    }
    return built
  }

  /// Common error-handling wrapper for the batch-fetch closures used in
  /// `batchFetchByType`. Logs at error level on throw and returns an
  /// empty array (mirroring the SwiftData path's `fetchOrLog`
  /// best-effort semantics).
  private func fetchRowsBatch<T>(_ work: () throws -> [T]) -> [T] {
    do {
      return try work()
    } catch {
      logger.error(
        """
        GRDB batch fetch failed: \(error.localizedDescription, privacy: .public)
        """)
      return []
    }
  }

  // MARK: - Per-Row Lookups

  private func fetchAccountRow(id: UUID) -> AccountRow? {
    fetchRowOrLog { try grdbRepositories.accounts.fetchRowSync(id: id) }
  }

  private func fetchTransactionRow(id: UUID) -> TransactionRow? {
    fetchRowOrLog { try grdbRepositories.transactions.fetchRowSync(id: id) }
  }

  private func fetchTransactionLegRow(id: UUID) -> TransactionLegRow? {
    fetchRowOrLog { try grdbRepositories.transactionLegs.fetchRowSync(id: id) }
  }

  private func fetchCategoryRow(id: UUID) -> CategoryRow? {
    fetchRowOrLog { try grdbRepositories.categories.fetchRowSync(id: id) }
  }

  private func fetchEarmarkRow(id: UUID) -> EarmarkRow? {
    fetchRowOrLog { try grdbRepositories.earmarks.fetchRowSync(id: id) }
  }

  private func fetchEarmarkBudgetItemRow(id: UUID) -> EarmarkBudgetItemRow? {
    fetchRowOrLog { try grdbRepositories.earmarkBudgetItems.fetchRowSync(id: id) }
  }

  private func fetchInvestmentValueRow(id: UUID) -> InvestmentValueRow? {
    fetchRowOrLog { try grdbRepositories.investmentValues.fetchRowSync(id: id) }
  }

  private func fetchInstrumentRow(id: String) -> InstrumentRow? {
    fetchRowOrLog { try grdbRepositories.instruments.fetchRowSync(id: id) }
  }

  private func fetchCSVImportProfileRow(id: UUID) -> CSVImportProfileRow? {
    fetchRowOrLog { try grdbRepositories.csvImportProfiles.fetchRowSync(id: id) }
  }

  private func fetchImportRuleRow(id: UUID) -> ImportRuleRow? {
    fetchRowOrLog { try grdbRepositories.importRules.fetchRowSync(id: id) }
  }

  /// Common error-handling wrapper for the per-row fetch closures used
  /// above. Logs at error level on throw and returns `nil`.
  private func fetchRowOrLog<T>(_ work: () throws -> T?) -> T? {
    do {
      return try work()
    } catch {
      logger.error(
        """
        GRDB fetch failed: \(error.localizedDescription, privacy: .public)
        """)
      return nil
    }
  }
}
