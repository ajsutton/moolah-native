import Foundation
import Testing

@testable import Moolah

@Suite("SessionManager")
@MainActor
struct SessionManagerTests {
  private func makeManager() throws -> SessionManager {
    let containerManager = try ProfileContainerManager.forTesting()
    return SessionManager(
      containerManager: containerManager,
      profileIndexRepository: containerManager.profileIndexRepositoryForTesting)
  }

  private func makeProfile(label: String = "Test") -> Profile {
    Profile(label: label)
  }

  private func openSession(_ manager: SessionManager, for profile: Profile) async throws
    -> ProfileSession
  {
    let result = await manager.session(for: profile)
    guard case .ready(let session) = result else {
      Issue.record("expected .ready, got \(result)")
      throw CancellationError()
    }
    return session
  }

  @Test("session(for:) creates a new session for unknown profile")
  func createsNewSession() async throws {
    let manager = try makeManager()
    let profile = makeProfile()

    let session = try await openSession(manager, for: profile)

    #expect(session.profile.id == profile.id)
    #expect(manager.sessions.count == 1)
  }

  @Test("session(for:) returns existing session for known profile")
  func reusesExistingSession() async throws {
    let manager = try makeManager()
    let profile = makeProfile()

    let session1 = try await openSession(manager, for: profile)
    let session2 = try await openSession(manager, for: profile)

    #expect(session1 === session2)
    #expect(manager.sessions.count == 1)
  }

  @Test("removeSession removes the session")
  func removesSession() async throws {
    let manager = try makeManager()
    let profile = makeProfile()

    _ = try await openSession(manager, for: profile)
    #expect(manager.sessions.count == 1)

    manager.removeSession(for: profile.id)
    #expect(manager.sessions.isEmpty)
  }

  @Test("rebuildSession replaces existing session with new instance")
  func rebuildsSession() async throws {
    let manager = try makeManager()
    let profile = makeProfile()

    let original = try await openSession(manager, for: profile)
    _ = await manager.rebuildSession(for: profile)
    let rebuilt = manager.sessions[profile.id]

    #expect(rebuilt !== original)
    #expect(rebuilt?.profile.id == profile.id)
    #expect(manager.sessions.count == 1)
  }

  @Test("multiple profiles get independent sessions")
  func independentSessions() async throws {
    let manager = try makeManager()
    let profile1 = makeProfile(label: "One")
    let profile2 = makeProfile(label: "Two")

    let session1 = try await openSession(manager, for: profile1)
    let session2 = try await openSession(manager, for: profile2)

    #expect(session1 !== session2)
    #expect(session1.profile.id != session2.profile.id)
    #expect(manager.sessions.count == 2)
  }

  @Test("removeSession for unknown ID is a no-op")
  func removeUnknownIsNoOp() throws {
    let manager = try makeManager()

    manager.removeSession(for: UUID())
    #expect(manager.sessions.isEmpty)
  }
}
