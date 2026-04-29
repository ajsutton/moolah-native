// Backends/GRDB/Records/ProfileRow+Mapping.swift

import Foundation

extension ProfileRow {
  /// Frozen CloudKit wire name. Slice 3 keeps the same string the
  /// SwiftData `ProfileRecord` used so the existing `profile-index`
  /// zone resolves both record types to the same wire contract.
  static let recordType = "ProfileRecord"

  /// Canonical CloudKit `recordName` for a UUID-keyed profile. Mirrors
  /// the shape (`"<recordType>|<uuid>"`) used everywhere else in the
  /// sync layer (`Backends/CloudKit/Sync/CKRecordIDRecordName.swift`).
  static func recordName(for id: UUID) -> String {
    "\(recordType)|\(id.uuidString)"
  }

  /// Builds a row from a domain `Profile`. `encodedSystemFields` is set
  /// to `nil`; the repository preserves any pre-existing blob inside
  /// its write closure so a cross-device upsert never strips the
  /// CKRecord change tag.
  init(domain profile: Profile) {
    self.init(
      id: profile.id,
      recordName: ProfileRow.recordName(for: profile.id),
      label: profile.label,
      currencyCode: profile.currencyCode,
      financialYearStartMonth: profile.financialYearStartMonth,
      createdAt: profile.createdAt,
      encodedSystemFields: nil)
  }

  /// Domain projection. `Profile`'s designated initialiser carries the
  /// full set of stored properties; nothing is computed at the mapping
  /// boundary so the round-trip is total.
  func toDomain() -> Profile {
    Profile(
      id: id,
      label: label,
      currencyCode: currencyCode,
      financialYearStartMonth: financialYearStartMonth,
      createdAt: createdAt)
  }
}
