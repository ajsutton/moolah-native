import CloudKit
import Foundation
import OSLog
import Observation
import SwiftData

/// Manages the list of profiles and which one is active.
/// Remote profiles persist in UserDefaults; iCloud profiles persist in SwiftData (ProfileRecord).
/// Active profile ID is per-device via UserDefaults.
@Observable
@MainActor
final class ProfileStore {
  private static let profilesKey = "com.moolah.profiles"
  private static let activeProfileKey = "com.moolah.activeProfileID"

  private(set) var remoteProfiles: [Profile] = []
  private(set) var cloudProfiles: [Profile] = []
  private(set) var activeProfileID: UUID?
  private(set) var isValidating = false
  private(set) var validationError: String?

  private let defaults: UserDefaults
  private let validator: (any ServerValidator)?
  private let containerManager: ProfileContainerManager?
  private let logger = Logger(subsystem: "com.moolah.app", category: "ProfileStore")

  /// Combined list of all profiles from both backends.
  var profiles: [Profile] {
    remoteProfiles + cloudProfiles
  }

  var activeProfile: Profile? {
    profiles.first { $0.id == activeProfileID }
  }

  var hasProfiles: Bool {
    !profiles.isEmpty
  }

  init(
    defaults: UserDefaults = .standard,
    validator: (any ServerValidator)? = nil,
    containerManager: ProfileContainerManager? = nil
  ) {
    self.defaults = defaults
    self.validator = validator
    self.containerManager = containerManager
    loadFromDefaults()
    if containerManager != nil {
      loadCloudProfiles(isInitialLoad: true)
      scheduleRetryIfNeeded()
    }
  }

  func addProfile(_ profile: Profile) {
    switch profile.backendType {
    case .remote, .moolah:
      remoteProfiles.append(profile)
      saveToDefaults()
    case .cloudKit:
      guard let containerManager else {
        logger.error("Cannot add CloudKit profile without ProfileContainerManager")
        return
      }
      let context = ModelContext(containerManager.indexContainer)
      let record = ProfileRecord.from(profile: profile)
      context.insert(record)
      do {
        try context.save()
      } catch {
        logger.error("Failed to save CloudKit profile: \(error)")
      }
      cloudProfiles.append(profile)
    }

    if profiles.count == 1 {
      activeProfileID = profile.id
      saveActiveProfileID()
    }
    logger.debug("Added profile: \(profile.label) (\(profile.id))")
  }

  func removeProfile(_ id: UUID) {
    if let index = remoteProfiles.firstIndex(where: { $0.id == id }) {
      remoteProfiles.remove(at: index)

      // Clean up the profile's keychain cookies
      let keychain = CookieKeychain(account: id.uuidString)
      keychain.clear()

      saveToDefaults()
    } else if let index = cloudProfiles.firstIndex(where: { $0.id == id }) {
      cloudProfiles.remove(at: index)

      if let containerManager {
        containerManager.deleteStore(for: id)
        let context = ModelContext(containerManager.indexContainer)
        let deleter = ProfileDataDeleter(modelContext: context)
        deleter.deleteProfileRecord(for: id)
      }
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
    switch profile.backendType {
    case .remote, .moolah:
      guard let index = remoteProfiles.firstIndex(where: { $0.id == profile.id }) else { return }
      remoteProfiles[index] = profile
      saveToDefaults()
    case .cloudKit:
      guard let containerManager else { return }
      guard let index = cloudProfiles.firstIndex(where: { $0.id == profile.id }) else { return }
      cloudProfiles[index] = profile

      let context = ModelContext(containerManager.indexContainer)
      let profileId = profile.id
      let descriptor = FetchDescriptor<ProfileRecord>(
        predicate: #Predicate { $0.id == profileId }
      )
      if let record = try? context.fetch(descriptor).first {
        record.label = profile.label
        record.currencyCode = profile.currencyCode
        record.financialYearStartMonth = profile.financialYearStartMonth
        try? context.save()
      }
    }
    logger.debug("Updated profile: \(profile.label)")
  }

  // MARK: - Validated mutations

  /// Validates the server URL then adds the profile. Returns true on success.
  func validateAndAddProfile(_ profile: Profile) async -> Bool {
    switch profile.backendType {
    case .remote, .moolah:
      guard await validateServer(url: profile.resolvedServerURL) else { return false }
    case .cloudKit:
      guard await validateiCloudAvailability() else { return false }
    }
    addProfile(profile)
    return true
  }

  /// Validates the server URL then updates the profile. Returns true on success.
  func validateAndUpdateProfile(_ profile: Profile) async -> Bool {
    switch profile.backendType {
    case .remote, .moolah:
      guard await validateServer(url: profile.resolvedServerURL) else { return false }
    case .cloudKit:
      // No validation needed for updating an existing CloudKit profile
      break
    }
    updateProfile(profile)
    return true
  }

  func clearValidationError() {
    validationError = nil
  }

  // MARK: - Cloud Profile Loading

  func loadCloudProfiles(isInitialLoad: Bool = false) {
    guard let containerManager else { return }
    let context = ModelContext(containerManager.indexContainer)
    let descriptor = FetchDescriptor<ProfileRecord>(
      sortBy: [SortDescriptor(\.createdAt)]
    )
    do {
      let records = try context.fetch(descriptor)
      cloudProfiles = records.map { $0.toProfile() }
      logger.debug("Loaded \(self.cloudProfiles.count) cloud profiles")

      // Auto-select a profile when none is active (e.g. new device receiving
      // its first cloud profile from another device).
      if activeProfileID == nil, let first = profiles.first {
        self.activeProfileID = first.id
        saveActiveProfileID()
        logger.debug("Auto-selected profile: \(first.id)")
      }

      // Handle active profile being deleted on another device.
      // Skip this on initial load — SwiftData with CloudKit may return empty results
      // before the store is fully ready, which would incorrectly reset the active profile.
      if !isInitialLoad,
        let activeProfileID,
        !profiles.contains(where: { $0.id == activeProfileID })
      {
        self.activeProfileID = profiles.first?.id
        saveActiveProfileID()
        logger.debug(
          "Active profile was removed remotely, switched to: \(self.activeProfileID?.uuidString ?? "nil")"
        )
      }
    } catch {
      logger.error("Failed to load cloud profiles: \(error.localizedDescription)")
    }
  }

  // MARK: - Private

  private func validateiCloudAvailability() async -> Bool {
    isValidating = true
    validationError = nil
    defer { isValidating = false }

    // Check if CloudKit entitlements are configured first — CKContainer.default()
    // throws an uncatchable NSException without them.
    let containers =
      Bundle.main.object(forInfoDictionaryKey: "NSUbiquitousContainers") as? [String: Any]
    guard containers != nil, !containers!.isEmpty else {
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

  private func validateServer(url: URL) async -> Bool {
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

  /// If the initial load returned no cloud profiles but we expect some (saved activeProfileID
  /// doesn't match any remote profile), retry once after a short delay. SwiftData with CloudKit
  /// may not have its store ready on the first synchronous fetch.
  private func scheduleRetryIfNeeded() {
    guard cloudProfiles.isEmpty,
      let activeProfileID,
      !remoteProfiles.contains(where: { $0.id == activeProfileID })
    else { return }

    logger.debug("Cloud profiles empty on initial load, scheduling retry")
    Task { @MainActor [weak self] in
      try? await Task.sleep(for: .seconds(1))
      guard let self, self.cloudProfiles.isEmpty else { return }
      self.logger.debug("Retrying cloud profile load")
      self.loadCloudProfiles()
    }
  }

  // MARK: - Persistence

  private func loadFromDefaults() {
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

  private func saveToDefaults() {
    do {
      let data = try JSONEncoder().encode(remoteProfiles)
      defaults.set(data, forKey: Self.profilesKey)
    } catch {
      logger.error("Failed to encode profiles: \(error.localizedDescription)")
    }
  }

  private func saveActiveProfileID() {
    if let activeProfileID {
      defaults.set(activeProfileID.uuidString, forKey: Self.activeProfileKey)
      logger.debug("Saved active profile: \(activeProfileID)")
    } else {
      defaults.removeObject(forKey: Self.activeProfileKey)
      logger.debug("Cleared active profile key")
    }
  }
}
