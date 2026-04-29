// Backends/GRDB/Sync/EarmarkRow+CloudKit.swift

import CloudKit
import Foundation

// MARK: - EarmarkRow + CloudKitRecordConvertible
//
// Replaces `Backends/CloudKit/Sync/EarmarkRecord+CloudKit.swift`. The
// CloudKit wire `recordType` ("EarmarkRecord") is a frozen contract —
// existing iCloud zones reference this exact string — so it stays
// unchanged regardless of the local Swift type's name.

extension EarmarkRow: CloudKitRecordConvertible {
  func toCKRecord(in zoneID: CKRecordZone.ID) -> CKRecord {
    let recordID = CKRecord.ID(
      recordType: Self.recordType, uuid: id, zoneID: zoneID)
    let record = CKRecord(recordType: Self.recordType, recordID: recordID)
    EarmarkRecordCloudKitFields(
      instrumentId: instrumentId,
      isHidden: isHidden ? 1 : 0,
      name: name,
      position: Int64(position),
      savingsEndDate: savingsEndDate,
      savingsStartDate: savingsStartDate,
      savingsTarget: savingsTarget,
      savingsTargetInstrumentId: savingsTargetInstrumentId
    ).write(to: record)
    return record
  }

  static func fieldValues(from ckRecord: CKRecord) -> EarmarkRow? {
    guard let id = ckRecord.recordID.uuid else { return nil }
    let fields = EarmarkRecordCloudKitFields(from: ckRecord)
    return EarmarkRow(
      id: id,
      recordName: ckRecord.recordID.recordName,
      name: fields.name ?? "",
      position: Int(fields.position ?? 0),
      isHidden: (fields.isHidden ?? 0) != 0,
      instrumentId: fields.instrumentId,
      savingsTarget: fields.savingsTarget,
      savingsTargetInstrumentId: fields.savingsTargetInstrumentId,
      savingsStartDate: fields.savingsStartDate,
      savingsEndDate: fields.savingsEndDate,
      // Stamped by applyGRDBBatchSave after upsert; never read from the
      // CKRecord itself.
      encodedSystemFields: nil
    )
  }
}
