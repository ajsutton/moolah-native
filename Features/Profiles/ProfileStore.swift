import Foundation
import OSLog
import Observation

/// Manages the list of profiles and which one is active.
/// Persists to UserDefaults as JSON.
@Observable
@MainActor
final class ProfileStore {
  private static let profilesKey = "com.moolah.profiles"
  private static let activeProfileKey = "com.moolah.activeProfileID"

  private(set) var profiles: [Profile] = []
  private(set) var activeProfileID: UUID?
  private(set) var isValidating = false
  private(set) var validationError: String?

  private let defaults: UserDefaults
  private let validator: (any ServerValidator)?
  private let logger = Logger(subsystem: "com.moolah.app", category: "ProfileStore")

  var activeProfile: Profile? {
    profiles.first { $0.id == activeProfileID }
  }

  var hasProfiles: Bool {
    !profiles.isEmpty
  }

  init(defaults: UserDefaults = .standard, validator: (any ServerValidator)? = nil) {
    self.defaults = defaults
    self.validator = validator
    loadFromDefaults()
  }

  func addProfile(_ profile: Profile) {
    profiles.append(profile)
    if profiles.count == 1 {
      activeProfileID = profile.id
    }
    saveToDefaults()
    logger.debug("Added profile: \(profile.label) (\(profile.id))")
  }

  func removeProfile(_ id: UUID) {
    profiles.removeAll { $0.id == id }

    // Clean up the profile's keychain cookies
    let keychain = CookieKeychain(account: id.uuidString)
    keychain.clear()

    if activeProfileID == id {
      activeProfileID = profiles.first?.id
    }
    saveToDefaults()
    logger.debug("Removed profile: \(id)")
  }

  func setActiveProfile(_ id: UUID) {
    guard profiles.contains(where: { $0.id == id }) else { return }
    activeProfileID = id
    saveToDefaults()
    logger.debug("Switched to profile: \(id)")
  }

  func updateProfile(_ profile: Profile) {
    guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
    profiles[index] = profile
    saveToDefaults()
    logger.debug("Updated profile: \(profile.label)")
  }

  // MARK: - Validated mutations

  /// Validates the server URL then adds the profile. Returns true on success.
  func validateAndAddProfile(_ profile: Profile) async -> Bool {
    guard await validateServer(url: profile.resolvedServerURL) else { return false }
    addProfile(profile)
    return true
  }

  /// Validates the server URL then updates the profile. Returns true on success.
  func validateAndUpdateProfile(_ profile: Profile) async -> Bool {
    guard await validateServer(url: profile.resolvedServerURL) else { return false }
    updateProfile(profile)
    return true
  }

  func clearValidationError() {
    validationError = nil
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

  // MARK: - Persistence

  private func loadFromDefaults() {
    if let data = defaults.data(forKey: Self.profilesKey) {
      do {
        profiles = try JSONDecoder().decode([Profile].self, from: data)
        logger.debug("Loaded \(self.profiles.count) profiles from defaults")
      } catch {
        logger.error("Failed to decode profiles: \(error.localizedDescription)")
        profiles = []
      }
    }

    let savedIDString = defaults.string(forKey: Self.activeProfileKey)
    if let idString = savedIDString,
      let id = UUID(uuidString: idString),
      profiles.contains(where: { $0.id == id })
    {
      activeProfileID = id
      logger.debug("Restored active profile: \(id)")
    } else {
      activeProfileID = profiles.first?.id
      logger.debug(
        "No saved active profile (saved=\(savedIDString ?? "nil")), defaulting to first: \(self.activeProfileID?.uuidString ?? "nil")"
      )
    }
  }

  private func saveToDefaults() {
    do {
      let data = try JSONEncoder().encode(profiles)
      defaults.set(data, forKey: Self.profilesKey)
    } catch {
      logger.error("Failed to encode profiles: \(error.localizedDescription)")
    }

    if let activeProfileID {
      defaults.set(activeProfileID.uuidString, forKey: Self.activeProfileKey)
      logger.debug("Saved active profile: \(activeProfileID)")
    } else {
      defaults.removeObject(forKey: Self.activeProfileKey)
      logger.debug("Cleared active profile key")
    }
  }
}
