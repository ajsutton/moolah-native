@preconcurrency import CloudKit
import Foundation

extension ProfileDataSyncHandler {
  // MARK: - GRDB Dispatch (saves)

  /// Routes a per-record-type batch through the GRDB repos when the type
  /// has been migrated. Returns `true` when the dispatch was handled here
  /// (caller skips the SwiftData path for this group), `false` for any
  /// type not covered by the GRDB layer.
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
    guard let handler = saveHandler(for: recordType) else { return false }
    try handler(self)(ckRecords, systemFields)
    return true
  }

  /// Returns the per-record-type save helper as a curried function,
  /// or `nil` for record types not handled by the GRDB layer. Pulling
  /// the dispatch table out of the body keeps `applyGRDBBatchSave`'s
  /// cyclomatic complexity at 2 (guard + return). The lookup itself
  /// is split between `referenceSaveHandler` (immutable reference data)
  /// and `domainSaveHandler` (the financial-graph rows) so neither
  /// switch breaches the complexity ceiling.
  nonisolated private func saveHandler(
    for recordType: String
  ) -> ((ProfileDataSyncHandler) -> ([CKRecord], [String: Data]) throws -> Void)? {
    referenceSaveHandler(for: recordType) ?? domainSaveHandler(for: recordType)
  }

  /// Reference-data side of the `saveHandler` lookup.
  nonisolated private func referenceSaveHandler(
    for recordType: String
  ) -> ((ProfileDataSyncHandler) -> ([CKRecord], [String: Data]) throws -> Void)? {
    switch recordType {
    case CSVImportProfileRow.recordType:
      return { handler in handler.applyBatchSaveCSVImportProfile(ckRecords:systemFields:) }
    case ImportRuleRow.recordType:
      return { handler in handler.applyBatchSaveImportRule(ckRecords:systemFields:) }
    case InstrumentRow.recordType:
      return { handler in handler.applyBatchSaveInstrument(ckRecords:systemFields:) }
    case CategoryRow.recordType:
      return { handler in handler.applyBatchSaveCategory(ckRecords:systemFields:) }
    default:
      return nil
    }
  }

  /// Financial-graph side of the `saveHandler` lookup.
  nonisolated private func domainSaveHandler(
    for recordType: String
  ) -> ((ProfileDataSyncHandler) -> ([CKRecord], [String: Data]) throws -> Void)? {
    switch recordType {
    case AccountRow.recordType:
      return { handler in handler.applyBatchSaveAccount(ckRecords:systemFields:) }
    case EarmarkRow.recordType:
      return { handler in handler.applyBatchSaveEarmark(ckRecords:systemFields:) }
    case EarmarkBudgetItemRow.recordType:
      return { handler in handler.applyBatchSaveEarmarkBudgetItem(ckRecords:systemFields:) }
    case InvestmentValueRow.recordType:
      return { handler in handler.applyBatchSaveInvestmentValue(ckRecords:systemFields:) }
    case TransactionRow.recordType:
      return { handler in handler.applyBatchSaveTransaction(ckRecords:systemFields:) }
    case TransactionLegRow.recordType:
      return { handler in handler.applyBatchSaveTransactionLeg(ckRecords:systemFields:) }
    default:
      return nil
    }
  }

  // MARK: - GRDB Dispatch (deletions)

  /// Routes a per-record-type batch deletion through the GRDB repos when
  /// the type has been migrated. Returns `true` when the dispatch was
  /// handled here, `false` for any type not covered by the GRDB layer.
  /// Throws on GRDB write failure so the caller can surface
  /// `.saveFailed(...)` upstream — see `applyGRDBBatchSave` for the
  /// data-loss rationale.
  nonisolated func applyGRDBBatchDeletion(
    recordType: String, ids: [UUID]
  ) throws -> Bool {
    switch recordType {
    case CSVImportProfileRow.recordType:
      try writeRemote(site: "applyGRDBBatchDeletion[CSVImportProfile]") {
        try grdbRepositories.csvImportProfiles.applyRemoteChangesSync(saved: [], deleted: ids)
      }
      return true
    case ImportRuleRow.recordType:
      try writeRemote(site: "applyGRDBBatchDeletion[ImportRule]") {
        try grdbRepositories.importRules.applyRemoteChangesSync(saved: [], deleted: ids)
      }
      return true
    case AccountRow.recordType:
      try writeRemote(site: "applyGRDBBatchDeletion[Account]") {
        try grdbRepositories.accounts.applyRemoteChangesSync(saved: [], deleted: ids)
      }
      return true
    case CategoryRow.recordType:
      try writeRemote(site: "applyGRDBBatchDeletion[Category]") {
        try grdbRepositories.categories.applyRemoteChangesSync(saved: [], deleted: ids)
      }
      return true
    case EarmarkRow.recordType:
      try writeRemote(site: "applyGRDBBatchDeletion[Earmark]") {
        try grdbRepositories.earmarks.applyRemoteChangesSync(saved: [], deleted: ids)
      }
      return true
    case EarmarkBudgetItemRow.recordType:
      try writeRemote(site: "applyGRDBBatchDeletion[EarmarkBudgetItem]") {
        try grdbRepositories.earmarkBudgetItems.applyRemoteChangesSync(saved: [], deleted: ids)
      }
      return true
    case InvestmentValueRow.recordType:
      try writeRemote(site: "applyGRDBBatchDeletion[InvestmentValue]") {
        try grdbRepositories.investmentValues.applyRemoteChangesSync(saved: [], deleted: ids)
      }
      return true
    case TransactionRow.recordType:
      try writeRemote(site: "applyGRDBBatchDeletion[Transaction]") {
        try grdbRepositories.transactions.applyRemoteChangesSync(saved: [], deleted: ids)
      }
      return true
    case TransactionLegRow.recordType:
      try writeRemote(site: "applyGRDBBatchDeletion[TransactionLeg]") {
        try grdbRepositories.transactionLegs.applyRemoteChangesSync(saved: [], deleted: ids)
      }
      return true
    default:
      return false
    }
  }

  /// Companion to `applyGRDBBatchDeletion(recordType:ids:)` for record
  /// types keyed by string ID (currently only `Instrument`). Returns
  /// `true` when handled.
  nonisolated func applyGRDBBatchDeletion(
    recordType: String, names: [String]
  ) throws -> Bool {
    switch recordType {
    case InstrumentRow.recordType:
      try writeRemote(site: "applyGRDBBatchDeletion[Instrument]") {
        try grdbRepositories.instruments.applyRemoteChangesSync(saved: [], deleted: names)
      }
      return true
    default:
      return false
    }
  }
}
