import CloudKit
import Foundation

// MARK: - ProfileRecord + CloudKitRecordConvertible

extension ProfileRecord: CloudKitRecordConvertible {
  static let recordType = "ProfileRecord"

  func toCKRecord(in zoneID: CKRecordZone.ID) -> CKRecord {
    let recordID = CKRecord.ID(
      recordType: Self.recordType, uuid: id, zoneID: zoneID)
    let record = CKRecord(recordType: Self.recordType, recordID: recordID)
    ProfileRecordCloudKitFields(
      createdAt: createdAt,
      currencyCode: currencyCode,
      financialYearStartMonth: Int64(financialYearStartMonth),
      label: label
    ).write(to: record)
    return record
  }

  static func fieldValues(from ckRecord: CKRecord) -> ProfileRecord? {
    guard let id = ckRecord.recordID.uuid else { return nil }
    let fields = ProfileRecordCloudKitFields(from: ckRecord)
    return ProfileRecord(
      id: id,
      label: fields.label ?? "",
      currencyCode: fields.currencyCode ?? "",
      financialYearStartMonth: Int(fields.financialYearStartMonth ?? 7),
      createdAt: fields.createdAt ?? Date()
    )
  }
}
