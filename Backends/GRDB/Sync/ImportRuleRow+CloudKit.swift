// Backends/GRDB/Sync/ImportRuleRow+CloudKit.swift

import CloudKit
import Foundation

// MARK: - ImportRuleRow + CloudKitRecordConvertible

extension ImportRuleRow: CloudKitRecordConvertible {
  func toCKRecord(in zoneID: CKRecordZone.ID) -> CKRecord {
    let recordID = CKRecord.ID(
      recordType: Self.recordType, uuid: id, zoneID: zoneID)
    let record = CKRecord(recordType: Self.recordType, recordID: recordID)
    ImportRuleRecordCloudKitFields(
      accountScope: accountScope?.uuidString,
      actionsJSON: actionsJSON,
      conditionsJSON: conditionsJSON,
      enabled: enabled ? 1 : 0,
      matchMode: matchMode,
      name: name,
      position: Int64(position)
    ).write(to: record)
    return record
  }

  static func fieldValues(from ckRecord: CKRecord) -> ImportRuleRow? {
    guard let id = ckRecord.recordID.uuid else { return nil }
    let fields = ImportRuleRecordCloudKitFields(from: ckRecord)
    return ImportRuleRow(
      id: id,
      recordName: ckRecord.recordID.recordName,
      name: fields.name ?? "",
      enabled: (fields.enabled ?? 0) != 0,
      position: Int(fields.position ?? 0),
      matchMode: fields.matchMode ?? MatchMode.all.rawValue,
      conditionsJSON: fields.conditionsJSON ?? Data(),
      actionsJSON: fields.actionsJSON ?? Data(),
      accountScope: fields.accountScope.flatMap(UUID.init(uuidString:)),
      // Stamped by applyGRDBBatchSave after upsert; never read from the
      // CKRecord itself.
      encodedSystemFields: nil
    )
  }
}
