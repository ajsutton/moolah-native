import CloudKit
import Foundation

// MARK: - CSVImportProfileRecord + CloudKitRecordConvertible

extension CSVImportProfileRecord: CloudKitRecordConvertible {
  static let recordType = "CD_CSVImportProfileRecord"

  func toCKRecord(in zoneID: CKRecordZone.ID) -> CKRecord {
    let recordID = CKRecord.ID(
      recordType: Self.recordType, uuid: id, zoneID: zoneID)
    let record = CKRecord(recordType: Self.recordType, recordID: recordID)
    record["accountId"] = accountId.uuidString as CKRecordValue
    record["parserIdentifier"] = parserIdentifier as CKRecordValue
    record["headerSignature"] = headerSignature as CKRecordValue
    if let value = filenamePattern { record["filenamePattern"] = value as CKRecordValue }
    record["deleteAfterImport"] = (deleteAfterImport ? 1 : 0) as CKRecordValue
    record["createdAt"] = createdAt as CKRecordValue
    if let value = lastUsedAt { record["lastUsedAt"] = value as CKRecordValue }
    if let value = dateFormatRawValue { record["dateFormatRawValue"] = value as CKRecordValue }
    if let value = columnRoleRawValuesEncoded {
      record["columnRoleRawValuesEncoded"] = value as CKRecordValue
    }
    return record
  }

  static func fieldValues(from ckRecord: CKRecord) -> CSVImportProfileRecord {
    let record = CSVImportProfileRecord(
      id: ckRecord.recordID.uuid ?? UUID(),
      accountId: (ckRecord["accountId"] as? String).flatMap { UUID(uuidString: $0) } ?? UUID(),
      parserIdentifier: ckRecord["parserIdentifier"] as? String ?? "",
      headerSignature: [],
      filenamePattern: ckRecord["filenamePattern"] as? String,
      deleteAfterImport: (ckRecord["deleteAfterImport"] as? Int ?? 0) != 0,
      createdAt: ckRecord["createdAt"] as? Date ?? Date(),
      lastUsedAt: ckRecord["lastUsedAt"] as? Date,
      dateFormatRawValue: ckRecord["dateFormatRawValue"] as? String,
      columnRoleRawValuesEncoded: ckRecord["columnRoleRawValuesEncoded"] as? String)
    // Store the joined headerSignature directly (init normalises via joining,
    // but the CK value already arrives pre-joined).
    record.headerSignature = ckRecord["headerSignature"] as? String ?? ""
    return record
  }
}
