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

  private let defaults: UserDefaults
  private let logger = Logger(subsystem: "com.moolah.app", category: "ProfileStore")

  var activeProfile: Profile? {
    profiles.first { $0.id == activeProfileID }
  }

  var hasProfiles: Bool {
    !profiles.isEmpty
  }

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
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

  // MARK: - Persistence

  private func loadFromDefaults() {
    if let data = defaults.data(forKey: Self.profilesKey) {
      do {
        profiles = try JSONDecoder().decode([Profile].self, from: data)
      } catch {
        logger.error("Failed to decode profiles: \(error.localizedDescription)")
        profiles = []
      }
    }

    if let idString = defaults.string(forKey: Self.activeProfileKey),
      let id = UUID(uuidString: idString),
      profiles.contains(where: { $0.id == id })
    {
      activeProfileID = id
    } else {
      activeProfileID = profiles.first?.id
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
    } else {
      defaults.removeObject(forKey: Self.activeProfileKey)
    }
  }
}
