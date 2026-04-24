import CloudKit
import Foundation

/// Filename-marker enum so SwiftLint's `file_name` rule has a declared type
/// matching the filename. The extension on `CKRecord.ID` below does the work.
enum CKRecordIDRecordName {}

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

  /// Returns the UUID portion of a recordName regardless of format.
  /// Accepts `"<TYPE>|<UUID>"` (new) and `"<UUID>"` (legacy).
  /// Returns `nil` for non-UUID names (e.g. instrument IDs like `"AUD"`).
  func uuidRecordName() -> UUID? {
    if let sep = recordName.firstIndex(of: "|") {
      let uuidPart = recordName[recordName.index(after: sep)...]
      return UUID(uuidString: String(uuidPart))
    }
    return UUID(uuidString: recordName)
  }

  /// The key used for per-record system-fields caching during batch upsert.
  /// - For UUID-keyed records: the bare UUID string (prefix stripped).
  /// - For string-keyed records (instruments): the full recordName.
  ///
  /// This matches the keys used by `batchUpsertX` methods which look up
  /// `systemFields[id.uuidString]` for UUID records and `systemFields[id]`
  /// for instruments.
  var systemFieldsKey: String {
    if let sep = recordName.firstIndex(of: "|") {
      return String(recordName[recordName.index(after: sep)...])
    }
    return recordName
  }
}
