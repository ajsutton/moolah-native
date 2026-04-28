import Foundation
import Testing

@testable import Moolah

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
