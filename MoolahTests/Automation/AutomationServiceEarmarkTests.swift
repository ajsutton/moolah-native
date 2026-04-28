import Foundation
import Testing

@testable import Moolah

@Suite("AutomationService Earmark Operations")
@MainActor
struct AutomationServiceEarmarkTests {
  private func makeServiceWithSession() async throws -> (AutomationService, ProfileSession) {
    let containerManager = try ProfileContainerManager.forTesting()
    let sessionManager = SessionManager(containerManager: containerManager)
    let profile = Profile(
      label: "Test",
      currencyCode: "AUD",
      financialYearStartMonth: 7
    )
    let session = sessionManager.session(for: profile)
    await session.earmarkStore.load()
    let service = AutomationService(sessionManager: sessionManager)
    return (service, session)
  }

  @Test("createEarmark creates and lists earmarks")
  func createAndListEarmarks() async throws {
    let (service, _) = try await makeServiceWithSession()

    let earmark = try await service.createEarmark(
      profileIdentifier: "Test",
      name: "Holiday Fund",
      targetAmount: 5000
    )

    #expect(earmark.name == "Holiday Fund")
    #expect(earmark.savingsGoal?.quantity == 5000)

    let earmarks = try service.listEarmarks(profileIdentifier: "Test")
    #expect(earmarks.count == 1)
    #expect(earmarks.first?.name == "Holiday Fund")
  }

  @Test("resolveEarmark finds earmark case-insensitively")
  func resolveEarmarkCaseInsensitive() async throws {
    let (service, _) = try await makeServiceWithSession()

    _ = try await service.createEarmark(
      profileIdentifier: "Test",
      name: "Emergency Fund"
    )

    let resolved = try service.resolveEarmark(named: "emergency fund", profileIdentifier: "Test")
    #expect(resolved.name == "Emergency Fund")
  }

  @Test("resolveEarmark throws when not found")
  func resolveEarmarkNotFound() async throws {
    let (service, _) = try await makeServiceWithSession()

    #expect(throws: AutomationError.self) {
      try service.resolveEarmark(named: "NonExistent", profileIdentifier: "Test")
    }
  }
}
