// Backends/GRDB/Sync/EarmarkBudgetItemRow+CloudKit.swift

import CloudKit
import Foundation

// MARK: - EarmarkBudgetItemRow + CloudKitRecordConvertible
//
// Replaces `Backends/CloudKit/Sync/EarmarkBudgetItemRecord+CloudKit.swift`.
// The CloudKit wire `recordType` ("EarmarkBudgetItemRecord") is a frozen
// contract — existing iCloud zones reference this exact string — so it
// stays unchanged regardless of the local Swift type's name.

extension EarmarkBudgetItemRow: CloudKitRecordConvertible {
  func toCKRecord(in zoneID: CKRecordZone.ID) -> CKRecord {
    let recordID = CKRecord.ID(
      recordType: Self.recordType, uuid: id, zoneID: zoneID)
    let record = CKRecord(recordType: Self.recordType, recordID: recordID)
    EarmarkBudgetItemRecordCloudKitFields(
      amount: amount,
      categoryId: categoryId.uuidString,
      earmarkId: earmarkId.uuidString,
      instrumentId: instrumentId
    ).write(to: record)
    return record
  }

  static func fieldValues(from ckRecord: CKRecord) -> EarmarkBudgetItemRow? {
    guard let id = ckRecord.recordID.uuid else { return nil }
    let fields = EarmarkBudgetItemRecordCloudKitFields(from: ckRecord)
    // Both FKs are required; bail rather than minting placeholder UUIDs
    // that would point at no row.
    guard
      let earmarkId = fields.earmarkId.flatMap(UUID.init(uuidString:)),
      let categoryId = fields.categoryId.flatMap(UUID.init(uuidString:))
    else {
      return nil
    }
    return EarmarkBudgetItemRow(
      id: id,
      recordName: ckRecord.recordID.recordName,
      earmarkId: earmarkId,
      categoryId: categoryId,
      amount: fields.amount ?? 0,
      instrumentId: fields.instrumentId ?? "",
      // Stamped by applyGRDBBatchSave after upsert; never read from the
      // CKRecord itself.
      encodedSystemFields: nil
    )
  }
}
