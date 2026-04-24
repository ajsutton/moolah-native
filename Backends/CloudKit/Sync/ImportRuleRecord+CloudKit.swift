import CloudKit
import Foundation

// MARK: - ImportRuleRecord + CloudKitRecordConvertible

extension ImportRuleRecord: CloudKitRecordConvertible {
  static let recordType = "CD_ImportRuleRecord"

  func toCKRecord(in zoneID: CKRecordZone.ID) -> CKRecord {
    let recordID = CKRecord.ID(
      recordType: Self.recordType, uuid: id, zoneID: zoneID)
    let record = CKRecord(recordType: Self.recordType, recordID: recordID)
    record["name"] = name as CKRecordValue
    record["enabled"] = (enabled ? 1 : 0) as CKRecordValue
    record["position"] = position as CKRecordValue
    record["matchMode"] = matchMode as CKRecordValue
    record["conditionsJSON"] = conditionsJSON as CKRecordValue
    record["actionsJSON"] = actionsJSON as CKRecordValue
    if let value = accountScope { record["accountScope"] = value.uuidString as CKRecordValue }
    return record
  }

  static func fieldValues(from ckRecord: CKRecord) -> ImportRuleRecord {
    let id = ckRecord.recordID.uuid ?? UUID()
    // The convenience initializer re-encodes the conditions/actions arrays,
    // so to avoid a decode-then-re-encode round trip we go through the
    // synthesised property setters on a fresh record.
    let record = ImportRuleRecord(
      id: id,
      name: ckRecord["name"] as? String ?? "",
      enabled: (ckRecord["enabled"] as? Int ?? 0) != 0,
      position: ckRecord["position"] as? Int ?? 0,
      matchMode: MatchMode(rawValue: ckRecord["matchMode"] as? String ?? "all") ?? .all,
      conditions: [],
      actions: [],
      accountScope: (ckRecord["accountScope"] as? String).flatMap { UUID(uuidString: $0) })
    record.conditionsJSON = ckRecord["conditionsJSON"] as? Data ?? Data()
    record.actionsJSON = ckRecord["actionsJSON"] as? Data ?? Data()
    return record
  }
}
