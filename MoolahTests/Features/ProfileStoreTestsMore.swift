import Foundation
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

  // Regression: a fresh-install / wiped Mac has no saved active profile
  // but still needs the post-migration retry. Without it the store stays
  // empty for the rest of the session, no `ProfileSession` ever gets
  // constructed for incoming sync events, and CKSyncEngine's first
  // fetch traps in `SyncCoordinator.handlerForProfileZone`.
  @Test("initial load schedules a retry when cloud store is empty even with no active profile")
  func initialLoadSchedulesRetryWhenNoActiveProfile() throws {
    let defaults = makeDefaults()
    // Intentionally do NOT seed `com.moolah.activeProfileID`.

    let containerManager = try ProfileContainerManager.forTesting()
    let store = ProfileStore(defaults: defaults, containerManager: containerManager)

    #expect(store.activeProfileID == nil)
    #expect(store.profiles.isEmpty)
    #expect(store.isCloudLoadPending == true)
  }

  @Test("remote change resets activeProfileID when cloud profile was deleted")
  func remoteChangeResetsActiveProfileID() async throws {
    let defaults = makeDefaults()
    let containerManager = try ProfileContainerManager.forTesting()
    let store = ProfileStore(defaults: defaults, containerManager: containerManager)
    await drainPendingMutations(store)

    // Add two cloud profiles
    let firstProfile = makeProfile(label: "First")
    let secondProfile = makeProfile(label: "Second")
    store.addProfile(firstProfile)
    store.addProfile(secondProfile)
    await drainPendingMutations(store)
    store.setActiveProfile(secondProfile.id)
    #expect(store.activeProfileID == secondProfile.id)

    // Delete the second profile row from GRDB directly (simulates remote deletion)
    _ = try await containerManager.profileIndexRepository.delete(id: secondProfile.id)

    // Simulate a remote change reload — should reset active to remaining profile
    store.loadCloudProfiles(isInitialLoad: false)
    await drainPendingMutations(store)

    #expect(store.activeProfileID == firstProfile.id)
  }

  // MARK: - Remote deletion cleanup

  @Test("loadCloudProfiles calls onProfileRemoved for remotely-deleted profiles")
  func remoteDeleteCallsOnProfileRemoved() async throws {
    let defaults = makeDefaults()
    let containerManager = try ProfileContainerManager.forTesting()
    let store = ProfileStore(defaults: defaults, containerManager: containerManager)
    await drainPendingMutations(store)

    let cloudProfile = makeProfile(label: "Cloud")
    store.addProfile(cloudProfile)
    await drainPendingMutations(store)
    store.setActiveProfile(cloudProfile.id)

    // Track which profiles the callback reports as removed
    var removedIDs: [UUID] = []
    store.onProfileRemoved = { id in removedIDs.append(id) }

    // Delete the cloud profile from GRDB (simulates remote deletion)
    _ = try await containerManager.profileIndexRepository.delete(id: cloudProfile.id)

    store.loadCloudProfiles(isInitialLoad: false)
    await drainPendingMutations(store)

    #expect(removedIDs == [cloudProfile.id])
  }

  @Test("loadCloudProfiles cleans up local store for remotely-deleted profiles")
  func remoteDeleteCleansUpLocalStore() async throws {
    let defaults = makeDefaults()
    let containerManager = try ProfileContainerManager.forTesting()
    let store = ProfileStore(defaults: defaults, containerManager: containerManager)
    await drainPendingMutations(store)

    let cloudProfile = makeProfile(label: "Cloud")
    store.addProfile(cloudProfile)
    await drainPendingMutations(store)

    // Force creation of the per-profile container (simulates normal app usage)
    _ = try containerManager.container(for: cloudProfile.id)

    // Delete the cloud profile from GRDB (simulates remote deletion)
    _ = try await containerManager.profileIndexRepository.delete(id: cloudProfile.id)

    store.loadCloudProfiles(isInitialLoad: false)
    await drainPendingMutations(store)

    // The container cache should have been evicted
    // Creating a new container should give a different instance
    #expect(!containerManager.hasContainer(for: cloudProfile.id))
  }

  // MARK: - Sync change tracking

  @Test("addProfile calls onProfileChanged for CloudKit profiles")
  func addCloudProfileCallsOnProfileChanged() async throws {
    let defaults = makeDefaults()
    let containerManager = try ProfileContainerManager.forTesting()
    let store = ProfileStore(defaults: defaults, containerManager: containerManager)
    await drainPendingMutations(store)

    var changedIDs: [UUID] = []
    store.onProfileChanged = { id in changedIDs.append(id) }

    let profile = makeProfile(label: "Cloud")
    store.addProfile(profile)
    await drainPendingMutations(store)

    #expect(changedIDs == [profile.id])
  }
}
