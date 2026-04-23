import Foundation
import SwiftData
import Testing

@testable import Moolah

@Suite("ProfileStore")
@MainActor
struct ProfileStoreTestsMore {
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

  @Test("validateAndUpdateProfile updates profile when validation succeeds")
  func validateAndUpdateSuccess() async {
    let validator = InMemoryServerValidator()
    let store = ProfileStore(defaults: makeDefaults(), validator: validator)
    var profile = makeProfile(label: "Old")
    store.addProfile(profile)

    profile.label = "New"
    let result = await store.validateAndUpdateProfile(profile)

    #expect(result == true)
    #expect(store.profiles[0].label == "New")
    #expect(store.validationError == nil)
  }

  @Test("validateAndUpdateProfile does not update profile when validation fails")
  func validateAndUpdateFailure() async {
    let validator = InMemoryServerValidator()
    let store = ProfileStore(defaults: makeDefaults(), validator: validator)
    var profile = makeProfile(label: "Old")
    store.addProfile(profile)

    validator.shouldSucceed = false
    profile.label = "New"
    let result = await store.validateAndUpdateProfile(profile)

    #expect(result == false)
    #expect(store.profiles[0].label == "Old")
    #expect(store.validationError != nil)
  }

  // MARK: - Validation: nil validator

  @Test("validateAndAddProfile skips validation when no validator is set")
  func validateAndAddWithoutValidator() async {
    let store = ProfileStore(defaults: makeDefaults())
    let profile = makeProfile()

    let result = await store.validateAndAddProfile(profile)

    #expect(result == true)
    #expect(store.profiles.count == 1)
  }

  // MARK: - Cloud profile initial load

  @Test("initial load preserves activeProfileID when cloud profiles are empty")
  func initialLoadPreservesActiveProfileID() throws {
    let defaults = makeDefaults()
    let cloudProfileID = UUID()

    // Simulate a previous session that saved a cloud profile as active
    defaults.set(cloudProfileID.uuidString, forKey: "com.moolah.activeProfileID")

    // Create store with empty ProfileContainerManager (no ProfileRecords stored yet)
    let containerManager = try ProfileContainerManager.forTesting()
    let store = ProfileStore(defaults: defaults, containerManager: containerManager)

    // The active profile ID should be preserved even though no cloud profiles loaded
    #expect(store.activeProfileID == cloudProfileID)
    #expect(store.cloudProfiles.isEmpty)
  }

  @Test("remote change resets activeProfileID when cloud profile was deleted")
  func remoteChangeResetsActiveProfileID() throws {
    let defaults = makeDefaults()
    let containerManager = try ProfileContainerManager.forTesting()
    let store = ProfileStore(defaults: defaults, containerManager: containerManager)

    // Add a cloud profile and a remote fallback
    let remoteProfile = makeProfile(label: "Remote")
    store.addProfile(remoteProfile)

    let cloudProfile = Profile(
      label: "Cloud",
      backendType: .cloudKit,
      currencyCode: "AUD",
      financialYearStartMonth: 7
    )
    store.addProfile(cloudProfile)
    store.setActiveProfile(cloudProfile.id)
    #expect(store.activeProfileID == cloudProfile.id)

    // Delete the cloud profile record from SwiftData directly (simulates remote deletion)
    let context = ModelContext(containerManager.indexContainer)
    let profileId = cloudProfile.id
    let descriptor = FetchDescriptor<ProfileRecord>(
      predicate: #Predicate { $0.id == profileId }
    )
    if let record = try context.fetch(descriptor).first {
      context.delete(record)
      try context.save()
    }

    // Simulate a remote change reload — should reset active to fallback
    store.loadCloudProfiles(isInitialLoad: false)

    #expect(store.activeProfileID == remoteProfile.id)
  }

  // MARK: - Remote deletion cleanup

  @Test("loadCloudProfiles calls onProfileRemoved for remotely-deleted profiles")
  func remoteDeleteCallsOnProfileRemoved() throws {
    let defaults = makeDefaults()
    let containerManager = try ProfileContainerManager.forTesting()
    let store = ProfileStore(defaults: defaults, containerManager: containerManager)

    let cloudProfile = Profile(
      label: "Cloud",
      backendType: .cloudKit,
      currencyCode: "AUD",
      financialYearStartMonth: 7
    )
    store.addProfile(cloudProfile)
    store.setActiveProfile(cloudProfile.id)

    // Track which profiles the callback reports as removed
    var removedIDs: [UUID] = []
    store.onProfileRemoved = { id in removedIDs.append(id) }

    // Delete the cloud profile record from SwiftData (simulates remote deletion)
    let context = ModelContext(containerManager.indexContainer)
    let profileId = cloudProfile.id
    let descriptor = FetchDescriptor<ProfileRecord>(
      predicate: #Predicate { $0.id == profileId }
    )
    if let record = try context.fetch(descriptor).first {
      context.delete(record)
      try context.save()
    }

    store.loadCloudProfiles(isInitialLoad: false)

    #expect(removedIDs == [cloudProfile.id])
  }

  @Test("loadCloudProfiles cleans up local store for remotely-deleted profiles")
  func remoteDeleteCleansUpLocalStore() throws {
    let defaults = makeDefaults()
    let containerManager = try ProfileContainerManager.forTesting()
    let store = ProfileStore(defaults: defaults, containerManager: containerManager)

    let cloudProfile = Profile(
      label: "Cloud",
      backendType: .cloudKit,
      currencyCode: "AUD",
      financialYearStartMonth: 7
    )
    store.addProfile(cloudProfile)

    // Force creation of the per-profile container (simulates normal app usage)
    _ = try containerManager.container(for: cloudProfile.id)

    // Delete the cloud profile record from SwiftData (simulates remote deletion)
    let context = ModelContext(containerManager.indexContainer)
    let profileId = cloudProfile.id
    let descriptor = FetchDescriptor<ProfileRecord>(
      predicate: #Predicate { $0.id == profileId }
    )
    if let record = try context.fetch(descriptor).first {
      context.delete(record)
      try context.save()
    }

    store.loadCloudProfiles(isInitialLoad: false)

    // The container cache should have been evicted
    // Creating a new container should give a different instance
    #expect(!containerManager.hasContainer(for: cloudProfile.id))
  }

  // MARK: - Sync change tracking

  @Test("addProfile calls onProfileChanged for CloudKit profiles")
  func addCloudProfileCallsOnProfileChanged() throws {
    let defaults = makeDefaults()
    let containerManager = try ProfileContainerManager.forTesting()
    let store = ProfileStore(defaults: defaults, containerManager: containerManager)

    var changedIDs: [UUID] = []
    store.onProfileChanged = { id in changedIDs.append(id) }

    let profile = Profile(
      label: "Cloud",
      backendType: .cloudKit,
      currencyCode: "AUD",
      financialYearStartMonth: 7
    )
    store.addProfile(profile)

    #expect(changedIDs == [profile.id])
  }
}
