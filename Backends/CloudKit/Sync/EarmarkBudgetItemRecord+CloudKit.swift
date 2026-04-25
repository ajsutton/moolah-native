import CloudKit
import Foundation

// MARK: - EarmarkBudgetItemRecord + CloudKitRecordConvertible

extension EarmarkBudgetItemRecord: CloudKitRecordConvertible {
  static let recordType = "EarmarkBudgetItemRecord"

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

  static func fieldValues(from ckRecord: CKRecord) -> EarmarkBudgetItemRecord? {
    guard let id = ckRecord.recordID.uuid else { return nil }
    let fields = EarmarkBudgetItemRecordCloudKitFields(from: ckRecord)
    return EarmarkBudgetItemRecord(
      id: id,
      earmarkId: fields.earmarkId.flatMap(UUID.init(uuidString:)) ?? UUID(),
      categoryId: fields.categoryId.flatMap(UUID.init(uuidString:)) ?? UUID(),
      amount: fields.amount ?? 0,
      instrumentId: fields.instrumentId ?? ""
    )
  }
}
