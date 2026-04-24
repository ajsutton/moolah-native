import CloudKit
import Foundation
import SwiftData

// Cloud-profile loading, server/iCloud validation helpers, and UserDefaults
// persistence extracted from the main `ProfileStore` body so it stays under
// SwiftLint's `type_body_length` threshold. All members execute on the main
// actor (`ProfileStore` is `@MainActor`).
extension ProfileStore {

  // MARK: - Cloud Profile Loading

  func loadCloudProfiles(isInitialLoad: Bool = false) {
    guard let containerManager else { return }
    let context = ModelContext(containerManager.indexContainer)
    let descriptor = FetchDescriptor<ProfileRecord>(
      sortBy: [SortDescriptor(\.createdAt)]
    )
    do {
      let previousCloudProfiles = cloudProfiles
      let records = try context.fetch(descriptor)
      cloudProfiles = records.map { $0.toProfile() }
      logger.debug("Loaded \(self.cloudProfiles.count) cloud profiles")

      // If this load produced cloud profiles, any pending retry is now
      // redundant — cancel it so we don't do unnecessary work after the
      // store is ready.
      if !cloudProfiles.isEmpty {
        cancelPendingRetry()
      }

      // Auto-select a profile when none is active AND there is exactly one
      // profile in total (e.g. new device receiving its first cloud profile
      // from another device). Suppressed when `WelcomeView` is mid-create —
      // see design spec §3.3 race condition. With two or more profiles, the
      // `WelcomeView` picker (state 5) lets the user choose explicitly.
      if activeProfileID == nil,
        profiles.count == 1,
        let first = profiles.first,
        welcomePhase != .creating
      {
        self.activeProfileID = first.id
        saveActiveProfileID()
        logger.debug("Auto-selected profile: \(first.id)")
      } else if welcomePhase == .creating {
        logger.debug("Skipped auto-select — welcomePhase == .creating")
      } else if activeProfileID == nil, profiles.count > 1 {
        let profileCount = profiles.count
        logger.debug(
          "Skipped auto-select — \(profileCount) profiles present, picker will choose"
        )
      }

      // Handle profiles deleted on another device.
      // Skip this on initial load — SwiftData with CloudKit may return empty results
      // before the store is fully ready, which would incorrectly reset the active profile.
      if !isInitialLoad {
        let newIDs = Set(cloudProfiles.map(\.id))
        for oldProfile in previousCloudProfiles where !newIDs.contains(oldProfile.id) {
          logger.info(
            "Cloud profile \(oldProfile.id) was removed remotely — cleaning up local store")
          containerManager.deleteStore(for: oldProfile.id)
          onProfileRemoved?(oldProfile.id)
        }

        if let activeProfileID,
          !profiles.contains(where: { $0.id == activeProfileID })
        {
          self.activeProfileID = profiles.first?.id
          saveActiveProfileID()
          logger.debug(
            "Active profile was removed remotely, switched to: \(self.activeProfileID?.uuidString ?? "nil")"
          )
        }
      }
    } catch {
      logger.error("Failed to load cloud profiles: \(error.localizedDescription)")
    }
  }

  // MARK: - Validation

  func validateiCloudAvailability() async -> Bool {
    isValidating = true
    validationError = nil
    defer { isValidating = false }

    guard CloudKitAuthProvider.isCloudKitAvailable else {
      // No CloudKit entitlements — allow local-only SwiftData profiles
      return true
    }

    do {
      let status = try await CKContainer.default().accountStatus()
      if status == .available {
        return true
      } else {
        validationError = "iCloud is not available. Please sign in to iCloud in Settings."
        return false
      }
    } catch {
      validationError = "Could not check iCloud availability"
      return false
    }
  }

  func validateServer(url: URL) async -> Bool {
    guard let validator else { return true }
    isValidating = true
    validationError = nil
    defer { isValidating = false }

    do {
      try await validator.validate(url: url)
      return true
    } catch let error as BackendError {
      if case .validationFailed(let message) = error {
        validationError = message
      } else {
        validationError = "Could not connect to server"
      }
      return false
    } catch {
      validationError = "Could not connect to server"
      return false
    }
  }

  // MARK: - Retry scheduling

  /// If the initial load returned no cloud profiles but we expect some (saved activeProfileID
  /// doesn't match any remote profile), retry once after a short delay. SwiftData with CloudKit
  /// may not have its store ready on the first synchronous fetch.
  func scheduleRetryIfNeeded() {
    guard cloudProfiles.isEmpty,
      let activeProfileID,
      !remoteProfiles.contains(where: { $0.id == activeProfileID })
    else { return }

    // Cancel any existing retry before starting a new one so we never run
    // two pending retries concurrently.
    retryTask?.cancel()

    isCloudLoadPending = true
    logger.debug("Cloud profiles empty on initial load, scheduling retry")
    retryTask = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .seconds(1))
      guard !Task.isCancelled, let self, self.cloudProfiles.isEmpty else {
        self?.isCloudLoadPending = false
        self?.retryTask = nil
        return
      }
      self.logger.debug("Retrying cloud profile load")
      self.loadCloudProfiles()
      self.isCloudLoadPending = false
      self.retryTask = nil
    }
  }

  /// Cancels any in-flight retry task. Called when an external event (such as
  /// a remote change notification driving `loadCloudProfiles()`) makes the
  /// pending retry redundant.
  func cancelPendingRetry() {
    guard retryTask != nil else { return }
    retryTask?.cancel()
    retryTask = nil
    isCloudLoadPending = false
  }

  // MARK: - Persistence

  func loadFromDefaults() {
    if let data = defaults.data(forKey: Self.profilesKey) {
      do {
        remoteProfiles = try JSONDecoder().decode([Profile].self, from: data)
        logger.debug("Loaded \(self.remoteProfiles.count) remote profiles from defaults")
      } catch {
        logger.error("Failed to decode profiles: \(error.localizedDescription)")
        remoteProfiles = []
      }
    }

    let savedIDString = defaults.string(forKey: Self.activeProfileKey)
    if let idString = savedIDString,
      let id = UUID(uuidString: idString)
    {
      // Validate against all profiles after cloud profiles are loaded;
      // for now just restore the saved ID
      activeProfileID = id
      logger.debug("Restored active profile: \(id)")
    } else {
      activeProfileID = nil
      logger.debug(
        "No saved active profile (saved=\(savedIDString ?? "nil"))"
      )
    }
  }

  func saveToDefaults() {
    do {
      let data = try JSONEncoder().encode(remoteProfiles)
      defaults.set(data, forKey: Self.profilesKey)
    } catch {
      logger.error("Failed to encode profiles: \(error.localizedDescription)")
    }
  }

  func saveActiveProfileID() {
    if let activeProfileID {
      defaults.set(activeProfileID.uuidString, forKey: Self.activeProfileKey)
      logger.debug("Saved active profile: \(activeProfileID)")
    } else {
      defaults.removeObject(forKey: Self.activeProfileKey)
      logger.debug("Cleared active profile key")
    }
  }
}
