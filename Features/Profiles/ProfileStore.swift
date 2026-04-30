import CloudKit
import Foundation
import OSLog
import Observation

/// Manages the list of profiles and which one is active.
/// Profiles persist as CloudKit `ProfileRecord` rows in the GRDB
/// profile-index database; the active profile ID is per-device via
/// UserDefaults.
@Observable
@MainActor
final class ProfileStore {
  // internal (was private) so the `+Cloud` extension can key UserDefaults
  // lookups under the same constants.
  static let activeProfileKey = "com.moolah.activeProfileID"

  // Setters widened from `private(set)` to default (internal) so the
  // `+Cloud` extension file can mutate them while loading / validating.
  var profiles: [Profile] = []
  var activeProfileID: UUID?
  var isValidating = false
  var validationError: String?

  /// Signal from `WelcomeView` about which interaction phase is on screen.
  /// When `.creating`, `loadCloudProfiles` suppresses its auto-activate
  /// behaviour so a single profile arriving from iCloud doesn't race the
  /// user's in-flight "Create Profile" tap. Cleared (`nil`) when
  /// `WelcomeView` unmounts. See design spec §3.3, §8.
  enum WelcomePhase: Sendable {
    case landing
    case creating
    case pickingProfile
  }

  var welcomePhase: WelcomePhase?

  /// True while the initial cloud profile load may still be retrying.
  /// CloudKit-driven remote inserts may not have landed yet on the
  /// first fetch.
  var isCloudLoadPending = false

  /// The currently-scheduled retry task, tracked so it can be cancelled when a
  /// fresh load arrives (e.g. from a remote change notification) or when a new
  /// retry is queued. See `guides/CONCURRENCY_GUIDE.md` — fire-and-forget
  /// `Task {}` in stores must be tracked.
  var retryTask: Task<Void, Never>?

  /// In-flight tracked tasks for fire-and-forget GRDB writes (add /
  /// update / remove / cloud load). Tasks self-evict on completion so
  /// the array doesn't grow unbounded across long-running sessions.
  /// See `guides/CONCURRENCY_GUIDE.md` — every fire-and-forget Task
  /// in a store must be tracked so the lifecycle is observable.
  ///
  /// `private(set)` so test code can read (drain) the array but only
  /// the store can append to it.
  private(set) var pendingMutationTasks: [Task<Void, Never>] = []

  /// Called when a cloud profile is removed (locally or via remote sync).
  /// Used by SessionManager to tear down the corresponding ProfileSession.
  var onProfileRemoved: ((UUID) -> Void)?

  /// Called after a CloudKit profile is created or updated locally.
  /// Used by SyncCoordinator to queue the profile for upload.
  var onProfileChanged: ((UUID) -> Void)?

  /// Called after a CloudKit profile is deleted locally.
  /// Used by SyncCoordinator to queue the profile for deletion.
  var onProfileDeleted: ((UUID) -> Void)?

  // internal (was private) so the `+Cloud` extension can reach the injected
  // dependencies and logger.
  let defaults: UserDefaults
  let containerManager: ProfileContainerManager?
  private let syncCoordinator: SyncCoordinator?
  let logger = Logger(subsystem: "com.moolah.app", category: "ProfileStore")

  /// Pass-through to ``SyncCoordinator/iCloudAvailability``. `.unknown`
  /// when no coordinator was injected (tests, previews). View code (e.g.
  /// `WelcomeView`) reads this rather than reaching into the sync layer.
  var iCloudAvailability: ICloudAvailability {
    syncCoordinator?.iCloudAvailability ?? .unknown
  }

  var activeProfile: Profile? {
    profiles.first { $0.id == activeProfileID }
  }

  var hasProfiles: Bool {
    !profiles.isEmpty
  }

  init(
    defaults: UserDefaults = .standard,
    containerManager: ProfileContainerManager? = nil,
    syncCoordinator: SyncCoordinator? = nil
  ) {
    self.defaults = defaults
    self.containerManager = containerManager
    self.syncCoordinator = syncCoordinator
    loadFromDefaults()
    if containerManager != nil {
      loadCloudProfiles(isInitialLoad: true)
      scheduleRetryIfNeeded()
    } else {
      // No CloudKit — nothing pending
      isCloudLoadPending = false
    }
  }

  deinit {
    // Cancel every in-flight fire-and-forget mutation and the retry
    // task so GRDB writes don't outlive the store. Swift 6 makes
    // `deinit` `nonisolated`, so reading `@MainActor`-isolated state
    // requires `MainActor.assumeIsolated` — the deinit is invoked
    // from a main-actor reference release in practice (the store is
    // owned by main-actor code), so the assumption holds.
    MainActor.assumeIsolated {
      for task in pendingMutationTasks { task.cancel() }
      retryTask?.cancel()
    }
  }

  /// Tracks a fire-and-forget mutation Task. The task self-evicts from
  /// `pendingMutationTasks` on completion so the array doesn't grow
  /// unbounded over a long session.
  func trackMutation(_ task: Task<Void, Never>) {
    pendingMutationTasks.append(task)
    // The bookkeeping Task is intentionally untracked: its only side
    // effect is cleaning up the array, which becomes a no-op when
    // `self` has already deallocated (the `[weak self]` capture goes
    // nil and the array is gone). Tracking it would create infinite
    // self-recursion through `trackMutation`.
    Task { [weak self] in
      _ = await task.value
      self?.pendingMutationTasks.removeAll { $0 == task }
    }
  }

  func addProfile(_ profile: Profile) {
    guard let containerManager else {
      logger.error("Cannot add CloudKit profile without ProfileContainerManager")
      return
    }
    profiles.append(profile)
    let task = Task { [weak self] in
      do {
        try await containerManager.profileIndexRepository.upsert(profile)
      } catch {
        self?.logger.error("Failed to save CloudKit profile: \(error, privacy: .public)")
      }
    }
    trackMutation(task)
    // Fire the legacy store-side change callback synchronously to
    // preserve the pre-Phase-A behaviour for callers that observe it
    // (e.g. `ExportCoordinator.importNewProfileFromFile`'s rollback
    // path captures the id mid-flight). The GRDB-side
    // `onRecordChanged` hook from `attachSyncHooks` fires when the
    // async write commits; both queue idempotent CKSyncEngine state.
    onProfileChanged?(profile.id)

    if profiles.count == 1 {
      activeProfileID = profile.id
      saveActiveProfileID()
    }
    logger.debug("Added profile: \(profile.label) (\(profile.id))")
  }

  func removeProfile(_ id: UUID) {
    if let index = profiles.firstIndex(where: { $0.id == id }) {
      profiles.remove(at: index)

      if let containerManager {
        containerManager.deleteStore(for: id)
        let task = Task { [weak self] in
          do {
            _ = try await containerManager.profileIndexRepository.delete(id: id)
          } catch {
            self?.logger.error(
              "Failed to delete CloudKit profile row: \(error, privacy: .public)")
          }
        }
        trackMutation(task)
      }
      onProfileDeleted?(id)
      onProfileRemoved?(id)
    }

    if activeProfileID == id {
      activeProfileID = profiles.first?.id
      saveActiveProfileID()
    }
    logger.debug("Removed profile: \(id)")
  }

  func setActiveProfile(_ id: UUID) {
    guard profiles.contains(where: { $0.id == id }) else { return }
    activeProfileID = id
    saveActiveProfileID()
    logger.debug("Switched to profile: \(id)")
  }

  func updateProfile(_ profile: Profile) {
    guard let containerManager else { return }
    guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
    profiles[index] = profile

    let task = Task { [weak self] in
      do {
        try await containerManager.profileIndexRepository.upsert(profile)
      } catch {
        self?.logger.error(
          "Failed to save CloudKit profile update: \(error, privacy: .public)")
      }
    }
    trackMutation(task)
    // See `addProfile` for the rationale: fire the legacy callback
    // synchronously so observers see the change at the same point as
    // the in-place state mutation.
    onProfileChanged?(profile.id)
    logger.debug("Updated profile: \(profile.label)")
  }

  // MARK: - Validated mutations

  /// Validates iCloud availability then adds the profile. Returns true on success.
  func validateAndAddProfile(_ profile: Profile) async -> Bool {
    guard await validateiCloudAvailability() else { return false }
    addProfile(profile)
    return true
  }

  func clearValidationError() {
    validationError = nil
  }

}
