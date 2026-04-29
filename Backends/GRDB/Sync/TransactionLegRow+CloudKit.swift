// Backends/GRDB/Sync/TransactionLegRow+CloudKit.swift

import CloudKit
import Foundation

// MARK: - TransactionLegRow + CloudKitRecordConvertible
//
// Replaces `Backends/CloudKit/Sync/TransactionLegRecord+CloudKit.swift`.
// The CloudKit wire `recordType` ("TransactionLegRecord") is a frozen
// contract — existing iCloud zones reference this exact string — so it
// stays unchanged regardless of the local Swift type's name.

extension TransactionLegRow: CloudKitRecordConvertible {
  func toCKRecord(in zoneID: CKRecordZone.ID) -> CKRecord {
    let recordID = CKRecord.ID(
      recordType: Self.recordType, uuid: id, zoneID: zoneID)
    let record = CKRecord(recordType: Self.recordType, recordID: recordID)
    TransactionLegRecordCloudKitFields(
      accountId: accountId?.uuidString,
      categoryId: categoryId?.uuidString,
      earmarkId: earmarkId?.uuidString,
      instrumentId: instrumentId,
      quantity: quantity,
      sortOrder: Int64(sortOrder),
      transactionId: transactionId.uuidString,
      type: type
    ).write(to: record)
    return record
  }

  static func fieldValues(from ckRecord: CKRecord) -> TransactionLegRow? {
    guard let id = ckRecord.recordID.uuid else { return nil }
    let fields = TransactionLegRecordCloudKitFields(from: ckRecord)
    return TransactionLegRow(
      id: id,
      recordName: ckRecord.recordID.recordName,
      transactionId: fields.transactionId.flatMap(UUID.init(uuidString:)) ?? UUID(),
      accountId: fields.accountId.flatMap(UUID.init(uuidString:)),
      instrumentId: fields.instrumentId ?? "",
      quantity: fields.quantity ?? 0,
      type: fields.type ?? "expense",
      categoryId: fields.categoryId.flatMap(UUID.init(uuidString:)),
      earmarkId: fields.earmarkId.flatMap(UUID.init(uuidString:)),
      sortOrder: Int(fields.sortOrder ?? 0),
      // Stamped by applyGRDBBatchSave after upsert; never read from the
      // CKRecord itself.
      encodedSystemFields: nil
    )
  }
}
