import CloudKit
import Foundation

// MARK: - TransactionLegRecord + CloudKitRecordConvertible

extension TransactionLegRecord: CloudKitRecordConvertible {
  static let recordType = "CD_TransactionLegRecord"

  func toCKRecord(in zoneID: CKRecordZone.ID) -> CKRecord {
    let recordID = CKRecord.ID(
      recordType: Self.recordType, uuid: id, zoneID: zoneID)
    let record = CKRecord(recordType: Self.recordType, recordID: recordID)
    record["transactionId"] = transactionId.uuidString as CKRecordValue
    if let accountId { record["accountId"] = accountId.uuidString as CKRecordValue }
    record["instrumentId"] = instrumentId as CKRecordValue
    record["quantity"] = quantity as CKRecordValue
    record["type"] = type as CKRecordValue
    if let categoryId { record["categoryId"] = categoryId.uuidString as CKRecordValue }
    if let earmarkId { record["earmarkId"] = earmarkId.uuidString as CKRecordValue }
    record["sortOrder"] = sortOrder as CKRecordValue
    return record
  }

  static func fieldValues(from ckRecord: CKRecord) -> TransactionLegRecord {
    TransactionLegRecord(
      id: ckRecord.recordID.uuid ?? UUID(),
      transactionId: (ckRecord["transactionId"] as? String).flatMap { UUID(uuidString: $0) }
        ?? UUID(),
      accountId: (ckRecord["accountId"] as? String).flatMap { UUID(uuidString: $0) },
      instrumentId: ckRecord["instrumentId"] as? String ?? "",
      quantity: ckRecord["quantity"] as? Int64 ?? 0,
      type: ckRecord["type"] as? String ?? "expense",
      categoryId: (ckRecord["categoryId"] as? String).flatMap { UUID(uuidString: $0) },
      earmarkId: (ckRecord["earmarkId"] as? String).flatMap { UUID(uuidString: $0) },
      sortOrder: ckRecord["sortOrder"] as? Int ?? 0
    )
  }
}
