import CloudKit
import Foundation

// MARK: - AccountRecord + CloudKitRecordConvertible

extension AccountRecord: CloudKitRecordConvertible {
  static let recordType = "CD_AccountRecord"

  func toCKRecord(in zoneID: CKRecordZone.ID) -> CKRecord {
    let recordID = CKRecord.ID(recordName: id.uuidString, zoneID: zoneID)
    let record = CKRecord(recordType: Self.recordType, recordID: recordID)
    record["name"] = name as CKRecordValue
    record["type"] = type as CKRecordValue
    record["instrumentId"] = instrumentId as CKRecordValue
    record["position"] = position as CKRecordValue
    record["isHidden"] = (isHidden ? 1 : 0) as CKRecordValue
    return record
  }

  static func fieldValues(from ckRecord: CKRecord) -> AccountRecord {
    AccountRecord(
      id: UUID(uuidString: ckRecord.recordID.recordName) ?? UUID(),
      name: ckRecord["name"] as? String ?? "",
      type: ckRecord["type"] as? String ?? "bank",
      instrumentId: ckRecord["instrumentId"] as? String ?? "AUD",
      position: ckRecord["position"] as? Int ?? 0,
      isHidden: (ckRecord["isHidden"] as? Int ?? 0) != 0
    )
  }
}
