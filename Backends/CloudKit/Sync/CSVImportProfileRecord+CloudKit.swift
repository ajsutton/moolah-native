import CloudKit
import Foundation

// MARK: - CSVImportProfileRecord + CloudKitRecordConvertible

extension CSVImportProfileRecord: CloudKitRecordConvertible {
  static let recordType = "CSVImportProfileRecord"

  func toCKRecord(in zoneID: CKRecordZone.ID) -> CKRecord {
    let recordID = CKRecord.ID(
      recordType: Self.recordType, uuid: id, zoneID: zoneID)
    let record = CKRecord(recordType: Self.recordType, recordID: recordID)
    CSVImportProfileRecordCloudKitFields(
      accountId: accountId.uuidString,
      columnRoleRawValuesEncoded: columnRoleRawValuesEncoded,
      createdAt: createdAt,
      dateFormatRawValue: dateFormatRawValue,
      deleteAfterImport: deleteAfterImport ? 1 : 0,
      filenamePattern: filenamePattern,
      headerSignature: headerSignature,
      lastUsedAt: lastUsedAt,
      parserIdentifier: parserIdentifier
    ).write(to: record)
    return record
  }

  static func fieldValues(from ckRecord: CKRecord) -> CSVImportProfileRecord? {
    guard let id = ckRecord.recordID.uuid else { return nil }
    let fields = CSVImportProfileRecordCloudKitFields(from: ckRecord)
    let record = CSVImportProfileRecord(
      id: id,
      accountId: fields.accountId.flatMap(UUID.init(uuidString:)) ?? UUID(),
      parserIdentifier: fields.parserIdentifier ?? "",
      headerSignature: [],
      filenamePattern: fields.filenamePattern,
      deleteAfterImport: (fields.deleteAfterImport ?? 0) != 0,
      createdAt: fields.createdAt ?? Date(),
      lastUsedAt: fields.lastUsedAt,
      dateFormatRawValue: fields.dateFormatRawValue,
      columnRoleRawValuesEncoded: fields.columnRoleRawValuesEncoded
    )
    // Store the joined headerSignature directly (init normalises via joining,
    // but the CK value already arrives pre-joined).
    record.headerSignature = fields.headerSignature ?? ""
    return record
  }
}
