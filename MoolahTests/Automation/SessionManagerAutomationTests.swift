import Foundation
import Testing

@testable import Moolah

@Suite("SessionManager Automation Extensions")
@MainActor
struct SessionManagerAutomationTests {
  private func makeManager() throws -> SessionManager {
    let containerManager = try ProfileContainerManager.forTesting()
    return SessionManager(containerManager: containerManager)
  }

  private func makeProfile(label: String = "Personal") -> Profile {
    Profile(
      label: label,
      currencyCode: "AUD",
      financialYearStartMonth: 7
    )
  }

  @Test("session(named:) finds session by exact profile name")
  func findSessionByProfileName() throws {
    let manager = try makeManager()
    let profile = makeProfile(label: "Personal")
    _ = manager.session(for: profile)

    let found = manager.session(named: "Personal")

    #expect(found != nil)
    #expect(found?.profile.id == profile.id)
  }

  @Test("session(named:) finds session case-insensitively")
  func findSessionByProfileNameCaseInsensitive() throws {
    let manager = try makeManager()
    let profile = makeProfile(label: "Personal")
    _ = manager.session(for: profile)

    let found = manager.session(named: "personal")

    #expect(found != nil)
    #expect(found?.profile.id == profile.id)
  }

  @Test("session(named:) returns nil when no session matches")
  func findSessionByProfileNameReturnsNilWhenNotFound() throws {
    let manager = try makeManager()
    let profile = makeProfile(label: "Personal")
    _ = manager.session(for: profile)

    let found = manager.session(named: "Business")

    #expect(found == nil)
  }

  @Test("session(forID:) finds session by UUID")
  func findSessionByUUID() throws {
    let manager = try makeManager()
    let profile = makeProfile()
    _ = manager.session(for: profile)

    let found = manager.session(forID: profile.id)

    #expect(found != nil)
    #expect(found?.profile.id == profile.id)
  }

  @Test("session(forID:) returns nil for unknown UUID")
  func findSessionByUUIDReturnsNilWhenNotFound() throws {
    let manager = try makeManager()

    let found = manager.session(forID: UUID())

    #expect(found == nil)
  }

  @Test("openProfiles returns all sessions")
  func openProfilesReturnsAllSessions() throws {
    let manager = try makeManager()
    let profile1 = makeProfile(label: "Personal")
    let profile2 = makeProfile(label: "Business")
    _ = manager.session(for: profile1)
    _ = manager.session(for: profile2)

    let open = manager.openProfiles

    #expect(open.count == 2)
    let ids = Set(open.map(\.profile.id))
    #expect(ids.contains(profile1.id))
    #expect(ids.contains(profile2.id))
  }
}
