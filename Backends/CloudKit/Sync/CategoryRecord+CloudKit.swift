import CloudKit
import Foundation

// MARK: - CategoryRecord + CloudKitRecordConvertible

extension CategoryRecord: CloudKitRecordConvertible {
  static let recordType = "CategoryRecord"

  func toCKRecord(in zoneID: CKRecordZone.ID) -> CKRecord {
    let recordID = CKRecord.ID(
      recordType: Self.recordType, uuid: id, zoneID: zoneID)
    let record = CKRecord(recordType: Self.recordType, recordID: recordID)
    CategoryRecordCloudKitFields(
      name: name,
      parentId: parentId?.uuidString
    ).write(to: record)
    return record
  }

  static func fieldValues(from ckRecord: CKRecord) -> CategoryRecord? {
    guard let id = ckRecord.recordID.uuid else { return nil }
    let fields = CategoryRecordCloudKitFields(from: ckRecord)
    return CategoryRecord(
      id: id,
      name: fields.name ?? "",
      parentId: fields.parentId.flatMap(UUID.init(uuidString:))
    )
  }
}
