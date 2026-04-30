import Foundation
import Testing

@testable import Moolah

@Suite("ProfileStore — auto-activate guard")
@MainActor
struct ProfileStoreAutoActivateGuardTests {
  private func makeDefaults() throws -> UserDefaults {
    let suiteName = "com.moolah.test.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)
    return defaults
  }

  private func seedCloudProfile(
    _ container: ProfileContainerManager
  ) async throws -> Profile {
    let profile = Profile(
      id: UUID(),
      label: "Household",
      currencyCode: "AUD",
      financialYearStartMonth: 7
    )
    try await container.profileIndexRepository.upsert(profile)
    return profile
  }

  /// Drains every fire-and-forget Task tracked by the store.
  private func drainPendingMutations(_ store: ProfileStore) async {
    while let task = store.pendingMutationTasks.first {
      await task.value
      await Task.yield()
    }
  }

  @Test("loadCloudProfiles auto-activates when welcomePhase == .landing")
  func autoActivatesWhenLanding() async throws {
    let manager = try ProfileContainerManager.forTesting()
    let store = ProfileStore(
      defaults: try makeDefaults(),
      containerManager: manager
    )
    await drainPendingMutations(store)
    let profile = try await seedCloudProfile(manager)
    store.welcomePhase = .landing

    store.loadCloudProfiles()
    await drainPendingMutations(store)

    #expect(store.activeProfileID == profile.id)
  }

  @Test("loadCloudProfiles does NOT auto-activate when welcomePhase == .creating")
  func doesNotAutoActivateWhenCreating() async throws {
    let manager = try ProfileContainerManager.forTesting()
    let store = ProfileStore(
      defaults: try makeDefaults(),
      containerManager: manager
    )
    await drainPendingMutations(store)
    _ = try await seedCloudProfile(manager)
    store.welcomePhase = .creating

    store.loadCloudProfiles()
    await drainPendingMutations(store)

    #expect(store.activeProfileID == nil)
    #expect(store.profiles.count == 1)
  }

  @Test("loadCloudProfiles auto-activates when welcomePhase is nil")
  func autoActivatesWhenPhaseNil() async throws {
    let manager = try ProfileContainerManager.forTesting()
    let store = ProfileStore(
      defaults: try makeDefaults(),
      containerManager: manager
    )
    await drainPendingMutations(store)
    let profile = try await seedCloudProfile(manager)
    store.welcomePhase = nil

    store.loadCloudProfiles()
    await drainPendingMutations(store)

    #expect(store.activeProfileID == profile.id)
  }
}
