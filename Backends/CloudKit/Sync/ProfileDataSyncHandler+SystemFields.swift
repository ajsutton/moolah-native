@preconcurrency import CloudKit
import Foundation

extension ProfileDataSyncHandler {
  // MARK: - System Fields Management

  /// Clears `encodedSystemFields` on every locally-tracked row.
  /// Called before re-uploading after an `encryptedDataReset`.
  func clearAllSystemFields() {
    let clearedAll = runSystemFieldClears(clearOperations())
    if clearedAll {
      logger.info("Cleared all system fields for profile \(self.profileId)")
    }
  }

  /// Per-record-type clear operations, in dependency order.
  private func clearOperations() -> [(String, () throws -> Void)] {
    [
      (CSVImportProfileRow.recordType, grdbRepositories.csvImportProfiles.clearAllSystemFieldsSync),
      (ImportRuleRow.recordType, grdbRepositories.importRules.clearAllSystemFieldsSync),
      (InstrumentRow.recordType, grdbRepositories.instruments.clearAllSystemFieldsSync),
      (CategoryRow.recordType, grdbRepositories.categories.clearAllSystemFieldsSync),
      (AccountRow.recordType, grdbRepositories.accounts.clearAllSystemFieldsSync),
      (EarmarkRow.recordType, grdbRepositories.earmarks.clearAllSystemFieldsSync),
      (
        EarmarkBudgetItemRow.recordType,
        grdbRepositories.earmarkBudgetItems.clearAllSystemFieldsSync
      ),
      (InvestmentValueRow.recordType, grdbRepositories.investmentValues.clearAllSystemFieldsSync),
      (TransactionRow.recordType, grdbRepositories.transactions.clearAllSystemFieldsSync),
      (TransactionLegRow.recordType, grdbRepositories.transactionLegs.clearAllSystemFieldsSync),
    ]
  }

  /// Runs the per-record-type clears; logs and continues on failure so
  /// a single broken table cannot leave others stuck. Returns `true`
  /// when every operation succeeded.
  private func runSystemFieldClears(
    _ clears: [(String, () throws -> Void)]
  ) -> Bool {
    var clearedAll = true
    for (recordType, clear) in clears {
      do {
        try clear()
      } catch {
        clearedAll = false
        logger.error(
          """
          Failed to clear system fields for \(recordType, privacy: .public) profile \
          \(self.profileId, privacy: .public): \
          \(error.localizedDescription, privacy: .public)
          """)
      }
    }
    return clearedAll
  }

  // MARK: - Handle Sent Record Zone Changes

  /// Processes results from a successful CKSyncEngine send.
  /// Updates system fields on successfully saved records, classifies failures,
  /// and handles conflict/unknownItem system fields updates.
  /// Returns classified failures for the coordinator to re-queue.
  func handleSentRecordZoneChanges(
    savedRecords: [CKRecord],
    failedSaves: [CKSyncEngine.Event.SentRecordZoneChanges.FailedRecordSave],
    failedDeletes: [(CKRecord.ID, CKError)]
  ) -> SyncErrorRecovery.ClassifiedFailures {
    if !savedRecords.isEmpty {
      updateSystemFieldsForSaved(savedRecords)
    }

    let failures = SyncErrorRecovery.classify(
      failedSaves: failedSaves, failedDeletes: failedDeletes, logger: logger)

    if !failures.conflicts.isEmpty || !failures.unknownItems.isEmpty {
      updateSystemFieldsForFailures(
        conflicts: failures.conflicts, unknownItems: failures.unknownItems)
    }

    return failures
  }

  /// Writes each successfully-sent record's latest system fields back
  /// onto the matching local row.
  private func updateSystemFieldsForSaved(_ savedRecords: [CKRecord]) {
    for saved in savedRecords {
      applySystemFields(from: saved)
    }
    logger.info("Applied system fields for \(savedRecords.count) saved records")
  }

  /// Reconciles system fields after conflicts (adopt the server copy)
  /// and unknownItem failures (clear the stale cache so the record
  /// re-uploads as a fresh create).
  private func updateSystemFieldsForFailures(
    conflicts: [(recordID: CKRecord.ID, serverRecord: CKRecord)],
    unknownItems: [(recordID: CKRecord.ID, recordType: String)]
  ) {
    for (_, serverRecord) in conflicts {
      applySystemFields(from: serverRecord)
    }
    for (recordID, recordType) in unknownItems {
      clearSystemFields(for: recordID, recordType: recordType)
    }
  }

  private func applySystemFields(from ckRecord: CKRecord) {
    let data = ckRecord.encodedSystemFields
    if ckRecord.recordType == InstrumentRow.recordType {
      let id = ckRecord.recordID.systemFieldsKey
      do {
        let applied = try self.grdbRepositories.instruments
          .setEncodedSystemFieldsSync(id: id, data: data)
        if !applied {
          logger.warning(
            "No GRDB row to cache system fields for \(InstrumentRow.recordType, privacy: .public) \(id, privacy: .public)"
          )
        }
      } catch {
        logger.error(
          """
          GRDB system-fields update failed for \(InstrumentRow.recordType, privacy: .public) \
          \(id, privacy: .public): \(error.localizedDescription, privacy: .public)
          """)
      }
      return
    }
    guard let uuid = ckRecord.recordID.uuid else {
      logger.warning(
        "applySystemFields: recordName \(ckRecord.recordID.recordName) has no UUID component for \(ckRecord.recordType)"
      )
      return
    }
    if !applyGRDBSystemFields(recordType: ckRecord.recordType, id: uuid, data: data) {
      logger.warning(
        "No GRDB dispatch for \(ckRecord.recordType, privacy: .public) \(uuid.uuidString, privacy: .public)"
      )
    }
  }

  private func clearSystemFields(
    for recordID: CKRecord.ID, recordType: String
  ) {
    if recordType == InstrumentRow.recordType {
      let id = recordID.systemFieldsKey
      do {
        _ = try self.grdbRepositories.instruments.setEncodedSystemFieldsSync(id: id, data: nil)
      } catch {
        logger.error(
          """
          GRDB system-fields clear failed for \(InstrumentRow.recordType, privacy: .public) \
          \(id, privacy: .public): \(error.localizedDescription, privacy: .public)
          """)
      }
      return
    }
    guard let uuid = recordID.uuid else {
      logger.warning(
        "clearSystemFields: recordName \(recordID.recordName) has no UUID component for \(recordType)"
      )
      return
    }
    if !applyGRDBSystemFields(recordType: recordType, id: uuid, data: nil) {
      logger.warning(
        "No GRDB dispatch for \(recordType, privacy: .public) \(uuid.uuidString, privacy: .public)"
      )
    }
  }

  /// Routes a single-row system-fields write through the GRDB repos.
  /// Returns `true` when handled.
  private func applyGRDBSystemFields(
    recordType: String, id: UUID, data: Data?
  ) -> Bool {
    guard let setter = systemFieldsSetter(for: recordType) else { return false }
    do {
      let applied = try setter(id, data)
      if !applied {
        logger.warning(
          "No GRDB row to cache system fields for \(recordType, privacy: .public) \(id, privacy: .public)"
        )
      }
    } catch {
      logger.error(
        """
        GRDB system-fields update failed for \(recordType, privacy: .public) \
        \(id, privacy: .public): \(error.localizedDescription, privacy: .public)
        """)
    }
    return true
  }

  /// Returns the per-recordType single-row system-fields setter, or
  /// `nil` for record types not handled by the GRDB layer.
  private func systemFieldsSetter(
    for recordType: String
  ) -> ((UUID, Data?) throws -> Bool)? {
    let repos = grdbRepositories
    switch recordType {
    case CSVImportProfileRow.recordType:
      return { try repos.csvImportProfiles.setEncodedSystemFieldsSync(id: $0, data: $1) }
    case ImportRuleRow.recordType:
      return { try repos.importRules.setEncodedSystemFieldsSync(id: $0, data: $1) }
    case CategoryRow.recordType:
      return { try repos.categories.setEncodedSystemFieldsSync(id: $0, data: $1) }
    case AccountRow.recordType:
      return { try repos.accounts.setEncodedSystemFieldsSync(id: $0, data: $1) }
    case EarmarkRow.recordType:
      return { try repos.earmarks.setEncodedSystemFieldsSync(id: $0, data: $1) }
    case EarmarkBudgetItemRow.recordType:
      return { try repos.earmarkBudgetItems.setEncodedSystemFieldsSync(id: $0, data: $1) }
    case InvestmentValueRow.recordType:
      return { try repos.investmentValues.setEncodedSystemFieldsSync(id: $0, data: $1) }
    case TransactionRow.recordType:
      return { try repos.transactions.setEncodedSystemFieldsSync(id: $0, data: $1) }
    case TransactionLegRow.recordType:
      return { try repos.transactionLegs.setEncodedSystemFieldsSync(id: $0, data: $1) }
    default:
      return nil
    }
  }
}
