import Foundation
import OSLog

private let logger = Logger(subsystem: "com.moolah.app", category: "AutomationService")

@MainActor
final class AutomationService {
  let sessionManager: SessionManager

  init(sessionManager: SessionManager) {
    self.sessionManager = sessionManager
  }

  /// Resolves a profile session by name (case-insensitive) or UUID string.
  func resolveSession(for identifier: String) throws -> ProfileSession {
    if let session = sessionManager.session(named: identifier) { return session }
    if let uuid = UUID(uuidString: identifier),
      let session = sessionManager.session(forID: uuid)
    {
      return session
    }
    throw AutomationError.profileNotFound(identifier)
  }

  /// Returns all currently open profiles.
  func listOpenProfiles() -> [Profile] {
    sessionManager.openProfiles.map(\.profile)
  }
}
