import CloudKit
import Foundation

// MARK: - TransactionRecord + CloudKitRecordConvertible

extension TransactionRecord: CloudKitRecordConvertible {
  static let recordType = "TransactionRecord"

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

  static func fieldValues(from ckRecord: CKRecord) -> TransactionRecord? {
    guard let id = ckRecord.recordID.uuid else { return nil }
    let fields = TransactionRecordCloudKitFields(from: ckRecord)
    let record = TransactionRecord(
      id: id,
      date: fields.date ?? Date(),
      payee: fields.payee,
      notes: fields.notes,
      recurPeriod: fields.recurPeriod,
      recurEvery: fields.recurEvery.map(Int.init)
    )
    record.importOriginRawDescription = fields.importOriginRawDescription
    record.importOriginBankReference = fields.importOriginBankReference
    record.importOriginRawAmount = fields.importOriginRawAmount
    record.importOriginRawBalance = fields.importOriginRawBalance
    record.importOriginImportedAt = fields.importOriginImportedAt
    record.importOriginImportSessionId =
      fields.importOriginImportSessionId.flatMap(UUID.init(uuidString:))
    record.importOriginSourceFilename = fields.importOriginSourceFilename
    record.importOriginParserIdentifier = fields.importOriginParserIdentifier
    return record
  }
}
