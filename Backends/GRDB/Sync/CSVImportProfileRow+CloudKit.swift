// Backends/GRDB/Sync/CSVImportProfileRow+CloudKit.swift

import CloudKit
import Foundation

// MARK: - CSVImportProfileRow + CloudKitRecordConvertible
//
// Mirrors the previous SwiftData-backed
// `Backends/CloudKit/Sync/CSVImportProfileRecord+CloudKit.swift`. The
// CloudKit wire `recordType` ("CSVImportProfileRecord") is a frozen
// contract — existing iCloud zones reference this exact string — so it
// stays unchanged regardless of the local Swift type's name.

extension CSVImportProfileRow: CloudKitRecordConvertible {
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

  static func fieldValues(from ckRecord: CKRecord) -> CSVImportProfileRow? {
    guard let id = ckRecord.recordID.uuid else { return nil }
    let fields = CSVImportProfileRecordCloudKitFields(from: ckRecord)
    return CSVImportProfileRow(
      id: id,
      recordName: ckRecord.recordID.recordName,
      accountId: fields.accountId.flatMap(UUID.init(uuidString:)) ?? UUID(),
      parserIdentifier: fields.parserIdentifier ?? "",
      // The CK value already arrives unit-separator joined — keep it
      // as-is so the migrator's bit-for-bit copy preserves the wire
      // bytes.
      headerSignature: fields.headerSignature ?? "",
      filenamePattern: fields.filenamePattern,
      deleteAfterImport: (fields.deleteAfterImport ?? 0) != 0,
      createdAt: fields.createdAt ?? Date(),
      lastUsedAt: fields.lastUsedAt,
      dateFormatRawValue: fields.dateFormatRawValue,
      columnRoleRawValuesEncoded: fields.columnRoleRawValuesEncoded,
      // Stamped by applyGRDBBatchSave after upsert; never read from the
      // CKRecord itself.
      encodedSystemFields: nil
    )
  }
}
