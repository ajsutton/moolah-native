import CloudKit
import Foundation

// MARK: - EarmarkBudgetItemRecord + CloudKitRecordConvertible

extension EarmarkBudgetItemRecord: CloudKitRecordConvertible {
  static let recordType = "EarmarkBudgetItemRecord"

  func toCKRecord(in zoneID: CKRecordZone.ID) -> CKRecord {
    let recordID = CKRecord.ID(
      recordType: Self.recordType, uuid: id, zoneID: zoneID)
    let record = CKRecord(recordType: Self.recordType, recordID: recordID)
    record["earmarkId"] = earmarkId.uuidString as CKRecordValue
    record["categoryId"] = categoryId.uuidString as CKRecordValue
    record["amount"] = amount as CKRecordValue
    record["instrumentId"] = instrumentId as CKRecordValue
    return record
  }

  static func fieldValues(from ckRecord: CKRecord) -> EarmarkBudgetItemRecord? {
    guard let id = ckRecord.recordID.uuid else { return nil }
    return EarmarkBudgetItemRecord(
      id: id,
      earmarkId: (ckRecord["earmarkId"] as? String).flatMap { UUID(uuidString: $0) } ?? UUID(),
      categoryId: (ckRecord["categoryId"] as? String).flatMap { UUID(uuidString: $0) } ?? UUID(),
      amount: ckRecord["amount"] as? Int64 ?? 0,
      instrumentId: ckRecord["instrumentId"] as? String ?? ""
    )
  }
}
