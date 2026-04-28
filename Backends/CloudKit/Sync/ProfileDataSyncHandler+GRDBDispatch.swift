@preconcurrency import CloudKit
import Foundation

extension ProfileDataSyncHandler {
  // MARK: - GRDB Dispatch (saves)

  /// Routes a per-record-type batch through the GRDB repos when the type
  /// has been migrated. Returns `true` when the dispatch was handled here
  /// (caller skips the SwiftData path for this group), `false` for
  /// SwiftData-managed types.
  ///
  /// Throws when the GRDB write fails. The caller (`applyBatchSaves`)
  /// rethrows so `applyRemoteChanges` returns `.saveFailed(...)` and the
  /// CKSyncEngine change-token does not advance past the dropped record —
  /// the next fetch will retry instead of silently losing the update.
  nonisolated func applyGRDBBatchSave(
    recordType: String,
    ckRecords: [CKRecord],
    systemFields: [String: Data]
  ) throws -> Bool {
    switch recordType {
    case CSVImportProfileRow.recordType:
      let rows = ckRecords.compactMap { ckRecord -> CSVImportProfileRow? in
        guard var row = CSVImportProfileRow.fieldValues(from: ckRecord) else {
          Self.logMalformed("applyGRDBBatchSave[CSVImportProfile]", ckRecord)
          return nil
        }
        row.encodedSystemFields = systemFields[row.id.uuidString]
        return row
      }
      do {
        try grdbRepositories.csvImportProfiles.applyRemoteChangesSync(
          saved: rows, deleted: [])
      } catch {
        Self.batchLogger.error(
          """
          applyGRDBBatchSave[CSVImportProfile] profile \
          \(self.profileId, privacy: .public) failed: \
          \(error.localizedDescription, privacy: .public)
          """)
        throw error
      }
      return true
    case ImportRuleRow.recordType:
      let rows = ckRecords.compactMap { ckRecord -> ImportRuleRow? in
        guard var row = ImportRuleRow.fieldValues(from: ckRecord) else {
          Self.logMalformed("applyGRDBBatchSave[ImportRule]", ckRecord)
          return nil
        }
        row.encodedSystemFields = systemFields[row.id.uuidString]
        return row
      }
      do {
        try grdbRepositories.importRules.applyRemoteChangesSync(
          saved: rows, deleted: [])
      } catch {
        Self.batchLogger.error(
          """
          applyGRDBBatchSave[ImportRule] profile \
          \(self.profileId, privacy: .public) failed: \
          \(error.localizedDescription, privacy: .public)
          """)
        throw error
      }
      return true
    default:
      return false
    }
  }

  // MARK: - GRDB Dispatch (deletions)

  /// Routes a per-record-type batch deletion through the GRDB repos when
  /// the type has been migrated. Returns `true` when the dispatch was
  /// handled here (caller skips the SwiftData path for this group),
  /// `false` for SwiftData-managed types. Throws on GRDB write failure
  /// so the caller can surface `.saveFailed(...)` upstream — see
  /// `applyGRDBBatchSave` for the data-loss rationale.
  nonisolated func applyGRDBBatchDeletion(
    recordType: String, ids: [UUID]
  ) throws -> Bool {
    switch recordType {
    case CSVImportProfileRow.recordType:
      do {
        try grdbRepositories.csvImportProfiles.applyRemoteChangesSync(
          saved: [], deleted: ids)
      } catch {
        Self.batchLogger.error(
          """
          applyGRDBBatchDeletion[CSVImportProfile] profile \
          \(self.profileId, privacy: .public) failed: \
          \(error.localizedDescription, privacy: .public)
          """)
        throw error
      }
      return true
    case ImportRuleRow.recordType:
      do {
        try grdbRepositories.importRules.applyRemoteChangesSync(
          saved: [], deleted: ids)
      } catch {
        Self.batchLogger.error(
          """
          applyGRDBBatchDeletion[ImportRule] profile \
          \(self.profileId, privacy: .public) failed: \
          \(error.localizedDescription, privacy: .public)
          """)
        throw error
      }
      return true
    default:
      return false
    }
  }

  // MARK: - Malformed-Record Logging

  /// Logs a malformed incoming CKRecord at error level so the skip is
  /// visible in diagnostics rather than silently dropped. Mirror of the
  /// SwiftData-path helper so GRDB and SwiftData log lines look uniform.
  nonisolated static func logMalformed(_ site: String, _ ckRecord: CKRecord) {
    batchLogger.error(
      "\(site): malformed recordID '\(ckRecord.recordID.recordName)' (recordType \(ckRecord.recordType)) — skipping"
    )
  }
}
