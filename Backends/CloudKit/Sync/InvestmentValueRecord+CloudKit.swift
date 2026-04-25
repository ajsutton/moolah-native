import CloudKit
import Foundation

// MARK: - InvestmentValueRecord + CloudKitRecordConvertible

extension InvestmentValueRecord: CloudKitRecordConvertible {
  static let recordType = "InvestmentValueRecord"

  func toCKRecord(in zoneID: CKRecordZone.ID) -> CKRecord {
    let recordID = CKRecord.ID(
      recordType: Self.recordType, uuid: id, zoneID: zoneID)
    let record = CKRecord(recordType: Self.recordType, recordID: recordID)
    InvestmentValueRecordCloudKitFields(
      accountId: accountId.uuidString,
      date: date,
      instrumentId: instrumentId,
      value: value
    ).write(to: record)
    return record
  }

  static func fieldValues(from ckRecord: CKRecord) -> InvestmentValueRecord? {
    guard let id = ckRecord.recordID.uuid else { return nil }
    let fields = InvestmentValueRecordCloudKitFields(from: ckRecord)
    return InvestmentValueRecord(
      id: id,
      accountId: fields.accountId.flatMap(UUID.init(uuidString:)) ?? UUID(),
      date: fields.date ?? Date(),
      value: fields.value ?? 0,
      instrumentId: fields.instrumentId ?? ""
    )
  }
}
