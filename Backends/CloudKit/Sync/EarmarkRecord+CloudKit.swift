import CloudKit
import Foundation

// MARK: - EarmarkRecord + CloudKitRecordConvertible

extension EarmarkRecord: CloudKitRecordConvertible {
  static let recordType = "EarmarkRecord"

  func toCKRecord(in zoneID: CKRecordZone.ID) -> CKRecord {
    let recordID = CKRecord.ID(
      recordType: Self.recordType, uuid: id, zoneID: zoneID)
    let record = CKRecord(recordType: Self.recordType, recordID: recordID)
    EarmarkRecordCloudKitFields(
      instrumentId: instrumentId,
      isHidden: isHidden ? 1 : 0,
      name: name,
      position: Int64(position),
      savingsEndDate: savingsEndDate,
      savingsStartDate: savingsStartDate,
      savingsTarget: savingsTarget,
      savingsTargetInstrumentId: savingsTargetInstrumentId
    ).write(to: record)
    return record
  }

  static func fieldValues(from ckRecord: CKRecord) -> EarmarkRecord? {
    guard let id = ckRecord.recordID.uuid else { return nil }
    let fields = EarmarkRecordCloudKitFields(from: ckRecord)
    return EarmarkRecord(
      id: id,
      name: fields.name ?? "",
      position: Int(fields.position ?? 0),
      isHidden: (fields.isHidden ?? 0) != 0,
      instrumentId: fields.instrumentId,
      savingsTarget: fields.savingsTarget,
      savingsTargetInstrumentId: fields.savingsTargetInstrumentId,
      savingsStartDate: fields.savingsStartDate,
      savingsEndDate: fields.savingsEndDate
    )
  }
}
