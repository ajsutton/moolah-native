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
    onInstrumentRemoteChange: @escaping @Sendable () -> Void = {}
  ) {
    self.profileId = profileId
    self.zoneID = zoneID
    self.modelContainer = modelContainer
    self.onInstrumentRemoteChange = onInstrumentRemoteChange
  }

  // MARK: - Building CKRecords

  /// Builds a CKRecord from a local SwiftData record for upload.
  /// If cached system fields exist for this record, applies fields directly onto the
  /// cached record to preserve the change tag and avoid `.serverRecordChanged` conflicts.
  ///
  /// If the cached system fields reference a *different* zone than this handler's
  /// own zone, they are discarded and the record is uploaded as a fresh create in
  /// the handler's zone. This is a defence-in-depth guard against legacy corruption
  /// from the pre-April-15 build, where per-profile `CKSyncEngine`s received
  /// `fetchedRecordZoneChanges` for every zone in the database and upserted records
  /// by UUID into the wrong container — so a local record in profile A's store could
  /// end up with cached system fields pointing at profile B's zone. Zone filtering
  /// at ingestion (commit `7318941`) and the unified `SyncCoordinator` (commit
  /// `a0c502b`) prevent new corruption, but rows already on disk keep their stale
  /// system fields; without this guard they produce an unbreakable
  /// `serverRecordChanged` loop on every send.
  func buildCKRecord<T: CloudKitRecordConvertible & SystemFieldsCacheable>(
    for record: T
  ) -> CKRecord {
    let freshRecord = record.toCKRecord(in: zoneID)
    if let cachedData = record.encodedSystemFields,
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

  // MARK: - Shared Fetch Helper

  /// Fetches records using the given descriptor, logging errors instead of silently discarding them.
  /// Shared across all `ProfileDataSyncHandler+*.swift` files, so it lives on the type
  /// rather than on instance state. `nonisolated` + `static` lets batch closures invoke
  /// it from any isolation domain.
  nonisolated static func fetchOrLog<T: PersistentModel>(
    _ descriptor: FetchDescriptor<T>, context: ModelContext
  ) -> [T] {
    do {
      return try context.fetch(descriptor)
    } catch {
      batchLogger.error(
        "SwiftData fetch failed for \(String(describing: T.self), privacy: .public): \(error, privacy: .public)"
      )
      return []
    }
  }
}
