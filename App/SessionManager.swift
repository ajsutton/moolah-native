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
  let syncCoordinator: SyncCoordinator?

  init(containerManager: ProfileContainerManager, syncCoordinator: SyncCoordinator? = nil) {
    self.containerManager = containerManager
    self.syncCoordinator = syncCoordinator
  }

  /// Returns the existing session for a profile, or creates one.
  func session(for profile: Profile) -> ProfileSession {
    if let existing = sessions[profile.id] { return existing }
    let session = ProfileSession(
      profile: profile, containerManager: containerManager, syncCoordinator: syncCoordinator)
    sessions[profile.id] = session
    return session
  }

  /// Removes the session for a profile (e.g. when profile is deleted).
  func removeSession(for profileID: UUID) {
    if let session = sessions.removeValue(forKey: profileID), let syncCoordinator {
      session.cleanupSync(coordinator: syncCoordinator)
    }
  }

  // MARK: - Automation Lookup

  /// Find an open session by profile name (case-insensitive).
  func session(named name: String) -> ProfileSession? {
    let lowered = name.lowercased()
    return sessions.values.first { $0.profile.label.lowercased() == lowered }
  }

  /// Find an open session by profile UUID.
  func session(forID id: UUID) -> ProfileSession? {
    sessions[id]
  }

  /// All currently open profile sessions.
  var openProfiles: [ProfileSession] {
    Array(sessions.values)
  }

  /// Replaces the session for a profile with a fresh instance
  /// (e.g. when the profile's server URL changes).
  func rebuildSession(for profile: Profile) {
    if let oldSession = sessions[profile.id], let syncCoordinator {
      oldSession.cleanupSync(coordinator: syncCoordinator)
    }
    sessions[profile.id] = ProfileSession(
      profile: profile, containerManager: containerManager, syncCoordinator: syncCoordinator)
  }
}
