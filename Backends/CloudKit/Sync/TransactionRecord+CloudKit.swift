import CloudKit
import Foundation

// MARK: - TransactionRecord + CloudKitRecordConvertible

extension TransactionRecord: CloudKitRecordConvertible {
  static let recordType = "CD_TransactionRecord"

  func toCKRecord(in zoneID: CKRecordZone.ID) -> CKRecord {
    let recordID = CKRecord.ID(
      recordType: Self.recordType, uuid: id, zoneID: zoneID)
    let record = CKRecord(recordType: Self.recordType, recordID: recordID)
    record["date"] = date as CKRecordValue
    if let payee { record["payee"] = payee as CKRecordValue }
    if let notes { record["notes"] = notes as CKRecordValue }
    if let recurPeriod { record["recurPeriod"] = recurPeriod as CKRecordValue }
    if let recurEvery { record["recurEvery"] = recurEvery as CKRecordValue }
    encodeImportOriginFields(into: record)
    return record
  }

  /// Encodes the optional `importOrigin*` fields onto the CKRecord.
  ///
  /// Kept separate from `toCKRecord(in:)` so the main encode function stays under
  /// SwiftLint's cyclomatic_complexity limit.
  private func encodeImportOriginFields(into record: CKRecord) {
    if let value = importOriginRawDescription {
      record["importOriginRawDescription"] = value as CKRecordValue
    }
    if let value = importOriginBankReference {
      record["importOriginBankReference"] = value as CKRecordValue
    }
    if let value = importOriginRawAmount {
      record["importOriginRawAmount"] = value as CKRecordValue
    }
    if let value = importOriginRawBalance {
      record["importOriginRawBalance"] = value as CKRecordValue
    }
    if let value = importOriginImportedAt {
      record["importOriginImportedAt"] = value as CKRecordValue
    }
    if let value = importOriginImportSessionId {
      record["importOriginImportSessionId"] = value.uuidString as CKRecordValue
    }
    if let value = importOriginSourceFilename {
      record["importOriginSourceFilename"] = value as CKRecordValue
    }
    if let value = importOriginParserIdentifier {
      record["importOriginParserIdentifier"] = value as CKRecordValue
    }
  }

  static func fieldValues(from ckRecord: CKRecord) -> TransactionRecord? {
    guard let id = ckRecord.recordID.uuid else { return nil }
    let record = TransactionRecord(
      id: id,
      date: ckRecord["date"] as? Date ?? Date(),
      payee: ckRecord["payee"] as? String,
      notes: ckRecord["notes"] as? String,
      recurPeriod: ckRecord["recurPeriod"] as? String,
      recurEvery: ckRecord["recurEvery"] as? Int
    )
    record.importOriginRawDescription = ckRecord["importOriginRawDescription"] as? String
    record.importOriginBankReference = ckRecord["importOriginBankReference"] as? String
    record.importOriginRawAmount = ckRecord["importOriginRawAmount"] as? String
    record.importOriginRawBalance = ckRecord["importOriginRawBalance"] as? String
    record.importOriginImportedAt = ckRecord["importOriginImportedAt"] as? Date
    record.importOriginImportSessionId = (ckRecord["importOriginImportSessionId"] as? String)
      .flatMap { UUID(uuidString: $0) }
    record.importOriginSourceFilename = ckRecord["importOriginSourceFilename"] as? String
    record.importOriginParserIdentifier = ckRecord["importOriginParserIdentifier"] as? String
    return record
  }
}
