import CloudKit
import Foundation

// MARK: - CategoryRecord + CloudKitRecordConvertible

extension CategoryRecord: CloudKitRecordConvertible {
  static let recordType = "CD_CategoryRecord"

  func toCKRecord(in zoneID: CKRecordZone.ID) -> CKRecord {
    let recordID = CKRecord.ID(
      recordType: Self.recordType, uuid: id, zoneID: zoneID)
    let record = CKRecord(recordType: Self.recordType, recordID: recordID)
    record["name"] = name as CKRecordValue
    if let parentId { record["parentId"] = parentId.uuidString as CKRecordValue }
    return record
  }

  static func fieldValues(from ckRecord: CKRecord) -> CategoryRecord? {
    guard let id = ckRecord.recordID.uuid else { return nil }
    return CategoryRecord(
      id: id,
      name: ckRecord["name"] as? String ?? "",
      parentId: (ckRecord["parentId"] as? String).flatMap { UUID(uuidString: $0) }
    )
  }
}
