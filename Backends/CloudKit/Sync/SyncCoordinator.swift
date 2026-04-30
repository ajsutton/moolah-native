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
///
/// The class body here is intentionally small: nested types, stored state, observers,
/// handler access, refetch scheduling, and state-file persistence. Lifecycle, zone
/// handling, backfill, record-change application, and the `CKSyncEngineDelegate`
/// conformance live in sibling extension files under `Backends/CloudKit/Sync/`.
@Observable
@MainActor
final class SyncCoordinator {

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

  /// Result of preparing a `CKSyncEngine` off the main actor — returned by
  /// `prepareEngine(stateFileURL:delegate:)` and consumed by `completeStart`.
  /// `@unchecked Sendable` because `CKSyncEngine` isn't declared `Sendable` by
  /// CloudKit, but we only transfer ownership one-way (prepare-thread → main
  /// actor) with no concurrent readers, so the Task.value happens-before edge
  /// makes it safe. Keep this struct to value types only.
  struct PreparedEngine: @unchecked Sendable {
    let engine: CKSyncEngine
    let isFirstLaunch: Bool
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

  let stateFileURL = URL.moolahScopedApplicationSupport
    .appending(path: "Moolah-v2-sync.syncstate")

  let containerManager: ProfileContainerManager
  let profileIndexHandler: ProfileIndexSyncHandler

  // Cross-file-access note: members below this MARK that sibling extension
  // files (Lifecycle / Zones / Backfill / RecordChanges / Delegate) touch are
  // `internal` rather than `private`. Swift does not treat extensions in
  // separate files as part of the same scope, so `private` would make them
  // unreachable. Public API surface is unchanged; no member here is reachable
  // outside the module that wasn't already reachable before the split.

  /// User defaults used to persist per-profile "backfill scan complete" flags so the
  /// scan runs at most once per profile across app launches. Injected for testing.
  let userDefaults: UserDefaults

  /// Key prefix for the per-profile backfill-scan-completed flag. The full key is
  /// `"\(backfillScanCompleteKeyPrefix).\(profileId.uuidString)"`.
  static let backfillScanCompleteKeyPrefix = "com.moolah.sync.backfillScanComplete"

  /// Observable sync progress consumed by the sidebar footer and the
  /// `.heroDownloading` Welcome arm. Always non-nil; SyncCoordinator
  /// drives transitions from its existing CKSyncEngine event hooks.
  let progress: SyncProgress

  let logger = Logger(subsystem: "com.moolah.app", category: "SyncCoordinator")

  var syncEngine: CKSyncEngine?

  var isRunning = false

  /// Tracks whether this coordinator started without saved state (first launch or migration).
  /// Used to guard against the synthetic `.signIn` event.
  var isFirstLaunch = false

  /// Observable iCloud account availability. `.unknown` while a probe is
  /// outstanding; see `handleAccountChange` in `SyncCoordinator+Zones.swift`
  /// for ongoing updates, and `completeStart` in `+Lifecycle.swift` for the
  /// initial probe. Views bind via `ProfileStore.iCloudAvailability`.
  var iCloudAvailability: ICloudAvailability = .unknown

  /// Captured at init from `CloudKitAuthProvider.isCloudKitAvailable` (or a
  /// test override). `false` short-circuits the initial probe in
  /// `completeStart` because the build has no iCloud entitlements.
  let isCloudKitAvailable: Bool

  /// Maps `CKAccountStatus` to ``ICloudAvailability``.
  /// `.couldNotDetermine` and thrown errors are treated as `.unknown`
  /// (transient) per design spec §6.1.
  nonisolated static func mapAccountStatus(
    _ status: CKAccountStatus
  ) -> ICloudAvailability {
    switch status {
    case .available:
      return .available
    case .noAccount:
      return .unavailable(reason: .notSignedIn)
    case .restricted:
      return .unavailable(reason: .restricted)
    case .temporarilyUnavailable:
      return .unavailable(reason: .temporarilyUnavailable)
    case .couldNotDetermine:
      return .unknown
    @unknown default:
      return .unknown
    }
  }

  /// True while CKSyncEngine is fetching changes (between willFetchChanges and didFetchChanges).
  var isFetchingChanges = false

  /// True when iCloud storage is full and sync uploads are failing.
  /// Cleared when a send cycle completes without quota errors.
  var isQuotaExceeded = false

  /// Record types accumulated per profile during a fetch session.
  var fetchSessionChangedTypes: [UUID: Set<String>] = [:]

  /// Whether the profile-index zone had changes during the current fetch session.
  var fetchSessionIndexChanged = false

  /// True once the `profile-index` zone has been fetched (even empty-handed)
  /// at least once since the last `start()`. `WelcomeView` uses this to
  /// swap "Checking iCloud…" for "No profiles in iCloud yet." once we
  /// know the answer. Must NOT flip on fetches that only touched
  /// `profile-data` zones. See design spec §6.2.
  /// Writable-internal because `+Lifecycle` (separate file) resets it
  /// inside `stop()` and flips it inside `endFetchingChanges()`.
  var profileIndexFetchedAtLeastOnce: Bool = false

  /// Per-session flag — set true inside the delegate zone-fetch path
  /// when the `profile-index` zone ID is observed, regardless of whether
  /// records were applied. Flushed into `profileIndexFetchedAtLeastOnce`
  /// inside `endFetchingChanges()`. Reset inside `beginFetchingChanges()`.
  var fetchSessionTouchedIndexZone = false

  /// Cached profile data handlers, keyed by profile UUID.
  var dataHandlers: [UUID: ProfileDataSyncHandler] = [:]

  /// Per-profile callback fired by the handler whenever a remote pull touches
  /// any `InstrumentRecord` row. Registered by `ProfileSession` ahead of the
  /// first sync session so it is available when the handler is lazily created
  /// in `handlerForProfileZone(profileId:zoneID:)`. Sendable so the closure
  /// can be captured into the handler's `nonisolated` storage.
  var instrumentRemoteChangeCallbacks: [UUID: @Sendable () -> Void] = [:]

  /// Per-profile GRDB repository bundle. Registered by `ProfileSession`
  /// during `registerWithSyncCoordinator` so it is available when
  /// `handlerForProfileZone(profileId:zoneID:)` lazily creates the
  /// `ProfileDataSyncHandler`. The handler's dispatch tables address
  /// these repositories directly so the per-record-type save / delete
  /// helpers can write into SQLite without leaking GRDB types into the
  /// CKSyncEngine wire layer. See `ProfileGRDBRepositories`.
  var profileGRDBRepositories: [UUID: ProfileGRDBRepositories] = [:]
  // Test-only fallback factory — see `+HandlerAccess.swift`.
  let fallbackGRDBRepositoriesFactory: (@Sendable (UUID) throws -> ProfileGRDBRepositories)?

  /// Zones with pending zone creation — records in these zones are skipped in nextRecordZoneChangeBatch.
  var pendingZoneCreation: [CKRecordZone.ID: [CKSyncEngine.PendingRecordZoneChange]] = [:]

  /// Active zone creation tasks, keyed by zone ID.
  var zoneCreationTasks: [CKRecordZone.ID: Task<Void, Never>] = [:]

  /// The zone setup task (creates profile-index zone on start).
  var zoneSetupTask: Task<Void, Never>?

  /// Task that runs `CKSyncEngine.init` off the main actor. Held so it can be
  /// awaited/cancelled from `stop()`.
  var startTask: Task<Void, Never>?

  /// Task for coalescing re-fetch requests after save failures.
  var refetchTask: Task<Void, Never>?

  /// Last-resort periodic retry scheduled after the short-retry budget is exhausted.
  /// Fires every `longRetryInterval`, resets the short-retry counter, and re-triggers
  /// a fetch so persistent failures don't leave local data silently incomplete.
  var longRetryTask: Task<Void, Never>?

  /// Initial `CKContainer.accountStatus()` probe kicked off from
  /// `completeStart`. Held so `stop()` can cancel it.
  var availabilityProbeTask: Task<Void, Never>?

  /// Number of consecutive re-fetch attempts scheduled after a save failure.
  /// Reset to zero whenever a fetched-record-zone-changes batch applies successfully.
  /// Exposed for testing.
  var refetchAttempts = 0

  /// `true` while a last-resort periodic retry is pending. Exposed for testing.
  var hasPendingLongRetry: Bool { longRetryTask != nil }

  // (Re-fetch backoff constants and `refetchBackoff(forAttempt:)` live in
  // `SyncCoordinator+Lifecycle.swift` with the rest of the lifecycle
  // wiring.)

  // MARK: - Init

  init(
    containerManager: ProfileContainerManager,
    userDefaults: UserDefaults = .standard,
    isCloudKitAvailable: Bool = CloudKitAuthProvider.isCloudKitAvailable,
    fallbackGRDBRepositoriesFactory: (@Sendable (UUID) throws -> ProfileGRDBRepositories)? = nil
  ) {
    self.containerManager = containerManager
    self.userDefaults = userDefaults
    self.progress = SyncProgress(userDefaults: userDefaults)
    self.profileIndexHandler = ProfileIndexSyncHandler(
      repository: containerManager.profileIndexRepository)
    self.isCloudKitAvailable = isCloudKitAvailable
    self.fallbackGRDBRepositoriesFactory = fallbackGRDBRepositoriesFactory
    if !isCloudKitAvailable {
      applyICloudAvailability(.unavailable(reason: .entitlementsMissing))
    }
    // SAFETY: wireProfileIndexHooks() must remain the last statement in init.
    // The closures it installs capture `[weak self]` and depend on every
    // stored property of SyncCoordinator being assigned.
    wireProfileIndexHooks()
  }

  // MARK: - Fetch-Session Book-keeping
  // (Begin/end live on `+Lifecycle`; the isFetchingChanges flag is mutated there
  // and by `+Zones` on sign-out.)

  /// Accumulate changed types for a profile during a fetch session. Exposed for testing.
  func accumulateFetchSessionChanges(for profileId: UUID, changedTypes: Set<String>) {
    fetchSessionChangedTypes[profileId, default: []].formUnion(changedTypes)
  }

  // MARK: - Handler Access
  // (Lazy `ProfileDataSyncHandler` creation and the per-profile
  // instrument-change callback registry live on `+HandlerAccess`.)

  // MARK: - State Persistence
  // (Load of the state serialization happens off-actor in `prepareEngine`, on `+Lifecycle`.)

  func saveStateSerialization(_ serialization: CKSyncEngine.State.Serialization) {
    do {
      let data = try JSONEncoder().encode(serialization)
      try data.write(to: stateFileURL, options: .atomic)
    } catch {
      logger.error("Failed to save sync state: \(error, privacy: .public)")
    }
  }

  func deleteStateSerialization() {
    try? FileManager.default.removeItem(at: stateFileURL)
  }
}
