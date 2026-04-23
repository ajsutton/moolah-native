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

  private func makeProfile(label: String = "Test", url: String = "https://moolah.rocks/api/")
    -> Profile
  {
    Profile(label: label, serverURL: URL(string: url)!)
  }

  // MARK: - Add

  @Test("addProfile appends and sets first profile as active")
  func addFirstProfile() {
    let store = ProfileStore(defaults: makeDefaults())
    let profile = makeProfile()

    store.addProfile(profile)

    #expect(store.profiles.count == 1)
    #expect(store.activeProfileID == profile.id)
    #expect(store.activeProfile == profile)
    #expect(store.hasProfiles == true)
  }

  @Test("addProfile does not change active when adding second profile")
  func addSecondProfile() {
    let store = ProfileStore(defaults: makeDefaults())
    let first = makeProfile(label: "First")
    let second = makeProfile(label: "Second")

    store.addProfile(first)
    store.addProfile(second)

    #expect(store.profiles.count == 2)
    #expect(store.activeProfileID == first.id)
  }

  // MARK: - Remove

  @Test("removeProfile removes and switches active to next profile")
  func removeActiveProfile() {
    let store = ProfileStore(defaults: makeDefaults())
    let first = makeProfile(label: "First")
    let second = makeProfile(label: "Second")

    store.addProfile(first)
    store.addProfile(second)
    store.removeProfile(first.id)

    #expect(store.profiles.count == 1)
    #expect(store.activeProfileID == second.id)
  }

  @Test("removeProfile clears keychain cookies for that profile")
  func removeProfileClearsKeychain() throws {
    let store = ProfileStore(defaults: makeDefaults())
    let profile = makeProfile()
    store.addProfile(profile)

    // Save some cookies to the profile's keychain entry
    let keychain = CookieKeychain(account: profile.id.uuidString)
    let cookie = HTTPCookie(properties: [
      .name: "session",
      .value: "abc123",
      .domain: "moolah.rocks",
      .path: "/",
    ])!
    try keychain.save(cookies: [cookie])

    // Verify cookies are stored
    let before = try keychain.restore()
    #expect(before != nil)

    // Remove the profile — should clear keychain
    store.removeProfile(profile.id)

    // Verify cookies were cleared
    let after = try keychain.restore()
    #expect(after == nil)
  }

  @Test("removeProfile clears active when last profile removed")
  func removeLastProfile() {
    let store = ProfileStore(defaults: makeDefaults())
    let profile = makeProfile()

    store.addProfile(profile)
    store.removeProfile(profile.id)

    #expect(store.profiles.isEmpty)
    #expect(store.activeProfileID == nil)
    #expect(store.hasProfiles == false)
  }

  // MARK: - Switch

  @Test("setActiveProfile switches to specified profile")
  func switchProfile() {
    let store = ProfileStore(defaults: makeDefaults())
    let first = makeProfile(label: "First")
    let second = makeProfile(label: "Second")

    store.addProfile(first)
    store.addProfile(second)
    store.setActiveProfile(second.id)

    #expect(store.activeProfileID == second.id)
  }

  @Test("setActiveProfile ignores unknown profile ID")
  func switchToUnknownProfile() {
    let store = ProfileStore(defaults: makeDefaults())
    let profile = makeProfile()

    store.addProfile(profile)
    store.setActiveProfile(UUID())

    #expect(store.activeProfileID == profile.id)
  }

  // MARK: - Update

  @Test("updateProfile modifies the profile in place")
  func updateProfile() {
    let store = ProfileStore(defaults: makeDefaults())
    var profile = makeProfile(label: "Old")
    store.addProfile(profile)

    profile.label = "New"
    store.updateProfile(profile)

    #expect(store.profiles[0].label == "New")
  }

  @Test("updateProfile ignores unknown profile")
  func updateUnknownProfile() {
    let store = ProfileStore(defaults: makeDefaults())
    let unknown = makeProfile(label: "Ghost")

    store.updateProfile(unknown)

    #expect(store.profiles.isEmpty)
  }

  // MARK: - Persistence

  @Test("profiles persist across instances via UserDefaults")
  func persistenceRoundTrip() {
    let defaults = makeDefaults()
    let profile = makeProfile(label: "Persisted")

    let store1 = ProfileStore(defaults: defaults)
    store1.addProfile(profile)

    let store2 = ProfileStore(defaults: defaults)

    #expect(store2.profiles.count == 1)
    #expect(store2.profiles[0] == profile)
    #expect(store2.activeProfileID == profile.id)
  }

  @Test("active profile ID persists across instances")
  func activeProfilePersists() {
    let defaults = makeDefaults()
    let first = makeProfile(label: "First")
    let second = makeProfile(label: "Second")

    let store1 = ProfileStore(defaults: defaults)
    store1.addProfile(first)
    store1.addProfile(second)
    store1.setActiveProfile(second.id)

    let store2 = ProfileStore(defaults: defaults)
    #expect(store2.activeProfileID == second.id)
  }

  // MARK: - Empty state

  @Test("fresh store with no data has no profiles")
  func emptyState() {
    let store = ProfileStore(defaults: makeDefaults())

    #expect(store.profiles.isEmpty)
    #expect(store.activeProfileID == nil)
    #expect(store.activeProfile == nil)
    #expect(store.hasProfiles == false)
  }

  // MARK: - Validation: Add

  @Test("validateAndAddProfile adds profile when validation succeeds")
  func validateAndAddSuccess() async {
    let validator = InMemoryServerValidator()
    let store = ProfileStore(defaults: makeDefaults(), validator: validator)
    let profile = makeProfile()

    let result = await store.validateAndAddProfile(profile)

    #expect(result == true)
    #expect(store.profiles.count == 1)
    #expect(store.profiles[0] == profile)
    #expect(store.validationError == nil)
  }

  @Test("validateAndAddProfile does not add profile when validation fails")
  func validateAndAddFailure() async {
    let validator = InMemoryServerValidator()
    validator.shouldSucceed = false
    validator.errorMessage = "Could not connect to server"
    let store = ProfileStore(defaults: makeDefaults(), validator: validator)
    let profile = makeProfile()

    let result = await store.validateAndAddProfile(profile)

    #expect(result == false)
    #expect(store.profiles.isEmpty)
    #expect(store.validationError == "Could not connect to server")
  }

  @Test("validateAndAddProfile clears previous error on success")
  func validateAndAddClearsPreviousError() async {
    let validator = InMemoryServerValidator()
    validator.shouldSucceed = false
    let store = ProfileStore(defaults: makeDefaults(), validator: validator)
    let profile = makeProfile()

    _ = await store.validateAndAddProfile(profile)
    #expect(store.validationError != nil)

    validator.shouldSucceed = true
    let result = await store.validateAndAddProfile(profile)

    #expect(result == true)
    #expect(store.validationError == nil)
  }

  // MARK: - Validation: Update
}
