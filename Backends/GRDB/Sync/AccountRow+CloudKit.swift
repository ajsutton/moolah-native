// Backends/GRDB/Sync/AccountRow+CloudKit.swift

import CloudKit
import Foundation

// MARK: - AccountRow + CloudKitRecordConvertible
//
// Replaces `Backends/CloudKit/Sync/AccountRecord+CloudKit.swift`. The
// CloudKit wire `recordType` ("AccountRecord") is a frozen contract —
// existing iCloud zones reference this exact string — so it stays
// unchanged regardless of the local Swift type's name.

extension AccountRow: CloudKitRecordConvertible {
  func toCKRecord(in zoneID: CKRecordZone.ID) -> CKRecord {
    let recordID = CKRecord.ID(
      recordType: Self.recordType, uuid: id, zoneID: zoneID)
    let record = CKRecord(recordType: Self.recordType, recordID: recordID)
    AccountRecordCloudKitFields(
      instrumentId: instrumentId,
      isHidden: isHidden ? 1 : 0,
      name: name,
      position: Int64(position),
      type: type,
      valuationMode: valuationMode
    ).write(to: record)
    return record
  }

  static func fieldValues(from ckRecord: CKRecord) -> AccountRow? {
    guard let id = ckRecord.recordID.uuid else { return nil }
    let fields = AccountRecordCloudKitFields(from: ckRecord)
    return AccountRow(
      id: id,
      recordName: ckRecord.recordID.recordName,
      name: fields.name ?? "",
      type: fields.type ?? "bank",
      instrumentId: fields.instrumentId ?? "AUD",
      position: Int(fields.position ?? 0),
      isHidden: (fields.isHidden ?? 0) != 0,
      // Stamped by applyGRDBBatchSave after upsert; never read from the
      // CKRecord itself.
      encodedSystemFields: nil,
      valuationMode: fields.valuationMode ?? "recordedValue"
    )
  }
}
