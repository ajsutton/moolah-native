// swiftlint:disable multiline_arguments
// Reason: swift-format wraps long initialisers / SwiftUI builders across
// multiple lines in a way the multiline_arguments rule disagrees with.

@preconcurrency import CloudKit
import Foundation
import OSLog
import SwiftData
import os

extension ProfileDataSyncHandler {
  // MARK: - Applying Remote Changes

  /// Applies remote changes (inserts/updates/deletions) to the local
  /// stores. The eight migrated record types route through the GRDB
  /// dispatch tables in `+GRDBDispatch`; the `ProfileRecord` type
  /// remains on the SwiftData side and uses a fresh `ModelContext`.
  /// Returns the set of changed record type strings.
  nonisolated func applyRemoteChanges(
    saved: [CKRecord],
    deleted: [(CKRecord.ID, String)],
    preExtractedSystemFields: [(String, Data)] = []
  ) -> ApplyResult {
    let batchStart = ContinuousClock.now
    let signpostID = OSSignpostID(log: Signposts.sync)
    os_signpost(
      .begin, log: Signposts.sync, name: "applyRemoteChanges", signpostID: signpostID,
      "%{public}d saves, %{public}d deletes", saved.count, deleted.count)
    defer {
      os_signpost(.end, log: Signposts.sync, name: "applyRemoteChanges", signpostID: signpostID)
    }

    logIncomingBatch(saved: saved, deleted: deleted)

    let systemFields = Self.systemFieldsLookup(
      saved: saved, preExtracted: preExtractedSystemFields)

    // GRDB-routed batches throw on write failure so CKSyncEngine refetches
    // instead of advancing past a dropped record (silent data loss).
    let upsertStart = ContinuousClock.now
    if let failure = runBatchSavesPhase(
      saved: saved, systemFields: systemFields, signpostID: signpostID)
    {
      return failure
    }
    let upsertDuration = ContinuousClock.now - upsertStart

    if let failure = runBatchDeletionsPhase(
      deleted: deleted, signpostID: signpostID)
    {
      return failure
    }

    return reportSuccess(
      saved: saved,
      deleted: deleted,
      timing: BatchTiming(batchStart: batchStart, upsertDuration: upsertDuration),
      signpostID: signpostID)
  }

  /// Bundles per-batch timing markers so `reportSuccess` stays under
  /// the SwiftLint parameter budget. Both fields are populated up front
  /// in `applyRemoteChanges`; treat as an inline value, not shared state.
  nonisolated struct BatchTiming {
    let batchStart: ContinuousClock.Instant
    let upsertDuration: Duration
  }

  /// Wraps `applyBatchSaves` in its signpost + signpost-on-throw cleanup
  /// and converts a thrown error into a `.saveFailed(...)` result.
  /// Returns `nil` on success so the caller falls through to the next
  /// phase. Extracted from `applyRemoteChanges` to keep that function
  /// inside the SwiftLint body-length budget.
  nonisolated private func runBatchSavesPhase(
    saved: [CKRecord],
    systemFields: [String: Data],
    signpostID: OSSignpostID
  ) -> ApplyResult? {
    os_signpost(
      .begin, log: Signposts.sync, name: "applyBatchSaves", signpostID: signpostID,
      "%{public}d records", saved.count)
    do {
      try applyBatchSaves(saved, systemFields: systemFields)
      os_signpost(.end, log: Signposts.sync, name: "applyBatchSaves", signpostID: signpostID)
      return nil
    } catch {
      os_signpost(.end, log: Signposts.sync, name: "applyBatchSaves", signpostID: signpostID)
      logger.error(
        """
        GRDB write failed during applyBatchSaves for profile \
        \(self.profileId, privacy: .public): \
        \(error.localizedDescription, privacy: .public)
        """)
      return .saveFailed(error.localizedDescription)
    }
  }

  /// Companion to `runBatchSavesPhase` for the deletions branch.
  nonisolated private func runBatchDeletionsPhase(
    deleted: [(CKRecord.ID, String)],
    signpostID: OSSignpostID
  ) -> ApplyResult? {
    os_signpost(
      .begin, log: Signposts.sync, name: "applyBatchDeletions", signpostID: signpostID,
      "%{public}d records", deleted.count)
    do {
      try applyBatchDeletions(deleted)
      os_signpost(.end, log: Signposts.sync, name: "applyBatchDeletions", signpostID: signpostID)
      return nil
    } catch {
      os_signpost(.end, log: Signposts.sync, name: "applyBatchDeletions", signpostID: signpostID)
      logger.error(
        """
        GRDB write failed during applyBatchDeletions for profile \
        \(self.profileId, privacy: .public): \
        \(error.localizedDescription, privacy: .public)
        """)
      return .saveFailed(error.localizedDescription)
    }
  }

  /// Records timings, fires the instrument-touched observer, and
  /// returns the success outcome. Splitting this out keeps
  /// `applyRemoteChanges` inside the SwiftLint body-length budget.
  nonisolated private func reportSuccess(
    saved: [CKRecord],
    deleted: [(CKRecord.ID, String)],
    timing: BatchTiming,
    signpostID: OSSignpostID
  ) -> ApplyResult {
    logBatchDuration(
      batchStart: timing.batchStart,
      upsertDuration: timing.upsertDuration,
      saveCount: saved.count,
      deleteCount: deleted.count)
    let changedTypes = Set(saved.map(\.recordType) + deleted.map(\.1))
    // Fan out the instrument-touched signal exactly once per batch (not
    // per record). Picker UIs subscribe to the registry's
    // `observeChanges()` stream, which is local-write-driven; without
    // this hop a token registered on another device would not surface
    // until the next app launch.
    if changedTypes.contains(InstrumentRow.recordType) {
      onInstrumentRemoteChange()
    }
    return .success(changedTypes: changedTypes)
  }

  // MARK: - Batch Processing

  /// Groups saved records by type and routes each group through the
  /// GRDB dispatch table. Unknown record types are logged and skipped
  /// (`ProfileRecord` is handled by `ProfileIndexSyncHandler`, not this
  /// type).
  ///
  /// Throws when a GRDB-routed batch fails to write so the caller can
  /// return `.saveFailed(...)` and CKSyncEngine refetches instead of
  /// advancing past the dropped record (silent data loss).
  nonisolated func applyBatchSaves(
    _ records: [CKRecord], systemFields: [String: Data]
  ) throws {
    let grouped = Dictionary(grouping: records, by: \.recordType)
    for (recordType, ckRecords) in grouped {
      if try applyGRDBBatchSave(
        recordType: recordType, ckRecords: ckRecords, systemFields: systemFields)
      {
        continue
      }
      if recordType != ProfileRecord.recordType {
        // ProfileRecord is handled by ProfileIndexSyncHandler.
        Self.batchLogger.warning(
          "applyBatchSaves: unknown record type '\(recordType)' — skipping")
      }
    }
  }

  /// Handles batch deletions. Groups by record type then routes through
  /// the GRDB dispatch tables.
  ///
  /// Throws when a GRDB-routed deletion batch fails. See `applyBatchSaves`
  /// for the rationale: propagating the failure ensures CKSyncEngine
  /// refetches rather than dropping the deletion record silently.
  nonisolated func applyBatchDeletions(
    _ deletions: [(CKRecord.ID, String)]
  ) throws {
    var uuidGrouped: [String: [UUID]] = [:]
    var stringGrouped: [String: [String]] = [:]

    for (recordID, recordType) in deletions {
      if let uuid = recordID.uuid {
        uuidGrouped[recordType, default: []].append(uuid)
      } else {
        stringGrouped[recordType, default: []].append(recordID.recordName)
      }
    }

    for (recordType, ids) in uuidGrouped {
      if try applyGRDBBatchDeletion(recordType: recordType, ids: ids) {
        continue
      }
      if recordType != ProfileRecord.recordType {
        Self.batchLogger.warning(
          "applyBatchDeletions: unknown record type '\(recordType)' — skipping")
      }
    }
    for (recordType, names) in stringGrouped {
      if try applyGRDBBatchDeletion(recordType: recordType, names: names) {
        continue
      }
      Self.batchLogger.warning(
        "applyBatchDeletions: unknown string-ID record type '\(recordType)' — skipping")
    }
  }

  // MARK: - Private Helpers

  /// Builds the record-name → encoded-system-fields lookup used for
  /// batch upserts. When `preExtracted` has entries the caller has
  /// already done the extraction (and filtering) and we use it directly;
  /// otherwise we synthesise it from `saved`.
  nonisolated private static func systemFieldsLookup(
    saved: [CKRecord], preExtracted: [(String, Data)]
  ) -> [String: Data] {
    let keyFor = CKRecordIDRecordName.systemFieldsKey(for:)
    if !preExtracted.isEmpty {
      return Dictionary(
        preExtracted.map { (keyFor($0.0), $0.1) },
        uniquingKeysWith: { _, last in last })
    }
    return Dictionary(
      uniqueKeysWithValues: saved.map {
        ($0.recordID.systemFieldsKey, $0.encodedSystemFields)
      }
    )
  }

  nonisolated private func logIncomingBatch(
    saved: [CKRecord], deleted: [(CKRecord.ID, String)]
  ) {
    let typeCounts = Dictionary(grouping: saved, by: \.recordType).mapValues(\.count)
    logger.info("applyRemoteChanges: \(saved.count) saves \(typeCounts), \(deleted.count) deletes")
  }

  nonisolated private func logBatchDuration(
    batchStart: ContinuousClock.Instant,
    upsertDuration: Duration,
    saveCount: Int,
    deleteCount: Int
  ) {
    let batchMs = (ContinuousClock.now - batchStart).inMilliseconds
    guard batchMs > 100 else { return }
    let upsertMs = upsertDuration.inMilliseconds
    logger.info(
      """
      applyRemoteChanges took \(batchMs)ms \
      (upsert: \(upsertMs)ms, \(saveCount) saves, \(deleteCount) deletes)
      """)
  }
}
