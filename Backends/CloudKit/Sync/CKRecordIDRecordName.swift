import CloudKit
import Foundation

/// Namespace for recordName helpers used on `CKRecord.ID` and on raw
/// recordName strings. Also serves as the filename-marker type so
/// SwiftLint's `file_name` rule matches this file's name.
enum CKRecordIDRecordName {
  /// The key used for per-record system-fields caching during batch upsert,
  /// computed from a raw recordName string. See the `CKRecord.ID` extension
  /// property of the same name for the typed version used throughout the
  /// codebase; this static is for the downlink pipeline where the lookup
  /// dictionary is built from `(String, Data)` tuples whose key is a
  /// `CKRecord.ID.recordName` captured earlier off-main.
  static func systemFieldsKey(for recordName: String) -> String {
    if let sep = recordName.firstIndex(of: "|") {
      return String(recordName[recordName.index(after: sep)...])
    }
    return recordName
  }
}

// `CKRecord.ID.recordName` is the primary key for a record in a zone. UUID-keyed
// records in this app encode the SwiftData record type as a prefix so two
// different types that happen to share a UUID can't collide on the server
// (issue #416). Format: `"<recordType>|<uuid.uuidString>"` for new records.
// Legacy records already on the server continue to use bare `<uuid.uuidString>`;
// these helpers accept both formats.
extension CKRecord.ID {
  /// Constructs a prefixed recordName from a record type and UUID.
  convenience init(
    recordType: String, uuid: UUID, zoneID: CKRecordZone.ID
  ) {
    self.init(
      recordName: "\(recordType)|\(uuid.uuidString)",
      zoneID: zoneID
    )
  }

  /// The UUID portion of the recordName, or `nil` for non-UUID names
  /// (e.g. instrument IDs like `"AUD"`). Accepts both `"<TYPE>|<UUID>"`
  /// (new) and `"<UUID>"` (legacy) by parsing `systemFieldsKey`.
  var uuid: UUID? {
    UUID(uuidString: systemFieldsKey)
  }

  /// The key used for per-record system-fields caching during batch upsert.
  /// - For UUID-keyed records: the bare UUID string (prefix stripped).
  /// - For string-keyed records (instruments): the full recordName.
  ///
  /// This matches the keys used by `batchUpsertX` methods which look up
  /// `systemFields[id.uuidString]` for UUID records and `systemFields[id]`
  /// for instruments.
  var systemFieldsKey: String {
    CKRecordIDRecordName.systemFieldsKey(for: recordName)
  }
}
