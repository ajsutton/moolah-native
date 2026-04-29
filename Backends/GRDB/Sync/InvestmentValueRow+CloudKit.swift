// Backends/GRDB/Sync/InvestmentValueRow+CloudKit.swift

import CloudKit
import Foundation

// MARK: - InvestmentValueRow + CloudKitRecordConvertible
//
// Replaces `Backends/CloudKit/Sync/InvestmentValueRecord+CloudKit.swift`.
// The CloudKit wire `recordType` ("InvestmentValueRecord") is a frozen
// contract — existing iCloud zones reference this exact string — so it
// stays unchanged regardless of the local Swift type's name.

extension InvestmentValueRow: CloudKitRecordConvertible {
  func toCKRecord(in zoneID: CKRecordZone.ID) -> CKRecord {
    let recordID = CKRecord.ID(
      recordType: Self.recordType, uuid: id, zoneID: zoneID)
    let record = CKRecord(recordType: Self.recordType, recordID: recordID)
    InvestmentValueRecordCloudKitFields(
      accountId: accountId.uuidString,
      date: date,
      instrumentId: instrumentId,
      value: value
    ).write(to: record)
    return record
  }

  static func fieldValues(from ckRecord: CKRecord) -> InvestmentValueRow? {
    guard let id = ckRecord.recordID.uuid else { return nil }
    let fields = InvestmentValueRecordCloudKitFields(from: ckRecord)
    return InvestmentValueRow(
      id: id,
      recordName: ckRecord.recordID.recordName,
      accountId: fields.accountId.flatMap(UUID.init(uuidString:)) ?? UUID(),
      date: fields.date ?? Date(),
      value: fields.value ?? 0,
      instrumentId: fields.instrumentId ?? "",
      // Stamped by applyGRDBBatchSave after upsert; never read from the
      // CKRecord itself.
      encodedSystemFields: nil)
  }
}
