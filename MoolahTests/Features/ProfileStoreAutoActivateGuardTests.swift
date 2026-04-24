import Foundation
import SwiftData
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
  ) throws -> Profile {
    let profile = Profile(
      id: UUID(),
      label: "Household",
      backendType: .cloudKit,
      currencyCode: "AUD",
      financialYearStartMonth: 7
    )
    let context = ModelContext(container.indexContainer)
    context.insert(ProfileRecord.from(profile: profile))
    try context.save()
    return profile
  }

  @Test("loadCloudProfiles auto-activates when welcomePhase == .landing")
  func autoActivatesWhenLanding() throws {
    let manager = try ProfileContainerManager.forTesting()
    let store = ProfileStore(
      defaults: try makeDefaults(),
      containerManager: manager
    )
    let profile = try seedCloudProfile(manager)
    store.welcomePhase = .landing

    store.loadCloudProfiles()

    #expect(store.activeProfileID == profile.id)
  }

  @Test("loadCloudProfiles does NOT auto-activate when welcomePhase == .creating")
  func doesNotAutoActivateWhenCreating() throws {
    let manager = try ProfileContainerManager.forTesting()
    let store = ProfileStore(
      defaults: try makeDefaults(),
      containerManager: manager
    )
    _ = try seedCloudProfile(manager)
    store.welcomePhase = .creating

    store.loadCloudProfiles()

    #expect(store.activeProfileID == nil)
    #expect(store.cloudProfiles.count == 1)
  }

  @Test("loadCloudProfiles auto-activates when welcomePhase is nil")
  func autoActivatesWhenPhaseNil() throws {
    let manager = try ProfileContainerManager.forTesting()
    let store = ProfileStore(
      defaults: try makeDefaults(),
      containerManager: manager
    )
    let profile = try seedCloudProfile(manager)
    store.welcomePhase = nil

    store.loadCloudProfiles()

    #expect(store.activeProfileID == profile.id)
  }
}
