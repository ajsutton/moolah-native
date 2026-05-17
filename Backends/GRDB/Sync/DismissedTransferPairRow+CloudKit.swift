// Backends/GRDB/Sync/DismissedTransferPairRow+CloudKit.swift

import CloudKit
import Foundation

// MARK: - DismissedTransferPairRow + CloudKitRecordConvertible
//
// The CloudKit wire `recordType` ("DismissedTransferPairRecord") is a
// frozen contract — existing iCloud zones reference this exact string —
// so it stays unchanged regardless of the local Swift type's name.

extension DismissedTransferPairRow: CloudKitRecordConvertible {
  func toCKRecord(in zoneID: CKRecordZone.ID) -> CKRecord {
    let recordID = CKRecord.ID(
      recordType: Self.recordType, uuid: id, zoneID: zoneID)
    let record = CKRecord(recordType: Self.recordType, recordID: recordID)
    DismissedTransferPairRecordCloudKitFields(
      dismissedAt: dismissedAt,
      transactionIdA: transactionIdA.uuidString,
      transactionIdB: transactionIdB.uuidString
    ).write(to: record)
    return record
  }

  static func fieldValues(from ckRecord: CKRecord) -> DismissedTransferPairRow? {
    guard let id = ckRecord.recordID.uuid else { return nil }
    let fields = DismissedTransferPairRecordCloudKitFields(from: ckRecord)
    guard
      let transactionIdA = fields.transactionIdA.flatMap(UUID.init(uuidString:)),
      let transactionIdB = fields.transactionIdB.flatMap(UUID.init(uuidString:))
    else { return nil }
    return DismissedTransferPairRow(
      id: id,
      recordName: ckRecord.recordID.recordName,
      transactionIdA: transactionIdA,
      transactionIdB: transactionIdB,
      dismissedAt: fields.dismissedAt ?? Date(timeIntervalSince1970: 0),
      // Stamped by applyGRDBBatchSave after upsert; never read from the
      // CKRecord itself.
      encodedSystemFields: nil
    )
  }
}
