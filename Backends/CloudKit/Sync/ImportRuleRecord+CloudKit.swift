import CloudKit
import Foundation

// MARK: - ImportRuleRecord + CloudKitRecordConvertible

extension ImportRuleRecord: CloudKitRecordConvertible {
  static let recordType = "ImportRuleRecord"

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

  static func fieldValues(from ckRecord: CKRecord) -> ImportRuleRecord? {
    guard let id = ckRecord.recordID.uuid else { return nil }
    let fields = ImportRuleRecordCloudKitFields(from: ckRecord)
    // The convenience initializer re-encodes the conditions/actions arrays,
    // so to avoid a decode-then-re-encode round trip we go through the
    // synthesised property setters on a fresh record.
    let record = ImportRuleRecord(
      id: id,
      name: fields.name ?? "",
      enabled: (fields.enabled ?? 0) != 0,
      position: Int(fields.position ?? 0),
      matchMode: MatchMode(rawValue: fields.matchMode ?? "all") ?? .all,
      conditions: [],
      actions: [],
      accountScope: fields.accountScope.flatMap(UUID.init(uuidString:))
    )
    record.conditionsJSON = fields.conditionsJSON ?? Data()
    record.actionsJSON = fields.actionsJSON ?? Data()
    return record
  }
}
