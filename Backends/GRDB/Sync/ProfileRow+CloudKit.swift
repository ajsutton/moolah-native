// Backends/GRDB/Sync/ProfileRow+CloudKit.swift

import CloudKit
import Foundation

// MARK: - ProfileRow + CloudKitRecordConvertible
//
// Replaces `Backends/CloudKit/Sync/ProfileRecord+CloudKit.swift` once
// `RecordTypeRegistry.allTypes` maps `ProfileRecord.recordType` to
// `ProfileRow.self`. Until then the runtime still dispatches to the
// SwiftData `ProfileRecord` class; this conformance compiles and is
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
    // CloudKit permits any Int64; the GRDB profile table CHECKs
    // financial_year_start_month is between 1 and 12. Coercing
    // out-of-range or missing values to 7 (a common fiscal-year
    // start) keeps the sync batch from stalling on a single row.
    let rawMonth = fields.financialYearStartMonth.map(Int.init) ?? 7
    let month = (1...12).contains(rawMonth) ? rawMonth : 7
    return ProfileRow(
      id: id,
      recordName: ckRecord.recordID.recordName,
      label: fields.label ?? "",
      currencyCode: fields.currencyCode ?? "",
      financialYearStartMonth: month,
      // Wire-parity with the legacy ProfileRecord conformance which also
      // falls back to `Date()` when the field is absent. A stricter
      // "discard malformed record" policy is reasonable but must be
      // applied consistently across every CloudKit row type, not just
      // here — out of scope for the current change.
      createdAt: fields.createdAt ?? Date(),
      // Stamped post-upsert by ProfileIndexSyncHandler; never read from
      // the CKRecord itself.
      encodedSystemFields: nil
    )
  }
}
