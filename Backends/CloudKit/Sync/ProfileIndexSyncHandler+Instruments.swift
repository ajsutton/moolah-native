// Backends/CloudKit/Sync/ProfileIndexSyncHandler+Instruments.swift

@preconcurrency import CloudKit
import Foundation
import OSLog

/// Instrument-specific helpers for the profile-index zone. Hosts
/// the partitioning, build, and conflict-merge shapes so the main
/// `ProfileIndexSyncHandler` file stays under SwiftLint's
/// `file_length` and `type_body_length` thresholds.
extension ProfileIndexSyncHandler {

  /// Partitions the fetched batch into `(profileRows, instrumentRows)`.
  /// Records of unknown types are logged and dropped.
  static func partitionSaved(
    _ saved: [CKRecord], logger: Logger
  ) -> (profileRows: [ProfileRow], instrumentRows: [InstrumentRow]) {
    var profileRows: [ProfileRow] = []
    var instrumentRows: [InstrumentRow] = []
    for record in saved {
      switch record.recordType {
      case ProfileRow.recordType:
        guard var values = ProfileRow.fieldValues(from: record) else {
          logger.error(
            "applyRemoteChanges: malformed ProfileRow recordID '\(record.recordID.recordName)' — skipping"
          )
          continue
        }
        values.encodedSystemFields = record.encodedSystemFields
        profileRows.append(values)
      case InstrumentRow.recordType:
        guard var values = InstrumentRow.fieldValues(from: record) else {
          logger.error(
            "applyRemoteChanges: malformed InstrumentRow recordID '\(record.recordID.recordName)' — skipping"
          )
          continue
        }
        values.encodedSystemFields = record.encodedSystemFields
        instrumentRows.append(values)
      default:
        logger.error(
          "applyRemoteChanges: unexpected recordType '\(record.recordType, privacy: .public)' on profile-index zone — skipping"
        )
      }
    }
    return (profileRows, instrumentRows)
  }

  /// Partitions deleted record IDs into `(profileIds, instrumentIds)`
  /// by record-name shape. UUID-decoding names go to the profile
  /// bucket; everything else is treated as an instrument id.
  static func partitionDeleted(
    _ deleted: [CKRecord.ID], logger _: Logger
  ) -> (profileIds: [UUID], instrumentIds: [String]) {
    var profileIds: [UUID] = []
    var instrumentIds: [String] = []
    for recordID in deleted {
      if let profileId = recordID.uuid {
        profileIds.append(profileId)
      } else {
        instrumentIds.append(recordID.recordName)
      }
    }
    return (profileIds, instrumentIds)
  }

  /// Looks up an `InstrumentRow` by string-keyed `recordID` and builds
  /// a CKRecord for upload. Returns `nil` when no `instrumentRepository`
  /// is wired or the row no longer exists.
  func instrumentRecordToSave(for recordID: CKRecord.ID) -> CKRecord? {
    guard let instrumentRepository else { return nil }
    do {
      guard
        let row = try instrumentRepository.fetchRowSync(id: recordID.recordName)
      else { return nil }
      return buildCKRecord(for: row)
    } catch {
      logger.error(
        "recordToSave: failed to fetch instrument row '\(recordID.recordName, privacy: .public)': \(error, privacy: .public)"
      )
      return nil
    }
  }

  /// Builds a CKRecord from a local `InstrumentRow` for upload. Same
  /// cached-system-fields shape as the `ProfileRow` builder.
  private func buildCKRecord(for row: InstrumentRow) -> CKRecord {
    let freshRecord = row.toCKRecord(in: zoneID)
    if let cachedData = row.encodedSystemFields,
      let cachedRecord = CKRecord.fromEncodedSystemFields(cachedData),
      cachedRecord.recordID.zoneID == zoneID
    {
      for key in freshRecord.allKeys() {
        cachedRecord[key] = freshRecord[key]
      }
      return cachedRecord
    }
    return freshRecord
  }

  /// Applies the spam-wins conflict merge for `InstrumentRecord`
  /// when CKSyncEngine reports `.serverRecordChanged`. The merge
  /// rule is the same one the downlink path runs in
  /// `GRDBInstrumentRegistryRepository.applyRemoteChangesSync` —
  /// `PricingStatusMerge.merge(local:incoming:)` resolves
  /// `pricingStatus` to spam if either side has it; other fields
  /// follow plain newest-wins via the upsert.
  ///
  /// The retry upload (driven by the coordinator's existing
  /// `SyncErrorRecovery.requeueFailures` path) re-queues the local
  /// row, which now carries the merged `pricingStatus`.
  func applyInstrumentServerRecordChangedMerge(serverRecord: CKRecord) {
    guard let instrumentRepository else { return }
    guard var values = InstrumentRow.fieldValues(from: serverRecord) else {
      logger.error(
        "applyInstrumentServerRecordChangedMerge: malformed serverRecord '\(serverRecord.recordID.recordName)' — skipping"
      )
      return
    }
    values.encodedSystemFields = serverRecord.encodedSystemFields
    do {
      try instrumentRepository.applyRemoteChangesSync(
        saved: [values], deleted: [])
    } catch {
      logger.error(
        "applyInstrumentServerRecordChangedMerge: \(error, privacy: .public)")
    }
  }
}
