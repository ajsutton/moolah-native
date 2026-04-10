import Foundation
import Testing

@testable import Moolah

@Suite("SessionManager")
@MainActor
struct SessionManagerTests {
  private func makeManager() throws -> SessionManager {
    let container = try TestModelContainer.create()
    return SessionManager(modelContainer: container)
  }

  private func makeProfile(
    label: String = "Test",
    url: String = "https://moolah.rocks/api/"
  ) -> Profile {
    Profile(label: label, serverURL: URL(string: url)!)
  }

  @Test("session(for:) creates a new session for unknown profile")
  func createsNewSession() throws {
    let manager = try makeManager()
    let profile = makeProfile()

    let session = manager.session(for: profile)

    #expect(session.profile.id == profile.id)
    #expect(manager.sessions.count == 1)
  }

  @Test("session(for:) returns existing session for known profile")
  func reusesExistingSession() throws {
    let manager = try makeManager()
    let profile = makeProfile()

    let session1 = manager.session(for: profile)
    let session2 = manager.session(for: profile)

    #expect(session1 === session2)
    #expect(manager.sessions.count == 1)
  }

  @Test("removeSession removes the session")
  func removesSession() throws {
    let manager = try makeManager()
    let profile = makeProfile()

    _ = manager.session(for: profile)
    #expect(manager.sessions.count == 1)

    manager.removeSession(for: profile.id)
    #expect(manager.sessions.isEmpty)
  }

  @Test("rebuildSession replaces existing session with new instance")
  func rebuildsSession() throws {
    let manager = try makeManager()
    let profile = makeProfile()

    let original = manager.session(for: profile)
    manager.rebuildSession(for: profile)
    let rebuilt = manager.sessions[profile.id]

    #expect(rebuilt !== original)
    #expect(rebuilt?.profile.id == profile.id)
    #expect(manager.sessions.count == 1)
  }

  @Test("multiple profiles get independent sessions")
  func independentSessions() throws {
    let manager = try makeManager()
    let profile1 = makeProfile(label: "One", url: "https://one.com/api/")
    let profile2 = makeProfile(label: "Two", url: "https://two.com/api/")

    let session1 = manager.session(for: profile1)
    let session2 = manager.session(for: profile2)

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
