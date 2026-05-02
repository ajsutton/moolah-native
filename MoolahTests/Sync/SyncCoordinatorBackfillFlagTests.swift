import CloudKit
import Foundation
import SwiftData
import Testing

@testable import Moolah

/// Tests covering the lifecycle of the per-profile "backfill scan
/// complete" `UserDefaults` flag — when sign-out, encrypted-data
/// reset, and server-side zone deletion clear it so the next session
/// re-runs the unsynced-record scan. Split out of
/// `SyncCoordinatorTestsExtra` to keep type bodies under the SwiftLint
/// `type_body_length` threshold.
@Suite("SyncCoordinator backfill flag lifecycle")
@MainActor
struct SyncCoordinatorBackfillFlagTests {
  private func makeDefaults() throws -> UserDefaults {
    try #require(UserDefaults(suiteName: "sync-coordinator-test-\(UUID().uuidString)"))
  }

  @Test(
    "Sign-out clears all backfill-scan flags so the next sign-in can rescan"
  )
  func signOutClearsBackfillFlags() async throws {
    let manager = try ProfileContainerManager.forTesting()
    let defaults = try makeDefaults()
    let coordinator = SyncCoordinator(
      containerManager: manager,
      userDefaults: defaults)

    let profileId = UUID()
    let indexContext = ModelContext(manager.indexContainer)
    indexContext.insert(
      ProfileRecord(
        id: profileId, label: "A", currencyCode: "AUD",
        financialYearStartMonth: 7, createdAt: Date()))
    try indexContext.save()

    // Seed an unsynced record and scan so the flag is set.
    let accountId = UUID()
    let container = try manager.container(for: profileId)
    let context = ModelContext(container)
    context.insert(
      AccountRecord(id: accountId, name: "A1", type: "bank", position: 0, isHidden: false))
    try context.save()
    let database = try manager.database(for: profileId)
    try ProfileDataSyncHandlerTestSupport.mirrorContainerToDatabase(
      container: container, database: database)
    _ = await coordinator.queueUnsyncedRecordsForAllProfiles()

    // Simulate the sign-out handler firing.
    await coordinator.handleSignOutForTesting()

    // After sign-out, backfill state is gone — a future scan would rerun for the profile.
    // We can't directly seed a profile back (deleteAllLocalData removed it), but we can
    // observe the UserDefaults flag is cleared.
    let key = "com.moolah.sync.backfillScanComplete.\(profileId.uuidString)"
    #expect(defaults.bool(forKey: key) == false)
  }

  @Test(
    "encryptedDataReset on a profile zone clears its backfill flag so re-queued records get tracked afresh"
  )
  func encryptedDataResetClearsBackfillFlag() async throws {
    let manager = try ProfileContainerManager.forTesting()
    let defaults = try makeDefaults()
    let coordinator = SyncCoordinator(
      containerManager: manager,
      userDefaults: defaults)

    let profileId = UUID()
    let indexContext = ModelContext(manager.indexContainer)
    indexContext.insert(
      ProfileRecord(
        id: profileId, label: "A", currencyCode: "AUD",
        financialYearStartMonth: 7, createdAt: Date()))
    try indexContext.save()

    let accountId = UUID()
    let container = try manager.container(for: profileId)
    let context = ModelContext(container)
    context.insert(
      AccountRecord(id: accountId, name: "A1", type: "bank", position: 0, isHidden: false))
    try context.save()
    let database = try manager.database(for: profileId)
    try ProfileDataSyncHandlerTestSupport.mirrorContainerToDatabase(
      container: container, database: database)
    _ = await coordinator.queueUnsyncedRecordsForAllProfiles()

    let zoneID = CKRecordZone.ID(
      zoneName: "profile-\(profileId.uuidString)",
      ownerName: CKCurrentUserDefaultName)
    coordinator.handleEncryptedDataResetForTesting(zoneID: zoneID)

    let key = "com.moolah.sync.backfillScanComplete.\(profileId.uuidString)"
    #expect(defaults.bool(forKey: key) == false)
  }

  @Test(
    "Server-side profile zone deletion clears the backfill flag so a re-created zone rescans"
  )
  func zoneDeletionClearsBackfillFlag() async throws {
    let manager = try ProfileContainerManager.forTesting()
    let defaults = try makeDefaults()
    let coordinator = SyncCoordinator(
      containerManager: manager,
      userDefaults: defaults)

    let profileId = UUID()
    let indexContext = ModelContext(manager.indexContainer)
    indexContext.insert(
      ProfileRecord(
        id: profileId, label: "A", currencyCode: "AUD",
        financialYearStartMonth: 7, createdAt: Date()))
    try indexContext.save()

    let container = try manager.container(for: profileId)
    let context = ModelContext(container)
    context.insert(
      AccountRecord(id: UUID(), name: "A1", type: "bank", position: 0, isHidden: false))
    try context.save()
    let database = try manager.database(for: profileId)
    try ProfileDataSyncHandlerTestSupport.mirrorContainerToDatabase(
      container: container, database: database)
    _ = await coordinator.queueUnsyncedRecordsForAllProfiles()

    let zoneID = CKRecordZone.ID(
      zoneName: "profile-\(profileId.uuidString)",
      ownerName: CKCurrentUserDefaultName)
    coordinator.handleZoneDeletedForTesting(zoneID: zoneID)

    let key = "com.moolah.sync.backfillScanComplete.\(profileId.uuidString)"
    #expect(defaults.bool(forKey: key) == false)
  }
}
