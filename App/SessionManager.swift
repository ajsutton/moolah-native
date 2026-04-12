import Foundation
import SwiftData

/// Owns the mapping from Profile.ID to ProfileSession.
/// Multiple macOS windows share session instances through this manager.
/// Injected via `.environment(sessionManager)` at the app level.
@Observable
@MainActor
final class SessionManager {
  private(set) var sessions: [UUID: ProfileSession] = [:]
  let containerManager: ProfileContainerManager

  init(containerManager: ProfileContainerManager) {
    self.containerManager = containerManager
  }

  /// Returns the existing session for a profile, or creates one.
  func session(for profile: Profile) -> ProfileSession {
    if let existing = sessions[profile.id] { return existing }
    let session = ProfileSession(profile: profile, containerManager: containerManager)
    sessions[profile.id] = session
    return session
  }

  /// Removes the session for a profile (e.g. when profile is deleted).
  func removeSession(for profileID: UUID) {
    sessions.removeValue(forKey: profileID)
  }

  /// Replaces the session for a profile with a fresh instance
  /// (e.g. when the profile's server URL changes).
  func rebuildSession(for profile: Profile) {
    sessions[profile.id] = ProfileSession(profile: profile, containerManager: containerManager)
  }
}
