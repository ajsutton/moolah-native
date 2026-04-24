import CloudKit
import Foundation

// MARK: - ProfileRecord + CloudKitRecordConvertible

extension ProfileRecord: CloudKitRecordConvertible {
  static let recordType = "CD_ProfileRecord"

  func toCKRecord(in zoneID: CKRecordZone.ID) -> CKRecord {
    let recordID = CKRecord.ID(
      recordType: Self.recordType, uuid: id, zoneID: zoneID)
    let record = CKRecord(recordType: Self.recordType, recordID: recordID)
    record["label"] = label as CKRecordValue
    record["currencyCode"] = currencyCode as CKRecordValue
    record["financialYearStartMonth"] = financialYearStartMonth as CKRecordValue
    record["createdAt"] = createdAt as CKRecordValue
    return record
  }

  static func fieldValues(from ckRecord: CKRecord) -> ProfileRecord? {
    guard let id = ckRecord.recordID.uuid else { return nil }
    return ProfileRecord(
      id: id,
      label: ckRecord["label"] as? String ?? "",
      currencyCode: ckRecord["currencyCode"] as? String ?? "",
      financialYearStartMonth: ckRecord["financialYearStartMonth"] as? Int ?? 7,
      createdAt: ckRecord["createdAt"] as? Date ?? Date()
    )
  }
}
