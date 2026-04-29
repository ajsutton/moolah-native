// Backends/GRDB/Sync/TransactionRow+CloudKit.swift

import CloudKit
import Foundation

// MARK: - TransactionRow + CloudKitRecordConvertible
//
// Replaces `Backends/CloudKit/Sync/TransactionRecord+CloudKit.swift`. The
// CloudKit wire `recordType` ("TransactionRecord") is a frozen contract —
// existing iCloud zones reference this exact string — so it stays
// unchanged regardless of the local Swift type's name.

extension TransactionRow: CloudKitRecordConvertible {
  func toCKRecord(in zoneID: CKRecordZone.ID) -> CKRecord {
    let recordID = CKRecord.ID(
      recordType: Self.recordType, uuid: id, zoneID: zoneID)
    let record = CKRecord(recordType: Self.recordType, recordID: recordID)
    TransactionRecordCloudKitFields(
      date: date,
      importOriginBankReference: importOriginBankReference,
      importOriginImportSessionId: importOriginImportSessionId?.uuidString,
      importOriginImportedAt: importOriginImportedAt,
      importOriginParserIdentifier: importOriginParserIdentifier,
      importOriginRawAmount: importOriginRawAmount,
      importOriginRawBalance: importOriginRawBalance,
      importOriginRawDescription: importOriginRawDescription,
      importOriginSourceFilename: importOriginSourceFilename,
      notes: notes,
      payee: payee,
      recurEvery: recurEvery.map(Int64.init),
      recurPeriod: recurPeriod
    ).write(to: record)
    return record
  }

  static func fieldValues(from ckRecord: CKRecord) -> TransactionRow? {
    guard let id = ckRecord.recordID.uuid else { return nil }
    let fields = TransactionRecordCloudKitFields(from: ckRecord)
    return TransactionRow(
      id: id,
      recordName: ckRecord.recordID.recordName,
      date: fields.date ?? Date(),
      payee: fields.payee,
      notes: fields.notes,
      recurPeriod: fields.recurPeriod,
      recurEvery: fields.recurEvery.map(Int.init),
      importOriginRawDescription: fields.importOriginRawDescription,
      importOriginBankReference: fields.importOriginBankReference,
      importOriginRawAmount: fields.importOriginRawAmount,
      importOriginRawBalance: fields.importOriginRawBalance,
      importOriginImportedAt: fields.importOriginImportedAt,
      importOriginImportSessionId:
        fields.importOriginImportSessionId.flatMap(UUID.init(uuidString:)),
      importOriginSourceFilename: fields.importOriginSourceFilename,
      importOriginParserIdentifier: fields.importOriginParserIdentifier,
      // Stamped by applyGRDBBatchSave after upsert; never read from the
      // CKRecord itself.
      encodedSystemFields: nil
    )
  }
}
