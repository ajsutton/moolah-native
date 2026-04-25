import CloudKit
import Foundation

// MARK: - AccountRecord + CloudKitRecordConvertible

extension AccountRecord: CloudKitRecordConvertible {
  static let recordType = "AccountRecord"

  func toCKRecord(in zoneID: CKRecordZone.ID) -> CKRecord {
    let recordID = CKRecord.ID(
      recordType: Self.recordType, uuid: id, zoneID: zoneID)
    let record = CKRecord(recordType: Self.recordType, recordID: recordID)
    record["name"] = name as CKRecordValue
    record["type"] = type as CKRecordValue
    record["instrumentId"] = instrumentId as CKRecordValue
    record["position"] = position as CKRecordValue
    record["isHidden"] = (isHidden ? 1 : 0) as CKRecordValue
    return record
  }

  static func fieldValues(from ckRecord: CKRecord) -> AccountRecord? {
    guard let id = ckRecord.recordID.uuid else { return nil }
    return AccountRecord(
      id: id,
      name: ckRecord["name"] as? String ?? "",
      type: ckRecord["type"] as? String ?? "bank",
      instrumentId: ckRecord["instrumentId"] as? String ?? "AUD",
      position: ckRecord["position"] as? Int ?? 0,
      isHidden: (ckRecord["isHidden"] as? Int ?? 0) != 0
    )
  }
}
