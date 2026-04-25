import CloudKit
import Foundation

// MARK: - InvestmentValueRecord + CloudKitRecordConvertible

extension InvestmentValueRecord: CloudKitRecordConvertible {
  static let recordType = "InvestmentValueRecord"

  func toCKRecord(in zoneID: CKRecordZone.ID) -> CKRecord {
    let recordID = CKRecord.ID(
      recordType: Self.recordType, uuid: id, zoneID: zoneID)
    let record = CKRecord(recordType: Self.recordType, recordID: recordID)
    record["accountId"] = accountId.uuidString as CKRecordValue
    record["date"] = date as CKRecordValue
    record["value"] = value as CKRecordValue
    record["instrumentId"] = instrumentId as CKRecordValue
    return record
  }

  static func fieldValues(from ckRecord: CKRecord) -> InvestmentValueRecord? {
    guard let id = ckRecord.recordID.uuid else { return nil }
    return InvestmentValueRecord(
      id: id,
      accountId: (ckRecord["accountId"] as? String).flatMap { UUID(uuidString: $0) } ?? UUID(),
      date: ckRecord["date"] as? Date ?? Date(),
      value: ckRecord["value"] as? Int64 ?? 0,
      instrumentId: ckRecord["instrumentId"] as? String ?? ""
    )
  }
}
