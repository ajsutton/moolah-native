@preconcurrency import CloudKit
import Foundation
import OSLog
import SwiftData
import os

/// Result of applying remote changes from CKSyncEngine.
enum ApplyResult: Sendable {
  /// Changes saved successfully. Contains the set of changed record types.
  case success(changedTypes: Set<String>)
  /// context.save() failed. The coordinator should schedule a re-fetch.
  case saveFailed(String)
}

/// Stateless batch processing logic for a single profile's data zone.
/// Contains all data transformation, upsert, deletion, and record-building
/// logic with no CKSyncEngine dependency.
///
/// The coordinator owns the CKSyncEngine instance and delegates data processing
/// to this handler. Methods return results (changed types, record IDs, failures)
/// instead of directly interacting with CKSyncEngine state.
///
/// Functionality is split across several `ProfileDataSyncHandler+*.swift`
/// extensions (applying remote changes, batch upserts, record lookup, queueing,
/// and system fields) so that each file keeps a single focus.
@MainActor
final class ProfileDataSyncHandler {
  nonisolated let profileId: UUID
  nonisolated let zoneID: CKRecordZone.ID
  nonisolated let modelContainer: ModelContainer
  /// GRDB-backed repos for the record types migrated to SQLite. Used by
  /// the dispatch tables in `+ApplyRemoteChanges`, `+QueueAndDelete`,
  /// `+RecordLookup`, and `+SystemFields` for the two record types
  /// covered by `v2_csv_import_and_rules`. Subsequent slices extend the
  /// list.
  nonisolated let grdbRepositories: ProfileGRDBRepositories

  /// Closure fired from `applyRemoteChanges` whenever a remote pull touches
  /// any `InstrumentRecord` row (insert, update, or delete). Wired by
  /// `ProfileSession` to call `CloudKitInstrumentRegistryRepository.notifyExternalChange()`
  /// so picker UIs that subscribe via `observeChanges()` refresh after a
  /// token registered on another device arrives — without this, the
  /// registry's notify path only fires on local writes. Defaults to a
  /// no-op so non-iCloud and test callers don't need to provide one.
  nonisolated let onInstrumentRemoteChange: @Sendable () -> Void

  nonisolated let logger = Logger(
    subsystem: "com.moolah.app", category: "ProfileDataSyncHandler")

  /// Logger used by `nonisolated static` batch helpers that cannot reach `self.logger`.
  nonisolated static let batchLogger = Logger(
    subsystem: "com.moolah.app", category: "ProfileDataSyncHandler")

  init(
    profileId: UUID,
    zoneID: CKRecordZone.ID,
    modelContainer: ModelContainer,
    grdbRepositories: ProfileGRDBRepositories,
    onInstrumentRemoteChange: @escaping @Sendable () -> Void = {}
  ) {
    self.profileId = profileId
    self.zoneID = zoneID
    self.modelContainer = modelContainer
    self.grdbRepositories = grdbRepositories
    self.onInstrumentRemoteChange = onInstrumentRemoteChange
  }

  // MARK: - Building CKRecords

  /// Builds a `CKRecord` from a GRDB row for upload.
  ///
  /// If cached system fields exist for this row, applies fields
  /// directly onto the cached record to preserve the change tag and
  /// avoid `.serverRecordChanged` conflicts. If the cached system
  /// fields reference a *different* zone than this handler's own zone,
  /// they are discarded and the record is uploaded as a fresh create
  /// in the handler's zone — defence-in-depth against legacy
  /// corruption from before per-zone fetches were introduced.
  func buildCKRecord<T: CloudKitRecordConvertible>(
    from record: T, encodedSystemFields: Data?
  ) -> CKRecord {
    let freshRecord = record.toCKRecord(in: zoneID)
    if let cachedData = encodedSystemFields,
      let cachedRecord = CKRecord.fromEncodedSystemFields(cachedData),
      cachedRecord.recordID.zoneID == zoneID,
      Self.isUsableCachedRecordName(cachedRecord.recordID.recordName)
    {
      for key in freshRecord.allKeys() {
        cachedRecord[key] = freshRecord[key]
      }
      return cachedRecord
    }
    return freshRecord
  }

  /// Cached system fields produced by a build that pre-dated the
  /// `<recordType>|<UUID>` prefix (issue #416) carry a bare-UUID recordID.
  /// Reusing them would re-upload the record under the legacy recordName,
  /// which the rest of the pipeline now treats as non-UUID and drops on
  /// downlink — so a remote update would never round-trip back. Bare-UUID
  /// caches are ignored so the next upload reissues a fresh prefixed
  /// recordID. Instrument recordNames (e.g. `"AUD"`, `"ASX:BHP"`) are
  /// not UUID-shaped and pass through unchanged.
  nonisolated static func isUsableCachedRecordName(_ recordName: String) -> Bool {
    if recordName.contains("|") { return true }
    return UUID(uuidString: recordName) == nil
  }

}
