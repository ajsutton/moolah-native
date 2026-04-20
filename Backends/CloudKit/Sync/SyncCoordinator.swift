@preconcurrency import CloudKit
import Foundation
import OSLog
import SwiftData
import os

/// Unified sync coordinator that owns a single `CKSyncEngine` for the entire app.
///
/// Routes events by zone ID to `ProfileDataSyncHandler` or `ProfileIndexSyncHandler`.
/// Everything runs on `@MainActor` — no concurrency races by construction.
///
/// Zone routing:
/// - `profile-index` → `ProfileIndexSyncHandler`
/// - `profile-<uuid>` → `ProfileDataSyncHandler` (via `ProfileContainerManager`)
@Observable
@MainActor
final class SyncCoordinator: Sendable {

  // MARK: - Zone Parsing

  enum ZoneType: Equatable {
    case profileIndex
    case profileData(UUID)
    case unknown
  }

  nonisolated static func parseZone(_ zoneID: CKRecordZone.ID) -> ZoneType {
    let name = zoneID.zoneName
    if name == "profile-index" {
      return .profileIndex
    }
    if name.hasPrefix("profile-") {
      let suffix = String(name.dropFirst("profile-".count))
      if let uuid = UUID(uuidString: suffix) {
        return .profileData(uuid)
      }
    }
    return .unknown
  }

  // MARK: - Batch Kind

  /// Zone-kind bucket for a single `RecordZoneChangeBatch`.
  ///
  /// `nextRecordZoneChangeBatch` emits one bucket per call so `atomicByZone` can
  /// be set per-kind: profile-index records are independent (no cascade on conflict),
  /// while profile-data records within a zone must commit together.
  /// See issue #61.
  enum BatchKind: Equatable {
    case profileIndex
    case profileData

    var atomicByZone: Bool {
      switch self {
      case .profileIndex: return false
      case .profileData: return true
      }
    }
  }

  /// Picks the next batch kind to emit from a list of pending changes.
  /// Profile-index wins when both kinds are pending so index conflicts drain first.
  /// Returns `nil` if no changes belong to a known zone kind.
  nonisolated static func selectBatchKind(
    from changes: some Sequence<CKSyncEngine.PendingRecordZoneChange>
  ) -> BatchKind? {
    var sawData = false
    for change in changes {
      let zoneID: CKRecordZone.ID
      switch change {
      case .saveRecord(let id): zoneID = id.zoneID
      case .deleteRecord(let id): zoneID = id.zoneID
      @unknown default: continue
      }
      switch parseZone(zoneID) {
      case .profileIndex: return .profileIndex
      case .profileData: sawData = true
      case .unknown: continue
      }
    }
    return sawData ? .profileData : nil
  }

  /// Filters pending changes to those matching the given batch kind, preserving order.
  nonisolated static func filterChanges(
    _ changes: [CKSyncEngine.PendingRecordZoneChange],
    matching kind: BatchKind
  ) -> [CKSyncEngine.PendingRecordZoneChange] {
    changes.filter { change in
      let zoneID: CKRecordZone.ID
      switch change {
      case .saveRecord(let id): zoneID = id.zoneID
      case .deleteRecord(let id): zoneID = id.zoneID
      @unknown default: return false
      }
      switch (parseZone(zoneID), kind) {
      case (.profileIndex, .profileIndex): return true
      case (.profileData, .profileData): return true
      default: return false
      }
    }
  }

  // MARK: - Observer Pattern

  struct ObserverToken: Equatable {
    let id: UUID
    let profileId: UUID
  }

  private struct ProfileObserver {
    let id: UUID
    let callback: @MainActor (Set<String>) -> Void
  }

  private struct IndexObserver {
    let id: UUID
    let callback: @MainActor () -> Void
  }

  private var profileObservers: [UUID: [ProfileObserver]] = [:]
  private var indexObservers: [IndexObserver] = []

  func addObserver(
    for profileId: UUID, callback: @escaping @MainActor (Set<String>) -> Void
  ) -> ObserverToken {
    let token = ObserverToken(id: UUID(), profileId: profileId)
    let observer = ProfileObserver(id: token.id, callback: callback)
    profileObservers[profileId, default: []].append(observer)
    return token
  }

  func removeObserver(token: ObserverToken) {
    profileObservers[token.profileId]?.removeAll { $0.id == token.id }
    if profileObservers[token.profileId]?.isEmpty == true {
      profileObservers.removeValue(forKey: token.profileId)
    }
  }

  func addIndexObserver(_ callback: @escaping @MainActor () -> Void) -> UUID {
    let id = UUID()
    indexObservers.append(IndexObserver(id: id, callback: callback))
    return id
  }

  func removeIndexObserver(_ id: UUID) {
    indexObservers.removeAll { $0.id == id }
  }

  /// Notify profile observers. Exposed for testing.
  func notifyObservers(for profileId: UUID, changedTypes: Set<String>) {
    guard let observers = profileObservers[profileId] else { return }
    for observer in observers {
      observer.callback(changedTypes)
    }
  }

  /// Notify index observers. Exposed for testing.
  func notifyIndexObservers() {
    for observer in indexObservers {
      observer.callback()
    }
  }

  // MARK: - State

  let stateFileURL: URL = URL.applicationSupportDirectory
    .appending(path: "Moolah-v2-sync.syncstate")

  let containerManager: ProfileContainerManager
  let profileIndexHandler: ProfileIndexSyncHandler

  /// User defaults used to persist per-profile "backfill scan complete" flags so the
  /// scan runs at most once per profile across app launches. Injected for testing.
  private let userDefaults: UserDefaults

  /// Key prefix for the per-profile backfill-scan-completed flag. The full key is
  /// `"\(backfillScanCompleteKeyPrefix).\(profileId.uuidString)"`.
  private static let backfillScanCompleteKeyPrefix = "com.moolah.sync.backfillScanComplete"

  private let logger = Logger(subsystem: "com.moolah.app", category: "SyncCoordinator")
  private var syncEngine: CKSyncEngine?
  private(set) var isRunning = false

  /// Tracks whether this coordinator started without saved state (first launch or migration).
  /// Used to guard against the synthetic `.signIn` event.
  private var isFirstLaunch = false

  /// True while CKSyncEngine is fetching changes (between willFetchChanges and didFetchChanges).
  private(set) var isFetchingChanges = false

  /// True when iCloud storage is full and sync uploads are failing.
  /// Cleared when a send cycle completes without quota errors.
  private(set) var isQuotaExceeded = false

  /// Record types accumulated per profile during a fetch session.
  private var fetchSessionChangedTypes: [UUID: Set<String>] = [:]

  /// Whether the profile-index zone had changes during the current fetch session.
  private var fetchSessionIndexChanged = false

  /// Cached profile data handlers, keyed by profile UUID.
  private var dataHandlers: [UUID: ProfileDataSyncHandler] = [:]

  /// Zones with pending zone creation — records in these zones are skipped in nextRecordZoneChangeBatch.
  private var pendingZoneCreation: [CKRecordZone.ID: [CKSyncEngine.PendingRecordZoneChange]] = [:]

  /// Active zone creation tasks, keyed by zone ID.
  private var zoneCreationTasks: [CKRecordZone.ID: Task<Void, Never>] = [:]

  /// The zone setup task (creates profile-index zone on start).
  private var zoneSetupTask: Task<Void, Never>?

  /// Task for coalescing re-fetch requests after save failures.
  private var refetchTask: Task<Void, Never>?

  /// Last-resort periodic retry scheduled after the short-retry budget is exhausted.
  /// Fires every `longRetryInterval`, resets the short-retry counter, and re-triggers
  /// a fetch so persistent failures don't leave local data silently incomplete.
  private var longRetryTask: Task<Void, Never>?

  /// Number of consecutive re-fetch attempts scheduled after a save failure.
  /// Reset to zero whenever a fetched-record-zone-changes batch applies successfully.
  /// Exposed for testing.
  private(set) var refetchAttempts = 0

  /// `true` while a last-resort periodic retry is pending. Exposed for testing.
  var hasPendingLongRetry: Bool { longRetryTask != nil }

  /// Maximum number of consecutive re-fetch attempts before giving up on the short-retry
  /// chain and falling back to the long-retry timer. A persistent `context.save()` failure
  /// (e.g. SwiftData schema corruption, disk full) would otherwise produce an infinite
  /// 5-second retry loop. See issue #77.
  nonisolated static let maxRefetchAttempts = 5

  /// Interval between last-resort periodic retries after the short-retry budget is
  /// exhausted. Long enough to avoid battery / quota impact on a persistently failing
  /// device, but short enough that a device that comes back online (disk freed, schema
  /// migrated by a later app update, transient corruption cleared) recovers without
  /// requiring an app restart. See issue #77.
  nonisolated static let longRetryInterval: Duration = .seconds(30 * 60)

  /// Returns the exponential backoff delay for the given 1-based attempt number,
  /// starting at 5 seconds and doubling each attempt. Returns `nil` when `attempt`
  /// exceeds `maxRefetchAttempts` — the caller should stop retrying at that point.
  nonisolated static func refetchBackoff(forAttempt attempt: Int) -> Duration? {
    guard attempt >= 1, attempt <= maxRefetchAttempts else { return nil }
    // 5s, 10s, 20s, 40s, 80s
    let seconds = 5 * (1 << (attempt - 1))
    return .seconds(seconds)
  }

  // MARK: - Init

  init(
    containerManager: ProfileContainerManager,
    userDefaults: UserDefaults = .standard
  ) {
    self.containerManager = containerManager
    self.userDefaults = userDefaults
    self.profileIndexHandler = ProfileIndexSyncHandler(
      modelContainer: containerManager.indexContainer)
  }

  // MARK: - Handler Access

  /// Returns (or creates) a `ProfileDataSyncHandler` for the given profile zone.
  func handlerForProfileZone(
    profileId: UUID, zoneID: CKRecordZone.ID
  ) throws -> ProfileDataSyncHandler {
    if let existing = dataHandlers[profileId] {
      return existing
    }
    let container = try containerManager.container(for: profileId)
    let handler = ProfileDataSyncHandler(
      profileId: profileId, zoneID: zoneID, modelContainer: container)
    dataHandlers[profileId] = handler
    return handler
  }

  // MARK: - Lifecycle

  func start() {
    guard !isRunning else { return }

    let signpostID = OSSignpostID(log: Signposts.sync)
    os_signpost(.begin, log: Signposts.sync, name: "coordinatorStart", signpostID: signpostID)
    defer {
      os_signpost(.end, log: Signposts.sync, name: "coordinatorStart", signpostID: signpostID)
    }

    // Migration: delete old per-engine state files
    containerManager.deleteOldSyncStateFiles()

    let savedState = loadStateSerialization()
    isFirstLaunch = savedState == nil
    let configuration = CKSyncEngine.Configuration(
      database: CKContainer.default().privateCloudDatabase,
      stateSerialization: savedState,
      delegate: self
    )
    syncEngine = CKSyncEngine(configuration)
    isRunning = true
    logger.info("Started unified sync coordinator")

    // On first launch (migration or truly first launch), queue all existing records
    if isFirstLaunch {
      queueAllExistingRecordsForAllZones()
    }

    // Eagerly create the profile-index zone and all known profile-data zones,
    // then send if needed. Reactive creation in `handleSentRecordZoneChanges`
    // remains as a fallback per SYNC_GUIDE Rule 3.
    let profileIds = containerManager.allProfileIds()
    let shouldBackfillUnsynced = !isFirstLaunch
    zoneSetupTask = Task {
      await self.ensureZoneExists(self.profileIndexHandler.zoneID)
      for profileId in profileIds {
        let zoneID = CKRecordZone.ID(
          zoneName: "profile-\(profileId.uuidString)",
          ownerName: CKCurrentUserDefaultName)
        await self.ensureZoneExists(zoneID)
      }
      // After zones are confirmed, backfill any records that never got queued for upload
      // (e.g. data imported by migration on a build that predated the migration→sync fix,
      // or a previous run that crashed between the SwiftData write and the sync-engine
      // queue). Skipped on first launch because `queueAllExistingRecordsForAllZones`
      // has already queued everything.
      if shouldBackfillUnsynced {
        _ = self.queueUnsyncedRecordsForAllProfiles()
      }
      if self.hasPendingChanges {
        self.logger.info("Zones ready — sending pending changes")
        await self.sendChanges()
      }
    }
  }

  func stop() {
    zoneSetupTask?.cancel()
    zoneSetupTask = nil
    refetchTask?.cancel()
    refetchTask = nil
    longRetryTask?.cancel()
    longRetryTask = nil
    refetchAttempts = 0
    for (_, task) in zoneCreationTasks {
      task.cancel()
    }
    zoneCreationTasks.removeAll()
    syncEngine = nil
    isRunning = false
    isFetchingChanges = false
    isQuotaExceeded = false
    logger.info("Stopped unified sync coordinator")
  }

  // MARK: - Pending Changes

  var hasPendingChanges: Bool {
    syncEngine.map { !$0.state.pendingRecordZoneChanges.isEmpty } ?? false
  }

  func queueSave(id: UUID, zoneID: CKRecordZone.ID) {
    let recordID = CKRecord.ID(recordName: id.uuidString, zoneID: zoneID)
    syncEngine?.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
  }

  func queueSave(recordName: String, zoneID: CKRecordZone.ID) {
    let recordID = CKRecord.ID(recordName: recordName, zoneID: zoneID)
    syncEngine?.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
  }

  func queueDeletion(id: UUID, zoneID: CKRecordZone.ID) {
    let recordID = CKRecord.ID(recordName: id.uuidString, zoneID: zoneID)
    syncEngine?.state.add(pendingRecordZoneChanges: [.deleteRecord(recordID)])
  }

  func sendChanges() async {
    guard let syncEngine, isRunning else { return }
    do {
      try await syncEngine.sendChanges()
    } catch {
      logger.error("Failed to send changes: \(error)")
    }
  }

  func fetchChanges() async {
    guard let syncEngine, isRunning else { return }
    do {
      try await syncEngine.fetchChanges()
    } catch {
      logger.error("Failed to fetch changes: \(error)")
    }
  }

  /// Schedules a re-fetch after an exponentially-backed-off delay. Multiple calls coalesce
  /// into one re-fetch. Gives up after `maxRefetchAttempts` consecutive failures to avoid
  /// looping forever on a persistent save failure (e.g. SwiftData corruption). See issue #77.
  ///
  /// The attempt counter is reset by `resetRefetchAttempts()` whenever a fetch batch applies
  /// successfully.
  private func scheduleRefetch() {
    let nextAttempt = refetchAttempts + 1
    guard let delay = Self.refetchBackoff(forAttempt: nextAttempt) else {
      logger.error(
        """
        Giving up on short re-fetch chain after \(self.refetchAttempts) consecutive save \
        failures. Local SwiftData writes appear to be persistently failing. Scheduling a \
        last-resort retry in \(Self.longRetryInterval) so a recovered device (disk freed, \
        schema migrated, transient corruption cleared) resyncs without requiring an app \
        restart.
        """)
      refetchTask?.cancel()
      refetchTask = nil
      scheduleLongRetry()
      return
    }
    refetchAttempts = nextAttempt
    refetchTask?.cancel()
    refetchTask = Task { [delay, nextAttempt] in
      try? await Task.sleep(for: delay)
      guard !Task.isCancelled else { return }
      self.logger.info(
        "Re-fetching changes after save failure (attempt \(nextAttempt)/\(Self.maxRefetchAttempts))"
      )
      await self.fetchChanges()
    }
  }

  /// Schedules a last-resort periodic retry after the short-retry budget is exhausted.
  /// On fire, resets the short-retry counter and re-triggers a fetch. If that fetch also
  /// fails to save, the short-retry chain runs again and, on exhaustion, reschedules
  /// another long retry — producing a slow periodic probe that eventually recovers once
  /// the underlying fault clears. Coalesces with any existing long-retry task.
  private func scheduleLongRetry() {
    longRetryTask?.cancel()
    longRetryTask = Task { [interval = Self.longRetryInterval] in
      try? await Task.sleep(for: interval)
      guard !Task.isCancelled else { return }
      self.logger.info(
        "Last-resort re-fetch firing after \(interval) — short-retry chain previously exhausted"
      )
      // Reset the short-retry counter so the next save failure gets a fresh backoff
      // budget instead of immediately re-exhausting.
      self.refetchAttempts = 0
      self.longRetryTask = nil
      await self.fetchChanges()
    }
  }

  /// Resets the re-fetch attempt counter and cancels any pending long-retry task.
  /// Called on every successful apply of fetched changes — a single successful apply
  /// proves local writes are working, so the slow recovery timer is no longer needed.
  func resetRefetchAttempts() {
    refetchAttempts = 0
    longRetryTask?.cancel()
    longRetryTask = nil
  }

  // MARK: - Fetch Session

  func beginFetchingChanges() {
    if isFetchingChanges {
      // Prior session ended abnormally — flush accumulated changes
      logger.warning("Prior fetch session ended abnormally — flushing accumulated changes")
      flushFetchSessionChanges()
    }
    isFetchingChanges = true
    fetchSessionChangedTypes.removeAll()
    fetchSessionIndexChanged = false
  }

  func endFetchingChanges() {
    isFetchingChanges = false
    let profileCount = fetchSessionChangedTypes.filter { !$0.value.isEmpty }.count
    let totalTypes = fetchSessionChangedTypes.values.reduce(into: Set<String>()) {
      $0.formUnion($1)
    }
    logger.info(
      "Fetch session complete: \(profileCount) profiles changed, types: \(totalTypes), indexChanged: \(self.fetchSessionIndexChanged)"
    )
    flushFetchSessionChanges()
  }

  /// Accumulate changed types for a profile during a fetch session. Exposed for testing.
  func accumulateFetchSessionChanges(for profileId: UUID, changedTypes: Set<String>) {
    fetchSessionChangedTypes[profileId, default: []].formUnion(changedTypes)
  }

  private func flushFetchSessionChanges() {
    for (profileId, types) in fetchSessionChangedTypes where !types.isEmpty {
      notifyObservers(for: profileId, changedTypes: types)
    }
    if fetchSessionIndexChanged {
      notifyIndexObservers()
    }
    fetchSessionChangedTypes.removeAll()
    fetchSessionIndexChanged = false
  }

  // MARK: - Zone Creation

  private func ensureZoneExists(_ zoneID: CKRecordZone.ID) async {
    do {
      let zone = CKRecordZone(zoneID: zoneID)
      _ = try await CKContainer.default().privateCloudDatabase.save(zone)
      logger.info("Ensured zone exists: \(zoneID.zoneName)")
    } catch {
      logger.error("Failed to ensure zone exists \(zoneID.zoneName): \(error)")
    }
  }

  /// Creates a zone and re-queues pending records after creation succeeds.
  /// Records are stored in `pendingZoneCreation` so `nextRecordZoneChangeBatch` skips them.
  private func ensureProfileZone(
    _ zoneID: CKRecordZone.ID,
    pendingChanges: [CKSyncEngine.PendingRecordZoneChange]
  ) {
    // Merge with any existing pending changes for this zone
    pendingZoneCreation[zoneID, default: []].append(contentsOf: pendingChanges)

    // Don't start a duplicate task
    guard zoneCreationTasks[zoneID] == nil else { return }

    zoneCreationTasks[zoneID] = Task {
      await self.ensureZoneExists(zoneID)
      // Re-queue the stored records
      if let changes = self.pendingZoneCreation.removeValue(forKey: zoneID) {
        self.syncEngine?.state.add(pendingRecordZoneChanges: changes)
        self.logger.info(
          "Re-queued \(changes.count) changes after zone creation for \(zoneID.zoneName)")
      }
      self.zoneCreationTasks.removeValue(forKey: zoneID)
    }
  }

  // MARK: - Queue All Existing Records

  /// Ensures the given profile's zone exists on CloudKit, then queues every record in
  /// that profile's local SwiftData store for upload. Called by `MigrationCoordinator`
  /// after a migration import, which writes records directly to SwiftData and so
  /// bypasses the repository `onRecordChanged` hooks that normally feed the sync engine.
  ///
  /// The zone is created first so the initial send does not have to round-trip through
  /// `.zoneNotFound` and `pendingZoneCreation`.
  ///
  /// Returns the record IDs that were queued (empty if the profile has no records or
  /// its handler couldn't be resolved). The caller is responsible for invoking
  /// `sendChanges()` afterwards if an immediate upload is desired.
  @discardableResult
  func queueAllRecordsAfterImport(for profileId: UUID) async -> [CKRecord.ID] {
    let zoneID = CKRecordZone.ID(
      zoneName: "profile-\(profileId.uuidString)",
      ownerName: CKCurrentUserDefaultName)

    // Only hit CloudKit when the coordinator is actually running; tests never start
    // the engine and should not make network calls for zone creation.
    if isRunning {
      await ensureZoneExists(zoneID)
    }

    guard let handler = try? handlerForProfileZone(profileId: profileId, zoneID: zoneID) else {
      logger.error("Failed to get handler for post-import queueing, profile \(profileId)")
      return []
    }
    let recordIDs = handler.queueAllExistingRecords()
    if !recordIDs.isEmpty {
      syncEngine?.state.add(
        pendingRecordZoneChanges: recordIDs.map { .saveRecord($0) })
      logger.info(
        "Queued \(recordIDs.count) records for upload after import, profile \(profileId)")
    }
    // Mark the profile as backfill-scanned: we've just queued every record, which is
    // a strict superset of what the startup backfill scan would do. Prevents the next
    // launch from re-scanning this profile's SwiftData store for nothing.
    markBackfillScanComplete(for: profileId)
    return recordIDs
  }

  /// Scans every known cloud profile for records that have never been successfully
  /// synced (i.e. `encodedSystemFields == nil`) and queues them for upload. Called on
  /// coordinator start so users whose profiles were migrated on a previous build — where
  /// migration did not queue imported records — still end up with their data uploaded
  /// on the next launch.
  ///
  /// Idempotent: records that already have system fields are skipped, and CKSyncEngine's
  /// pending list dedupes against any other queued changes.
  @discardableResult
  func queueUnsyncedRecordsForAllProfiles() -> [CKRecord.ID] {
    var queued: [CKRecord.ID] = []
    var scannedProfiles = 0
    var skippedProfiles = 0
    let allProfiles = containerManager.allProfileIds()
    for profileId in allProfiles {
      // Skip profiles whose backfill scan has already run — the only work left for
      // those is normal sync traffic. This keeps the startup scan O(1) on the happy
      // path: after the first run per profile we never touch its SwiftData store again.
      if hasCompletedBackfillScan(for: profileId) {
        skippedProfiles += 1
        continue
      }
      let zoneID = CKRecordZone.ID(
        zoneName: "profile-\(profileId.uuidString)",
        ownerName: CKCurrentUserDefaultName)
      guard let handler = try? handlerForProfileZone(profileId: profileId, zoneID: zoneID)
      else {
        logger.error("Failed to get handler for backfill queueing, profile \(profileId)")
        continue
      }
      let recordIDs = handler.queueUnsyncedRecords()
      scannedProfiles += 1
      if !recordIDs.isEmpty {
        syncEngine?.state.add(
          pendingRecordZoneChanges: recordIDs.map { .saveRecord($0) })
        queued.append(contentsOf: recordIDs)
      }
      markBackfillScanComplete(for: profileId)
    }
    logger.info(
      """
      Backfill scan complete: \(allProfiles.count) profiles total, \
      \(scannedProfiles) scanned, \(skippedProfiles) skipped (already flagged), \
      \(queued.count) unsynced records queued for upload
      """)
    return queued
  }

  private func hasCompletedBackfillScan(for profileId: UUID) -> Bool {
    userDefaults.bool(forKey: backfillScanCompleteKey(for: profileId))
  }

  private func markBackfillScanComplete(for profileId: UUID) {
    userDefaults.set(true, forKey: backfillScanCompleteKey(for: profileId))
  }

  /// Clears the backfill-scan flag for one profile — called whenever the profile's
  /// local data is destroyed or its system fields are reset (zone deletion,
  /// encrypted data reset), so the next scan re-examines it instead of skipping
  /// based on stale state.
  private func clearBackfillScanFlag(for profileId: UUID) {
    userDefaults.removeObject(forKey: backfillScanCompleteKey(for: profileId))
  }

  /// Clears every backfill-scan flag. Called on sign-out/switch-accounts, where
  /// the set of valid profiles may change entirely before the next scan runs.
  private func clearAllBackfillScanFlags() {
    let prefix = Self.backfillScanCompleteKeyPrefix + "."
    for key in userDefaults.dictionaryRepresentation().keys where key.hasPrefix(prefix) {
      userDefaults.removeObject(forKey: key)
    }
  }

  private func backfillScanCompleteKey(for profileId: UUID) -> String {
    "\(Self.backfillScanCompleteKeyPrefix).\(profileId.uuidString)"
  }

  // MARK: - Test Hooks

  /// Test-only: runs the same bookkeeping as a CloudKit `.signOut` account event, so
  /// unit tests can verify backfill-flag cleanup without a real CKSyncEngine.
  func handleSignOutForTesting() {
    deleteAllLocalData()
    deleteStateSerialization()
    clearAllBackfillScanFlags()
    isFetchingChanges = false
  }

  /// Test-only: runs the same bookkeeping as a `.deleted` zone deletion for the given
  /// zone, so unit tests can verify backfill-flag cleanup without dispatching a real
  /// sync event.
  func handleZoneDeletedForTesting(zoneID: CKRecordZone.ID) {
    handleZoneDeleted(zoneID, zoneType: Self.parseZone(zoneID))
  }

  /// Test-only: runs the same bookkeeping as an `.encryptedDataReset` zone deletion,
  /// so unit tests can verify backfill-flag cleanup without dispatching a real sync
  /// event.
  func handleEncryptedDataResetForTesting(zoneID: CKRecordZone.ID) {
    handleEncryptedDataReset(zoneID, zoneType: Self.parseZone(zoneID))
  }

  private func queueAllExistingRecordsForAllZones() {
    // Queue profile-index records
    let indexRecordIDs = profileIndexHandler.queueAllExistingRecords()
    if !indexRecordIDs.isEmpty {
      syncEngine?.state.add(
        pendingRecordZoneChanges: indexRecordIDs.map { .saveRecord($0) })
    }

    // Queue per-profile records
    for profileId in containerManager.allProfileIds() {
      let zoneID = CKRecordZone.ID(
        zoneName: "profile-\(profileId.uuidString)",
        ownerName: CKCurrentUserDefaultName)
      do {
        let handler = try handlerForProfileZone(profileId: profileId, zoneID: zoneID)
        let recordIDs = handler.queueAllExistingRecords()
        if !recordIDs.isEmpty {
          syncEngine?.state.add(
            pendingRecordZoneChanges: recordIDs.map { .saveRecord($0) })
        }
      } catch {
        logger.error("Failed to queue records for profile \(profileId): \(error)")
      }
      // This path queued every record for the profile, so there is nothing left for
      // the per-launch backfill scan to find.
      markBackfillScanComplete(for: profileId)
    }
  }

  // MARK: - State Persistence

  private func loadStateSerialization() -> CKSyncEngine.State.Serialization? {
    guard let data = try? Data(contentsOf: stateFileURL) else { return nil }
    return try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: data)
  }

  private func saveStateSerialization(_ serialization: CKSyncEngine.State.Serialization) {
    do {
      let data = try JSONEncoder().encode(serialization)
      try data.write(to: stateFileURL, options: .atomic)
    } catch {
      logger.error("Failed to save sync state: \(error)")
    }
  }

  private func deleteStateSerialization() {
    try? FileManager.default.removeItem(at: stateFileURL)
  }

  // MARK: - Account Changes

  private func handleAccountChange(_ change: CKSyncEngine.Event.AccountChange) {
    switch change.changeType {
    case .signIn:
      if isFirstLaunch {
        logger.info("Synthetic sign-in on first launch — skipping re-upload")
        isFirstLaunch = false
      } else {
        logger.info("Account signed in — re-uploading all local data")
        queueAllExistingRecordsForAllZones()
      }

    case .signOut:
      logger.info("Account signed out — deleting all local data and sync state")
      deleteAllLocalData()
      deleteStateSerialization()
      clearAllBackfillScanFlags()
      isFetchingChanges = false

    case .switchAccounts:
      logger.info("Account switched — full reset")
      deleteAllLocalData()
      deleteStateSerialization()
      clearAllBackfillScanFlags()
      isFetchingChanges = false

    @unknown default:
      break
    }
  }

  private func deleteAllLocalData() {
    // Delete profile-index data
    profileIndexHandler.deleteLocalData()
    notifyIndexObservers()

    // Delete all profile data
    for profileId in containerManager.allProfileIds() {
      let zoneID = CKRecordZone.ID(
        zoneName: "profile-\(profileId.uuidString)",
        ownerName: CKCurrentUserDefaultName)
      if let handler = try? handlerForProfileZone(profileId: profileId, zoneID: zoneID) {
        let changedTypes = handler.deleteLocalData()
        if !changedTypes.isEmpty {
          notifyObservers(for: profileId, changedTypes: changedTypes)
        }
      }
    }
    dataHandlers.removeAll()
  }

  // MARK: - Fetched Database Changes (Zone Deletions)

  private func handleFetchedDatabaseChanges(
    _ changes: CKSyncEngine.Event.FetchedDatabaseChanges
  ) {
    for deletion in changes.deletions {
      let zoneType = Self.parseZone(deletion.zoneID)

      switch deletion.reason {
      case .deleted:
        handleZoneDeleted(deletion.zoneID, zoneType: zoneType)

      case .purged:
        handleZonePurged(deletion.zoneID, zoneType: zoneType)

      case .encryptedDataReset:
        handleEncryptedDataReset(deletion.zoneID, zoneType: zoneType)

      @unknown default:
        logger.warning("Unknown zone deletion reason for \(deletion.zoneID.zoneName)")
      }
    }
  }

  private func handleZoneDeleted(_ zoneID: CKRecordZone.ID, zoneType: ZoneType) {
    switch zoneType {
    case .profileIndex:
      logger.warning("Profile-index zone was deleted remotely — removing local data")
      profileIndexHandler.deleteLocalData()
      notifyIndexObservers()

    case .profileData(let profileId):
      logger.warning("Profile zone deleted: \(profileId) — removing local data")
      if let handler = try? handlerForProfileZone(profileId: profileId, zoneID: zoneID) {
        let changedTypes = handler.deleteLocalData()
        if !changedTypes.isEmpty {
          notifyObservers(for: profileId, changedTypes: changedTypes)
        }
      }
      // Records have been wiped; any re-created zone starts with no system fields and
      // must be re-scanned. Clear the flag so the next backfill pass picks it up.
      clearBackfillScanFlag(for: profileId)

    case .unknown:
      break
    }
  }

  private func handleZonePurged(_ zoneID: CKRecordZone.ID, zoneType: ZoneType) {
    // Purge: delete data AND state file (forces full re-fetch of all zones)
    switch zoneType {
    case .profileIndex:
      logger.warning("Profile-index zone purged — deleting data and state")
      profileIndexHandler.deleteLocalData()
      notifyIndexObservers()

    case .profileData(let profileId):
      logger.warning("Profile zone purged: \(profileId) — deleting data")
      if let handler = try? handlerForProfileZone(profileId: profileId, zoneID: zoneID) {
        let changedTypes = handler.deleteLocalData()
        if !changedTypes.isEmpty {
          notifyObservers(for: profileId, changedTypes: changedTypes)
        }
      }
      clearBackfillScanFlag(for: profileId)

    case .unknown:
      break
    }
    // Delete shared state file — all zones re-fetch
    deleteStateSerialization()
  }

  private func handleEncryptedDataReset(_ zoneID: CKRecordZone.ID, zoneType: ZoneType) {
    // Delete state file, clear system fields, re-queue records
    deleteStateSerialization()

    switch zoneType {
    case .profileIndex:
      logger.warning("Encrypted data reset for profile-index — re-uploading")
      profileIndexHandler.clearAllSystemFields()
      let recordIDs = profileIndexHandler.queueAllExistingRecords()
      if !recordIDs.isEmpty {
        syncEngine?.state.add(
          pendingRecordZoneChanges: recordIDs.map { .saveRecord($0) })
      }

    case .profileData(let profileId):
      logger.warning("Encrypted data reset for profile \(profileId) — re-uploading")
      if let handler = try? handlerForProfileZone(profileId: profileId, zoneID: zoneID) {
        handler.clearAllSystemFields()
        let recordIDs = handler.queueAllExistingRecords()
        if !recordIDs.isEmpty {
          syncEngine?.state.add(
            pendingRecordZoneChanges: recordIDs.map { .saveRecord($0) })
        }
      }
      // System fields were cleared; if a later crash happens before the re-upload
      // persists, the next backfill scan must revisit this profile instead of
      // trusting a stale "complete" flag from before the reset.
      clearBackfillScanFlag(for: profileId)

    case .unknown:
      break
    }
  }

  // MARK: - Fetched Record Zone Changes

  /// Processes fetched record zone changes with heavy SwiftData work off the main actor.
  /// Resolves handlers and manages state on @MainActor; upsert/delete/save runs off-main.
  nonisolated private func handleFetchedRecordZoneChangesAsync(
    _ changes: CKSyncEngine.Event.FetchedRecordZoneChanges
  ) async {
    // Group records by zone off-main
    var savedByZone: [CKRecordZone.ID: [CKRecord]] = [:]
    for modification in changes.modifications {
      let record = modification.record
      savedByZone[record.recordID.zoneID, default: []].append(record)
    }
    var deletedByZone: [CKRecordZone.ID: [(CKRecord.ID, String)]] = [:]
    for deletion in changes.deletions {
      deletedByZone[deletion.recordID.zoneID, default: []]
        .append((deletion.recordID, deletion.recordType))
    }

    // Pre-extract system fields off-main
    let preExtractedSystemFields: [(String, Data)] = changes.modifications
      .map { ($0.record.recordID.recordName, $0.record.encodedSystemFields) }

    let allZones = Set(savedByZone.keys).union(deletedByZone.keys)
    for zoneID in allZones {
      let saved = savedByZone[zoneID] ?? []
      let deleted = deletedByZone[zoneID] ?? []
      let zoneType = Self.parseZone(zoneID)

      let signpostID = OSSignpostID(log: Signposts.sync)
      os_signpost(
        .begin, log: Signposts.sync, name: "applyFetchedChanges", signpostID: signpostID,
        "%{public}@ %{public}d saves %{public}d deletes", zoneID.zoneName, saved.count,
        deleted.count)
      let zoneStart = ContinuousClock.now

      switch zoneType {
      case .profileIndex:
        let deletedIDs = deleted.map(\.0)
        // Index upsert is fast (few records), run off-main
        let indexResult = profileIndexHandler.applyRemoteChanges(saved: saved, deleted: deletedIDs)
        switch indexResult {
        case .success:
          await MainActor.run {
            // Successful apply proves local writes are working — reset the re-fetch
            // attempt counter so a future transient failure gets a full retry budget.
            resetRefetchAttempts()
            if isFetchingChanges {
              fetchSessionIndexChanged = true
            } else {
              notifyIndexObservers()
            }
          }
        case .saveFailed(let errorDescription):
          logger.error("Profile index save failed, scheduling re-fetch: \(errorDescription)")
          await scheduleRefetch()
        }

      case .profileData(let profileId):
        // Resolve handler on main (accesses @MainActor-isolated state)
        let handler: ProfileDataSyncHandler? = await MainActor.run {
          do {
            return try handlerForProfileZone(profileId: profileId, zoneID: zoneID)
          } catch {
            logger.error("Failed to get handler for profile \(profileId): \(error)")
            return nil
          }
        }
        guard let handler else { continue }

        // Filter pre-extracted system fields to this zone (off-main)
        let savedNames = Set(saved.map { $0.recordID.recordName })
        let zonePreExtracted = preExtractedSystemFields.filter { (recordName, _) in
          savedNames.contains(recordName)
        }

        // Heavy upsert/delete/save runs off-main via nonisolated method
        let result = handler.applyRemoteChanges(
          saved: saved, deleted: deleted, preExtractedSystemFields: zonePreExtracted)

        // Notify observers on main — read isFetchingChanges live to avoid
        // stale snapshot if stop() was called during applyRemoteChanges
        switch result {
        case .success(let changedTypes):
          await MainActor.run {
            // Successful apply proves local writes are working — reset the re-fetch
            // attempt counter so a future transient failure gets a full retry budget.
            resetRefetchAttempts()
            if !changedTypes.isEmpty {
              if isFetchingChanges {
                accumulateFetchSessionChanges(for: profileId, changedTypes: changedTypes)
              } else {
                notifyObservers(for: profileId, changedTypes: changedTypes)
              }
            }
          }
        case .saveFailed(let errorDescription):
          logger.error(
            "Profile data save failed for \(profileId), scheduling re-fetch: \(errorDescription)")
          await scheduleRefetch()
        }

      case .unknown:
        logger.warning("Received changes for unknown zone: \(zoneID.zoneName)")
      }

      os_signpost(.end, log: Signposts.sync, name: "applyFetchedChanges", signpostID: signpostID)
      let zoneMs = (ContinuousClock.now - zoneStart).inMilliseconds
      if zoneMs > 100 {
        logger.info(
          "applyFetchedChanges took \(zoneMs)ms (\(zoneID.zoneName), \(saved.count) saves, \(deleted.count) deletes)"
        )
      }
    }
  }

  // MARK: - Sent Record Zone Changes

  private func handleSentRecordZoneChanges(
    _ sentChanges: CKSyncEngine.Event.SentRecordZoneChanges
  ) {
    let signpostID = OSSignpostID(log: Signposts.sync)
    os_signpost(
      .begin, log: Signposts.sync, name: "handleSentChanges", signpostID: signpostID,
      "%{public}d saved %{public}d failedSaves %{public}d failedDeletes",
      sentChanges.savedRecords.count, sentChanges.failedRecordSaves.count,
      sentChanges.failedRecordDeletes.count)
    defer {
      os_signpost(.end, log: Signposts.sync, name: "handleSentChanges", signpostID: signpostID)
    }

    // Group saved records by zone
    var savedByZone: [CKRecordZone.ID: [CKRecord]] = [:]
    for record in sentChanges.savedRecords {
      savedByZone[record.recordID.zoneID, default: []].append(record)
    }

    // Group failed saves by zone
    var failedSavesByZone:
      [CKRecordZone.ID: [CKSyncEngine.Event.SentRecordZoneChanges
        .FailedRecordSave]] = [:]
    for failure in sentChanges.failedRecordSaves {
      failedSavesByZone[failure.record.recordID.zoneID, default: []].append(failure)
    }

    // Group failed deletes by zone
    var failedDeletesByZone: [CKRecordZone.ID: [(CKRecord.ID, CKError)]] = [:]
    for (recordID, error) in sentChanges.failedRecordDeletes {
      failedDeletesByZone[recordID.zoneID, default: []].append((recordID, error))
    }

    // Process each zone's results through the appropriate handler
    let allZones = Set(savedByZone.keys)
      .union(failedSavesByZone.keys)
      .union(failedDeletesByZone.keys)

    for zoneID in allZones {
      let zoneType = Self.parseZone(zoneID)
      let failures: SyncErrorRecovery.ClassifiedFailures

      switch zoneType {
      case .profileIndex:
        failures = profileIndexHandler.handleSentRecordZoneChanges(
          savedRecords: savedByZone[zoneID] ?? [],
          failedSaves: failedSavesByZone[zoneID] ?? [],
          failedDeletes: failedDeletesByZone[zoneID] ?? [])

      case .profileData(let profileId):
        guard let handler = try? handlerForProfileZone(profileId: profileId, zoneID: zoneID)
        else {
          logger.error("Failed to get handler for sent changes, profile \(profileId)")
          continue
        }
        failures = handler.handleSentRecordZoneChanges(
          savedRecords: savedByZone[zoneID] ?? [],
          failedSaves: failedSavesByZone[zoneID] ?? [],
          failedDeletes: failedDeletesByZone[zoneID] ?? [])

      case .unknown:
        logger.warning("Sent changes for unknown zone: \(zoneID.zoneName)")
        continue
      }

      // Re-queue failures (except zone-not-found which needs zone creation)
      let (zoneNotFoundSaves, zoneNotFoundDeletes) = SyncErrorRecovery.requeueFailures(
        failures, syncEngine: syncEngine, logger: logger)

      // Handle zone-not-found: store records and create zone
      if !zoneNotFoundSaves.isEmpty || !zoneNotFoundDeletes.isEmpty {
        var pendingChanges: [CKSyncEngine.PendingRecordZoneChange] = []
        pendingChanges += zoneNotFoundSaves.map { .saveRecord($0) }
        pendingChanges += zoneNotFoundDeletes.map { .deleteRecord($0) }
        ensureProfileZone(zoneID, pendingChanges: pendingChanges)
      }
    }

    // Track quota exceeded state across all zones in this send cycle
    let hasQuotaErrors = sentChanges.failedRecordSaves.contains { $0.error.code == .quotaExceeded }
    if hasQuotaErrors {
      isQuotaExceeded = true
    } else if !sentChanges.failedRecordSaves.isEmpty || !sentChanges.savedRecords.isEmpty {
      // Only clear if we actually processed records (not an empty event)
      isQuotaExceeded = false
    }
  }
}

// MARK: - CKSyncEngineDelegate

extension SyncCoordinator: CKSyncEngineDelegate {
  nonisolated func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
    if case .fetchedRecordZoneChanges(let changes) = event {
      await handleFetchedRecordZoneChangesAsync(changes)
    } else {
      await MainActor.run {
        handleEventOnMain(event)
      }
    }
  }

  private func handleEventOnMain(_ event: CKSyncEngine.Event) {
    switch event {
    case .stateUpdate(let stateUpdate):
      saveStateSerialization(stateUpdate.stateSerialization)

    case .accountChange(let accountChange):
      handleAccountChange(accountChange)

    case .fetchedDatabaseChanges(let changes):
      handleFetchedDatabaseChanges(changes)

    case .fetchedRecordZoneChanges:
      // Handled by handleFetchedRecordZoneChangesAsync
      break

    case .sentRecordZoneChanges(let sentChanges):
      handleSentRecordZoneChanges(sentChanges)

    case .willFetchChanges:
      beginFetchingChanges()

    case .didFetchChanges:
      endFetchingChanges()

    case .sentDatabaseChanges,
      .willFetchRecordZoneChanges, .didFetchRecordZoneChanges,
      .willSendChanges, .didSendChanges:
      break

    @unknown default:
      logger.debug("Unknown sync engine event")
    }
  }

  nonisolated func nextRecordZoneChangeBatch(
    _ context: CKSyncEngine.SendChangesContext,
    syncEngine: CKSyncEngine
  ) async -> CKSyncEngine.RecordZoneChangeBatch? {
    await MainActor.run {
      nextRecordZoneChangeBatchOnMain(context, syncEngine: syncEngine)
    }
  }

  private func nextRecordZoneChangeBatchOnMain(
    _ context: CKSyncEngine.SendChangesContext,
    syncEngine: CKSyncEngine
  ) -> CKSyncEngine.RecordZoneChangeBatch? {
    let signpostID = OSSignpostID(log: Signposts.sync)
    os_signpost(
      .begin, log: Signposts.sync, name: "nextBatch", signpostID: signpostID)
    defer {
      os_signpost(.end, log: Signposts.sync, name: "nextBatch", signpostID: signpostID)
    }

    let scope = context.options.scope
    var seenSaves = Set<CKRecord.ID>()
    var seenDeletes = Set<CKRecord.ID>()
    let pendingChanges = syncEngine.state.pendingRecordZoneChanges
      .filter { scope.contains($0) }
      .filter { change in
        switch change {
        case .saveRecord(let id): return seenSaves.insert(id).inserted
        case .deleteRecord(let id): return seenDeletes.insert(id).inserted
        @unknown default: return true
        }
      }
      .filter { change in
        // Skip records whose zone is in pendingZoneCreation
        let zoneID: CKRecordZone.ID
        switch change {
        case .saveRecord(let id): zoneID = id.zoneID
        case .deleteRecord(let id): zoneID = id.zoneID
        @unknown default: return true
        }
        return pendingZoneCreation[zoneID] == nil
      }

    guard !pendingChanges.isEmpty else { return nil }

    // Partition by zone-kind so atomicByZone can be set correctly per kind.
    // Profile-index records are independent (atomicByZone: false); profile-data
    // records within a zone must commit together (atomicByZone: true). See issue #61.
    guard let batchKind = Self.selectBatchKind(from: pendingChanges) else { return nil }
    let kindChanges = Self.filterChanges(pendingChanges, matching: batchKind)

    let batchLimit = 400
    let batch = Array(kindChanges.prefix(batchLimit))

    // Group saves by zone for efficient batch lookup
    var savesByZone: [CKRecordZone.ID: [CKRecord.ID]] = [:]
    var deletesByBatch: [CKRecord.ID] = []

    for change in batch {
      switch change {
      case .saveRecord(let recordID):
        savesByZone[recordID.zoneID, default: []].append(recordID)
      case .deleteRecord(let recordID):
        deletesByBatch.append(recordID)
      @unknown default:
        break
      }
    }

    // Build CKRecords for each zone using the appropriate handler
    var recordsToSave: [CKRecord] = []
    for (zoneID, recordIDs) in savesByZone {
      let zoneType = Self.parseZone(zoneID)

      switch zoneType {
      case .profileIndex:
        for recordID in recordIDs {
          if let record = profileIndexHandler.recordToSave(for: recordID) {
            recordsToSave.append(record)
          } else {
            // Bug fix #2: record deleted locally, queue server deletion
            handleMissingRecordToSave(recordID)
          }
        }

      case .profileData(let profileId):
        guard let handler = try? handlerForProfileZone(profileId: profileId, zoneID: zoneID)
        else {
          continue
        }

        // Separate UUID-based and string-based record names for batch lookup
        var uuidRecordNames: [(CKRecord.ID, UUID)] = []
        var stringRecordIDs: [CKRecord.ID] = []
        for recordID in recordIDs {
          if let uuid = UUID(uuidString: recordID.recordName) {
            uuidRecordNames.append((recordID, uuid))
          } else {
            stringRecordIDs.append(recordID)
          }
        }

        // Batch-load UUID-based records
        let recordLookup = handler.buildBatchRecordLookup(for: Set(uuidRecordNames.map(\.1)))

        for (recordID, uuid) in uuidRecordNames {
          if let record = recordLookup[uuid] {
            recordsToSave.append(record)
          } else {
            handleMissingRecordToSave(recordID)
          }
        }

        // Look up string-based records individually (InstrumentRecord)
        for recordID in stringRecordIDs {
          if let record = handler.recordToSave(for: recordID) {
            recordsToSave.append(record)
          } else {
            handleMissingRecordToSave(recordID)
          }
        }

      case .unknown:
        logger.warning("Pending save for unknown zone: \(zoneID.zoneName)")
      }
    }

    guard !recordsToSave.isEmpty || !deletesByBatch.isEmpty else { return nil }

    let zoneCount = Set(recordsToSave.map(\.recordID.zoneID)).union(deletesByBatch.map(\.zoneID))
      .count
    os_signpost(
      .event, log: Signposts.sync, name: "nextBatch", signpostID: signpostID,
      "%{public}d records across %{public}d zones", recordsToSave.count + deletesByBatch.count,
      zoneCount)

    return CKSyncEngine.RecordZoneChangeBatch(
      recordsToSave: recordsToSave,
      recordIDsToDelete: deletesByBatch,
      atomicByZone: batchKind.atomicByZone
    )
  }

  /// Bug fix #2: When `recordToSave` returns nil (record deleted locally before batch built),
  /// queue a `.deleteRecord` if one isn't already pending.
  private func handleMissingRecordToSave(_ recordID: CKRecord.ID) {
    guard let syncEngine else { return }
    let hasPendingDelete = syncEngine.state.pendingRecordZoneChanges.contains(
      .deleteRecord(recordID))
    if !hasPendingDelete {
      logger.info(
        "Record \(recordID.recordName) deleted locally before batch — queueing server deletion")
      syncEngine.state.add(pendingRecordZoneChanges: [.deleteRecord(recordID)])
    }
  }
}
