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

  /// Returns `true` when a cached recordName is safe to reuse for upload.
  ///
  /// Cached system fields produced by a build that pre-dated the
  /// `<recordType>|<UUID>` prefix (issue #416) carry a bare-UUID recordID.
  /// Reusing them would re-upload the record under the legacy recordName,
  /// which the rest of the pipeline now treats as non-UUID and drops on
  /// downlink — so a remote update would never round-trip back. Bare-UUID
  /// caches are ignored so the next upload reissues a fresh prefixed
  /// recordID. Instrument recordNames (e.g. `"AUD"`, `"ASX:BHP"`) are
  /// not UUID-shaped and pass through unchanged.
  static func isUsableCachedRecordName(_ recordName: String) -> Bool {
    if recordName.contains("|") { return true }
    return UUID(uuidString: recordName) == nil
  }
}

// `CKRecord.ID.recordName` is the primary key for a record in a zone. UUID-keyed
// records in this app encode the SwiftData record type as a prefix so two
// different types that happen to share a UUID can't collide on the server
// (issue #416). Format: `"<recordType>|<uuid.uuidString>"` for UUID records,
// `"<id>"` for string-keyed records (e.g. instruments like `"AUD"`).
//
// Bare-UUID recordNames are NOT accepted: prior to issue #416 records used
// `"<uuid.uuidString>"` directly. Persisted CKSyncEngine state from that era
// could contain bare-UUID pending changes that would parse as a UUID via
// `systemFieldsKey` and collide with the new prefixed entries during batch
// build (the dedup compares whole recordName but the lookup keys by UUID),
// causing CloudKit to reject the entire batch with `.invalidArguments` —
// "You can't save the same record twice". Treating bare UUIDs as non-UUID
// names is what breaks the collision; stale bare-UUID pending changes get
// purged on coordinator start (see SyncCoordinator+Lifecycle).
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
  /// (e.g. instrument IDs like `"AUD"`, or stale legacy bare-UUID entries
  /// from before issue #416). Requires the `"<TYPE>|<UUID>"` form — bare
  /// UUID strings deliberately return `nil`.
  var uuid: UUID? {
    guard recordName.contains("|") else { return nil }
    return UUID(uuidString: systemFieldsKey)
  }

  /// The recordType portion of the recordName for prefixed UUID-keyed
  /// records, or `nil` for instrument-style string IDs and stale legacy
  /// bare-UUID entries. Used to disambiguate batch lookups when two record
  /// types share a UUID (different prefix, same UUID) — a UUID-only lookup
  /// returns the same CKRecord for both pending changes, so the same
  /// CKRecord ends up in `recordsToSave` twice and CloudKit rejects the
  /// batch with `.invalidArguments` ("You can't save the same record twice").
  var prefixedRecordType: String? {
    guard let sep = recordName.firstIndex(of: "|") else { return nil }
    let prefix = String(recordName[..<sep])
    return prefix.isEmpty ? nil : prefix
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
