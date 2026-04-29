import Foundation
import SwiftData

/// Owns the mapping from Profile.ID to ProfileSession.
/// Multiple macOS windows share session instances through this manager.
/// Injected via `.environment(sessionManager)` at the app level.
@Observable
@MainActor
final class SessionManager {
  /// Map from `Profile.ID` to the live `ProfileSession`.
  ///
  /// **Mutation invariant:** any code path that drops or replaces a
  /// session **must** go through `removeSession(for:)` or
  /// `rebuildSession(for:)` so the session's `cleanupSync(coordinator:)`
  /// runs first. `cleanupSync` is the only place that cancels the
  /// session's tracked tasks (`syncReloadTask`, `catalogRefreshTask`,
  /// `pragmaOptimizeTask`); a direct mutation to `sessions` would leak
  /// any of those that happen to be in flight. Adding new tracked tasks
  /// to `ProfileSession`? Cancel them in `cleanupSync` and uphold this
  /// rule for any new mutation site.
  private(set) var sessions: [UUID: ProfileSession] = [:]
  let containerManager: ProfileContainerManager
  let syncCoordinator: SyncCoordinator?

  init(containerManager: ProfileContainerManager, syncCoordinator: SyncCoordinator? = nil) {
    self.containerManager = containerManager
    self.syncCoordinator = syncCoordinator
  }

  /// Returns the existing session for a profile, or creates one.
  ///
  /// Database creation can fail (disk full, permissions denied, schema
  /// migration error). On failure we crash with a descriptive message —
  /// the app cannot meaningfully run without per-profile storage and
  /// silent fallback would mask data loss.
  ///
  /// Synchronous so SwiftUI view bodies can call it directly. The
  /// SwiftData → GRDB migration that used to run inside
  /// `ProfileSession.init` now lives in `session.setUp()` (issue #575)
  /// and is scheduled here as a background task so it runs off
  /// `@MainActor`. Callers that need the migration to be observed (e.g.
  /// tests) can `await session.setUp()` to wait for completion.
  func session(for profile: Profile) -> ProfileSession {
    if let existing = sessions[profile.id] { return existing }
    let session: ProfileSession
    do {
      session = try ProfileSession(
        profile: profile, containerManager: containerManager, syncCoordinator: syncCoordinator)
    } catch {
      fatalError("Failed to open profile database for \(profile.id): \(error)")
    }
    sessions[profile.id] = session
    Task { try? await session.setUp() }
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
  /// (e.g. when the profile's server URL changes). Schedules `setUp()`
  /// on the new session so the migration runs off `@MainActor` (see
  /// `session(for:)` for the same pattern).
  func rebuildSession(for profile: Profile) {
    if let oldSession = sessions[profile.id], let syncCoordinator {
      oldSession.cleanupSync(coordinator: syncCoordinator)
    }
    let session: ProfileSession
    do {
      session = try ProfileSession(
        profile: profile, containerManager: containerManager, syncCoordinator: syncCoordinator)
    } catch {
      fatalError("Failed to rebuild profile database for \(profile.id): \(error)")
    }
    sessions[profile.id] = session
    Task { try? await session.setUp() }
  }
}
