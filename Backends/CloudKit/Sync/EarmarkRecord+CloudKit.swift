import CloudKit
import Foundation

// MARK: - EarmarkRecord + CloudKitRecordConvertible

extension EarmarkRecord: CloudKitRecordConvertible {
  static let recordType = "CD_EarmarkRecord"

  func toCKRecord(in zoneID: CKRecordZone.ID) -> CKRecord {
    let recordID = CKRecord.ID(
      recordType: Self.recordType, uuid: id, zoneID: zoneID)
    let record = CKRecord(recordType: Self.recordType, recordID: recordID)
    record["name"] = name as CKRecordValue
    if let instrumentId { record["instrumentId"] = instrumentId as CKRecordValue }
    record["position"] = position as CKRecordValue
    record["isHidden"] = (isHidden ? 1 : 0) as CKRecordValue
    if let savingsTarget { record["savingsTarget"] = savingsTarget as CKRecordValue }
    if let savingsTargetInstrumentId {
      record["savingsTargetInstrumentId"] = savingsTargetInstrumentId as CKRecordValue
    }
    if let savingsStartDate { record["savingsStartDate"] = savingsStartDate as CKRecordValue }
    if let savingsEndDate { record["savingsEndDate"] = savingsEndDate as CKRecordValue }
    return record
  }

  static func fieldValues(from ckRecord: CKRecord) -> EarmarkRecord {
    EarmarkRecord(
      id: ckRecord.recordID.uuid ?? UUID(),
      name: ckRecord["name"] as? String ?? "",
      position: ckRecord["position"] as? Int ?? 0,
      isHidden: (ckRecord["isHidden"] as? Int ?? 0) != 0,
      instrumentId: ckRecord["instrumentId"] as? String,
      savingsTarget: ckRecord["savingsTarget"] as? Int64,
      savingsTargetInstrumentId: ckRecord["savingsTargetInstrumentId"] as? String,
      savingsStartDate: ckRecord["savingsStartDate"] as? Date,
      savingsEndDate: ckRecord["savingsEndDate"] as? Date
    )
  }
}
