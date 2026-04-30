import CloudKit
import Foundation

// Cloud-profile loading, iCloud validation helpers, and UserDefaults
// persistence extracted from the main `ProfileStore` body so it stays under
// SwiftLint's `type_body_length` threshold. All members execute on the main
// actor (`ProfileStore` is `@MainActor`).
extension ProfileStore {

  // MARK: - Cloud Profile Loading

  /// Loads the cloud profile list from `profile-index.sqlite`. The fetch
  /// itself runs off the main actor; the returned profiles are applied
  /// back on the main actor via `applyLoadedProfiles(_:isInitialLoad:)`.
  /// One main-actor tick passes between the call and the visible state
  /// change. SwiftUI `@Observable` propagation handles the deferred
  /// update transparently.
  func loadCloudProfiles(isInitialLoad: Bool = false) {
    guard let containerManager else { return }
    let repo = containerManager.profileIndexRepository
    let task = Task { [weak self] in
      do {
        let loaded = try await repo.fetchAll()
        await MainActor.run { [weak self] in
          self?.applyLoadedProfiles(loaded, isInitialLoad: isInitialLoad)
        }
      } catch {
        await MainActor.run { [weak self] in
          self?.logger.error(
            "Failed to load cloud profiles: \(error, privacy: .public)")
        }
      }
    }
    trackMutation(task)
  }

  /// Applies a freshly-loaded cloud profile list. Mirrors the contract
  /// of the previous synchronous fetch: in-place state mutation, the
  /// auto-activate guard, the remote-deletion cleanup, and the
  /// pending-retry cancel.
  ///
  /// Race-condition guard: the GRDB write triggered by `addProfile`
  /// is fire-and-forget. If `loadCloudProfiles` lands the read of an
  /// empty GRDB table after `addProfile` optimistically appended a
  /// row, blindly assigning `profiles = loaded` would clobber the
  /// optimistic addition and the UI would briefly show no profiles.
  /// On the **initial** load, an empty result is treated as "the
  /// migrator / remote-import hasn't landed yet" and is ignored —
  /// the retry scheduled by `scheduleRetryIfNeeded` will pick the
  /// rows up once they're on disk. Subsequent loads (`isInitialLoad ==
  /// false`) honour the empty result so genuine remote deletions
  /// still flow through.
  private func applyLoadedProfiles(_ loaded: [Profile], isInitialLoad: Bool) {
    if isInitialLoad, loaded.isEmpty, !profiles.isEmpty {
      logger.debug(
        "Initial cloud load returned empty while profiles already present — skipping overwrite"
      )
      return
    }
    let previousCloudProfiles = profiles
    profiles = loaded
    logger.debug("Loaded \(self.profiles.count) cloud profiles")

    // If this load produced cloud profiles, any pending retry is now
    // redundant — cancel it so we don't do unnecessary work after the
    // store is ready.
    if !profiles.isEmpty {
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
    // Skip this on initial load — the GRDB store may return empty
    // before the migrator finishes copying rows from SwiftData, which
    // would incorrectly reset the active profile.
    if !isInitialLoad {
      let newIDs = Set(profiles.map(\.id))
      for oldProfile in previousCloudProfiles where !newIDs.contains(oldProfile.id) {
        logger.info(
          "Cloud profile \(oldProfile.id) was removed remotely — cleaning up local store")
        containerManager?.deleteStore(for: oldProfile.id)
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
  }

  // MARK: - Validation

  func validateiCloudAvailability() async -> Bool {
    isValidating = true
    validationError = nil
    defer { isValidating = false }

    guard CloudKitAuthProvider.isCloudKitAvailable else {
      // No CloudKit entitlements — allow local-only profiles.
      return true
    }

    do {
      let status = try await CloudKitContainer.app.accountStatus()
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

  // MARK: - Retry scheduling

  /// If the initial load returned no cloud profiles but we expect some (saved activeProfileID
  /// doesn't match any remote profile), retry once after a short delay. The GRDB
  /// profile-index DB may not have its migration completed on the first synchronous fetch.
  func scheduleRetryIfNeeded() {
    guard profiles.isEmpty,
      activeProfileID != nil
    else { return }

    // Cancel any existing retry before starting a new one so we never run
    // two pending retries concurrently.
    retryTask?.cancel()

    isCloudLoadPending = true
    logger.debug("Cloud profiles empty on initial load, scheduling retry")
    retryTask = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .seconds(1))
      guard !Task.isCancelled, let self, self.profiles.isEmpty else {
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
