import CloudKit
import Foundation
import OSLog
import Observation
import SwiftData

/// Manages the list of profiles and which one is active.
/// Profiles persist as CloudKit `ProfileRecord` rows in SwiftData; the active
/// profile ID is per-device via UserDefaults.
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
  /// SwiftData with CloudKit may not have its store ready on the first fetch.
  var isCloudLoadPending = false

  /// The currently-scheduled retry task, tracked so it can be cancelled when a
  /// fresh load arrives (e.g. from a remote change notification) or when a new
  /// retry is queued. See `guides/CONCURRENCY_GUIDE.md` — fire-and-forget
  /// `Task {}` in stores must be tracked.
  var retryTask: Task<Void, Never>?

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

  func addProfile(_ profile: Profile) {
    guard let containerManager else {
      logger.error("Cannot add CloudKit profile without ProfileContainerManager")
      return
    }
    let context = ModelContext(containerManager.indexContainer)
    let record = ProfileRecord.from(profile: profile)
    context.insert(record)
    do {
      try context.save()
      onProfileChanged?(profile.id)
    } catch {
      logger.error("Failed to save CloudKit profile: \(error)")
    }
    profiles.append(profile)

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
        let context = ModelContext(containerManager.indexContainer)
        let deleter = ProfileDataDeleter(modelContext: context)
        deleter.deleteProfileRecord(for: id)
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

    let context = ModelContext(containerManager.indexContainer)
    let profileId = profile.id
    let descriptor = FetchDescriptor<ProfileRecord>(
      predicate: #Predicate { $0.id == profileId }
    )
    if let record = try? context.fetch(descriptor).first {
      record.label = profile.label
      record.currencyCode = profile.currencyCode
      record.financialYearStartMonth = profile.financialYearStartMonth
      do {
        try context.save()
        onProfileChanged?(profile.id)
      } catch {
        logger.error("Failed to save CloudKit profile update: \(error)")
      }
    }
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
