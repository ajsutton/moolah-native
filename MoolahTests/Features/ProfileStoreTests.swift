import Foundation
import SwiftData
import Testing

@testable import Moolah

@Suite("ProfileStore")
@MainActor
struct ProfileStoreTests {
  private func makeDefaults() -> UserDefaults {
    let suiteName = "com.moolah.test.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return defaults
  }

  private func makeProfile(label: String = "Test") -> Profile {
    Profile(label: label)
  }

  // MARK: - Add

  @Test("addProfile appends and sets first profile as active")
  func addFirstProfile() throws {
    let manager = try ProfileContainerManager.forTesting()
    let store = ProfileStore(defaults: makeDefaults(), containerManager: manager)
    let profile = makeProfile()

    store.addProfile(profile)

    #expect(store.profiles.count == 1)
    #expect(store.activeProfileID == profile.id)
    #expect(store.activeProfile == profile)
    #expect(store.hasProfiles == true)
  }

  @Test("addProfile does not change active when adding second profile")
  func addSecondProfile() throws {
    let manager = try ProfileContainerManager.forTesting()
    let store = ProfileStore(defaults: makeDefaults(), containerManager: manager)
    let first = makeProfile(label: "First")
    let second = makeProfile(label: "Second")

    store.addProfile(first)
    store.addProfile(second)

    #expect(store.profiles.count == 2)
    #expect(store.activeProfileID == first.id)
  }

  // MARK: - Remove

  @Test("removeProfile removes and switches active to next profile")
  func removeActiveProfile() throws {
    let manager = try ProfileContainerManager.forTesting()
    let store = ProfileStore(defaults: makeDefaults(), containerManager: manager)
    let first = makeProfile(label: "First")
    let second = makeProfile(label: "Second")

    store.addProfile(first)
    store.addProfile(second)
    store.removeProfile(first.id)

    #expect(store.profiles.count == 1)
    #expect(store.activeProfileID == second.id)
  }

  @Test("removeProfile clears active when last profile removed")
  func removeLastProfile() throws {
    let manager = try ProfileContainerManager.forTesting()
    let store = ProfileStore(defaults: makeDefaults(), containerManager: manager)
    let profile = makeProfile()

    store.addProfile(profile)
    store.removeProfile(profile.id)

    #expect(store.profiles.isEmpty)
    #expect(store.activeProfileID == nil)
    #expect(store.hasProfiles == false)
  }

  // MARK: - Switch

  @Test("setActiveProfile switches to specified profile")
  func switchProfile() throws {
    let manager = try ProfileContainerManager.forTesting()
    let store = ProfileStore(defaults: makeDefaults(), containerManager: manager)
    let first = makeProfile(label: "First")
    let second = makeProfile(label: "Second")

    store.addProfile(first)
    store.addProfile(second)
    store.setActiveProfile(second.id)

    #expect(store.activeProfileID == second.id)
  }

  @Test("setActiveProfile ignores unknown profile ID")
  func switchToUnknownProfile() throws {
    let manager = try ProfileContainerManager.forTesting()
    let store = ProfileStore(defaults: makeDefaults(), containerManager: manager)
    let profile = makeProfile()

    store.addProfile(profile)
    store.setActiveProfile(UUID())

    #expect(store.activeProfileID == profile.id)
  }

  // MARK: - Update

  @Test("updateProfile modifies the profile in place")
  func updateProfile() throws {
    let manager = try ProfileContainerManager.forTesting()
    let store = ProfileStore(defaults: makeDefaults(), containerManager: manager)
    var profile = makeProfile(label: "Old")
    store.addProfile(profile)

    profile.label = "New"
    store.updateProfile(profile)

    #expect(store.profiles[0].label == "New")
  }

  @Test("updateProfile ignores unknown profile")
  func updateUnknownProfile() throws {
    let manager = try ProfileContainerManager.forTesting()
    let store = ProfileStore(defaults: makeDefaults(), containerManager: manager)
    let unknown = makeProfile(label: "Ghost")

    store.updateProfile(unknown)

    #expect(store.profiles.isEmpty)
  }

  // MARK: - Persistence

  @Test("active profile ID persists across instances")
  func activeProfilePersists() throws {
    let defaults = makeDefaults()
    let manager = try ProfileContainerManager.forTesting()
    let first = makeProfile(label: "First")
    let second = makeProfile(label: "Second")

    let store1 = ProfileStore(defaults: defaults, containerManager: manager)
    store1.addProfile(first)
    store1.addProfile(second)
    store1.setActiveProfile(second.id)

    let store2 = ProfileStore(defaults: defaults, containerManager: manager)
    #expect(store2.activeProfileID == second.id)
  }

  // MARK: - Empty state

  @Test("fresh store with no data has no profiles")
  func emptyState() throws {
    let manager = try ProfileContainerManager.forTesting()
    let store = ProfileStore(defaults: makeDefaults(), containerManager: manager)

    #expect(store.profiles.isEmpty)
    #expect(store.activeProfileID == nil)
    #expect(store.activeProfile == nil)
    #expect(store.hasProfiles == false)
  }

  // MARK: - Validation: Add

  @Test("validateAndAddProfile adds profile when iCloud available")
  func validateAndAddSuccess() async throws {
    let manager = try ProfileContainerManager.forTesting()
    let store = ProfileStore(defaults: makeDefaults(), containerManager: manager)
    let profile = makeProfile()

    // In tests without CloudKit entitlements, validateiCloudAvailability returns true
    // (the guard skips the account status check)
    let result = await store.validateAndAddProfile(profile)

    #expect(result == true)
    #expect(store.profiles.count == 1)
    #expect(store.profiles[0] == profile)
    #expect(store.validationError == nil)
  }

  // MARK: - Validation: Update
}
