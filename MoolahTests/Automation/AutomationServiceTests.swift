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
      backendType: .cloudKit,
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

@Suite("AutomationService Profile Operations")
@MainActor
struct AutomationServiceProfileTests {
  private func makeService() throws -> (AutomationService, SessionManager) {
    let containerManager = try ProfileContainerManager.forTesting()
    let sessionManager = SessionManager(containerManager: containerManager)
    let service = AutomationService(sessionManager: sessionManager)
    return (service, sessionManager)
  }

  private func makeProfile(label: String = "Personal") -> Profile {
    Profile(
      label: label,
      backendType: .cloudKit,
      currencyCode: "AUD",
      financialYearStartMonth: 7
    )
  }

  @Test("resolveSession finds session by name")
  func resolveByName() throws {
    let (service, sessionManager) = try makeService()
    let profile = makeProfile(label: "Personal")
    _ = sessionManager.session(for: profile)

    let session = try service.resolveSession(for: "Personal")

    #expect(session.profile.id == profile.id)
  }

  @Test("resolveSession finds session by UUID string")
  func resolveByUUID() throws {
    let (service, sessionManager) = try makeService()
    let profile = makeProfile(label: "Personal")
    _ = sessionManager.session(for: profile)

    let session = try service.resolveSession(for: profile.id.uuidString)

    #expect(session.profile.id == profile.id)
  }

  @Test("resolveSession throws when profile not found")
  func throwsWhenNotFound() throws {
    let (service, _) = try makeService()

    #expect(throws: AutomationError.self) {
      try service.resolveSession(for: "NonExistent")
    }
  }

  @Test("listOpenProfiles returns all open profiles")
  func listOpenProfiles() throws {
    let (service, sessionManager) = try makeService()
    let profile1 = makeProfile(label: "Personal")
    let profile2 = makeProfile(label: "Business")
    _ = sessionManager.session(for: profile1)
    _ = sessionManager.session(for: profile2)

    let profiles = service.listOpenProfiles()

    #expect(profiles.count == 2)
    let labels = Set(profiles.map(\.label))
    #expect(labels.contains("Personal"))
    #expect(labels.contains("Business"))
  }
}
