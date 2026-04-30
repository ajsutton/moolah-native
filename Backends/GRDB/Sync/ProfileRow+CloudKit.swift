// Backends/GRDB/Sync/ProfileRow+CloudKit.swift

import CloudKit
import Foundation

// MARK: - ProfileRow + CloudKitRecordConvertible
//
// Replaces `Backends/CloudKit/Sync/ProfileRecord+CloudKit.swift` once
// Task 6 flips `RecordTypeRegistry.allTypes` over to `ProfileRow.self`.
// Until then the runtime still dispatches `ProfileRecord.recordType` to
// the SwiftData `ProfileRecord` class; this conformance compiles and is
// available but unused.
//
// The CloudKit wire `recordType` ("ProfileRecord") is a frozen contract
// — existing iCloud zones reference this exact string — so it stays
// unchanged regardless of the local Swift type's name.

extension ProfileRow: CloudKitRecordConvertible {
  func toCKRecord(in zoneID: CKRecordZone.ID) -> CKRecord {
    let recordID = CKRecord.ID(
      recordType: Self.recordType, uuid: id, zoneID: zoneID)
    let record = CKRecord(recordType: Self.recordType, recordID: recordID)
    ProfileRecordCloudKitFields(
      createdAt: createdAt,
      currencyCode: currencyCode,
      financialYearStartMonth: Int64(financialYearStartMonth),
      label: label
    ).write(to: record)
    return record
  }

  static func fieldValues(from ckRecord: CKRecord) -> ProfileRow? {
    guard let id = ckRecord.recordID.uuid else { return nil }
    let fields = ProfileRecordCloudKitFields(from: ckRecord)
    let monthRaw = Int(fields.financialYearStartMonth ?? 7)
    // Coerce out-of-range remote values (Slice 1 skip-and-log pattern):
    // financial_year_start_month must be 1…12 or the SQLite CHECK on
    // the GRDB profile table would reject the upsert and stall the
    // sync batch.
    let month = (1...12).contains(monthRaw) ? monthRaw : 7
    return ProfileRow(
      id: id,
      recordName: ckRecord.recordID.recordName,
      label: fields.label ?? "",
      currencyCode: fields.currencyCode ?? "",
      financialYearStartMonth: month,
      createdAt: fields.createdAt ?? Date(),
      // Stamped post-upsert by ProfileIndexSyncHandler; never read from
      // the CKRecord itself.
      encodedSystemFields: nil
    )
  }
}
