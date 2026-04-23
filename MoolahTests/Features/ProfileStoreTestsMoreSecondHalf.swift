import Foundation
import SwiftData
import Testing

@testable import Moolah

@Suite("ProfileStore")
@MainActor
struct ProfileStoreTestsMoreSecondHalf {
  private func makeDefaults() -> UserDefaults {
    let suiteName = "com.moolah.test.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return defaults
  }

  private func makeProfile(label: String = "Test", url: String = "https://moolah.rocks/api/")
    -> Profile
  {
    Profile(label: label, serverURL: makeURL(url))
  }

  @Test("addProfile does not call onProfileChanged for remote profiles")
  func addRemoteProfileDoesNotCallOnProfileChanged() throws {
    let defaults = makeDefaults()
    let store = ProfileStore(defaults: defaults)

    var changedIDs: [UUID] = []
    store.onProfileChanged = { id in changedIDs.append(id) }

    store.addProfile(makeProfile())

    #expect(changedIDs.isEmpty)
  }

  @Test("updateProfile calls onProfileChanged for CloudKit profiles")
  func updateCloudProfileCallsOnProfileChanged() throws {
    let defaults = makeDefaults()
    let containerManager = try ProfileContainerManager.forTesting()
    let store = ProfileStore(defaults: defaults, containerManager: containerManager)

    var profile = Profile(
      label: "Cloud",
      backendType: .cloudKit,
      currencyCode: "AUD",
      financialYearStartMonth: 7
    )
    store.addProfile(profile)

    var changedIDs: [UUID] = []
    store.onProfileChanged = { id in changedIDs.append(id) }

    profile.label = "Updated"
    store.updateProfile(profile)

    #expect(changedIDs == [profile.id])
  }

  @Test("removeProfile calls onProfileDeleted for CloudKit profiles")
  func removeCloudProfileCallsOnProfileDeleted() throws {
    let defaults = makeDefaults()
    let containerManager = try ProfileContainerManager.forTesting()
    let store = ProfileStore(defaults: defaults, containerManager: containerManager)

    let profile = Profile(
      label: "Cloud",
      backendType: .cloudKit,
      currencyCode: "AUD",
      financialYearStartMonth: 7
    )
    store.addProfile(profile)

    var deletedIDs: [UUID] = []
    store.onProfileDeleted = { id in deletedIDs.append(id) }

    store.removeProfile(profile.id)

    #expect(deletedIDs == [profile.id])
  }

  @Test("removeProfile does not call onProfileDeleted for remote profiles")
  func removeRemoteProfileDoesNotCallOnProfileDeleted() throws {
    let defaults = makeDefaults()
    let store = ProfileStore(defaults: defaults)
    let profile = makeProfile()
    store.addProfile(profile)

    var deletedIDs: [UUID] = []
    store.onProfileDeleted = { id in deletedIDs.append(id) }

    store.removeProfile(profile.id)

    #expect(deletedIDs.isEmpty)
  }

  @Test("loadCloudProfiles does not clean up profiles on initial load")
  func initialLoadDoesNotCleanUp() throws {
    let defaults = makeDefaults()
    let containerManager = try ProfileContainerManager.forTesting()

    // Pre-save a cloud profile as the active one
    let cloudProfileID = UUID()
    defaults.set(cloudProfileID.uuidString, forKey: "com.moolah.activeProfileID")

    let store = ProfileStore(defaults: defaults, containerManager: containerManager)

    var removedIDs: [UUID] = []
    store.onProfileRemoved = { id in removedIDs.append(id) }

    // Initial load with empty SwiftData — should NOT trigger cleanup
    store.loadCloudProfiles(isInitialLoad: true)

    #expect(removedIDs.isEmpty)
  }

  // MARK: - Retry task lifecycle

  @Test("initial load schedules a retry when cloud store is empty but active profile is cloud")
  func initialLoadSchedulesRetry() throws {
    let defaults = makeDefaults()
    let cloudProfileID = UUID()
    defaults.set(cloudProfileID.uuidString, forKey: "com.moolah.activeProfileID")

    let containerManager = try ProfileContainerManager.forTesting()
    let store = ProfileStore(defaults: defaults, containerManager: containerManager)

    #expect(store.isCloudLoadPending == true)
  }

  @Test("no retry is scheduled when a remote profile already satisfies activeProfileID")
  func noRetryWhenRemoteProfilePresent() throws {
    let defaults = makeDefaults()
    let remote = makeProfile(label: "Remote")
    let encoded = try JSONEncoder().encode([remote])
    defaults.set(encoded, forKey: "com.moolah.profiles")
    defaults.set(remote.id.uuidString, forKey: "com.moolah.activeProfileID")

    let containerManager = try ProfileContainerManager.forTesting()
    let store = ProfileStore(defaults: defaults, containerManager: containerManager)

    #expect(store.isCloudLoadPending == false)
  }

  @Test("loadCloudProfiles cancels the pending retry once profiles are found")
  func loadCloudProfilesCancelsPendingRetry() throws {
    let defaults = makeDefaults()
    let cloudProfileID = UUID()
    defaults.set(cloudProfileID.uuidString, forKey: "com.moolah.activeProfileID")

    let containerManager = try ProfileContainerManager.forTesting()
    let store = ProfileStore(defaults: defaults, containerManager: containerManager)

    // Retry should be pending because the active profile has no backing record yet.
    #expect(store.isCloudLoadPending == true)

    // Insert a ProfileRecord directly — simulates CloudKit finishing its initial
    // import after the store was constructed.
    let context = ModelContext(containerManager.indexContainer)
    let profile = Profile(
      id: cloudProfileID,
      label: "Cloud",
      backendType: .cloudKit,
      currencyCode: "AUD",
      financialYearStartMonth: 7
    )
    context.insert(ProfileRecord.from(profile: profile))
    try context.save()

    // A remote-change-driven reload should find the profile and cancel the
    // pending retry so we don't do redundant work.
    store.loadCloudProfiles(isInitialLoad: false)

    #expect(store.cloudProfiles.count == 1)
    #expect(store.isCloudLoadPending == false)
  }
}
