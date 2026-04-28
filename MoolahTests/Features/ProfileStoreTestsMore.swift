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

  private func makeProfile(label: String = "Test") -> Profile {
    Profile(label: label)
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
    #expect(store.profiles.isEmpty)
  }

  @Test("remote change resets activeProfileID when cloud profile was deleted")
  func remoteChangeResetsActiveProfileID() throws {
    let defaults = makeDefaults()
    let containerManager = try ProfileContainerManager.forTesting()
    let store = ProfileStore(defaults: defaults, containerManager: containerManager)

    // Add two cloud profiles
    let firstProfile = makeProfile(label: "First")
    let secondProfile = makeProfile(label: "Second")
    store.addProfile(firstProfile)
    store.addProfile(secondProfile)
    store.setActiveProfile(secondProfile.id)
    #expect(store.activeProfileID == secondProfile.id)

    // Delete the second profile record from SwiftData directly (simulates remote deletion)
    let context = ModelContext(containerManager.indexContainer)
    let profileId = secondProfile.id
    let descriptor = FetchDescriptor<ProfileRecord>(
      predicate: #Predicate { $0.id == profileId }
    )
    if let record = try context.fetch(descriptor).first {
      context.delete(record)
      try context.save()
    }

    // Simulate a remote change reload — should reset active to remaining profile
    store.loadCloudProfiles(isInitialLoad: false)

    #expect(store.activeProfileID == firstProfile.id)
  }

  // MARK: - Remote deletion cleanup

  @Test("loadCloudProfiles calls onProfileRemoved for remotely-deleted profiles")
  func remoteDeleteCallsOnProfileRemoved() throws {
    let defaults = makeDefaults()
    let containerManager = try ProfileContainerManager.forTesting()
    let store = ProfileStore(defaults: defaults, containerManager: containerManager)

    let cloudProfile = makeProfile(label: "Cloud")
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

    let cloudProfile = makeProfile(label: "Cloud")
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

    let profile = makeProfile(label: "Cloud")
    store.addProfile(profile)

    #expect(changedIDs == [profile.id])
  }
}
