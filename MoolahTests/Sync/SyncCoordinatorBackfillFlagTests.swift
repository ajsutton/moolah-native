import CloudKit
import Foundation
import GRDB
import Testing

@testable import Moolah

/// Tests covering the lifecycle of the per-profile "backfill scan
/// complete" `UserDefaults` flag — when sign-out, encrypted-data
/// reset, and server-side zone deletion clear it so the next session
/// re-runs the unsynced-record scan.
@Suite("SyncCoordinator backfill flag lifecycle")
@MainActor
struct SyncCoordinatorBackfillFlagTests {
  private func makeDefaults() throws -> UserDefaults {
    try #require(UserDefaults(suiteName: "sync-coordinator-test-\(UUID().uuidString)"))
  }

  /// Registers a profile in the GRDB index and seeds one unsynced
  /// `AccountRow` into its per-profile data DB so a follow-up backfill
  /// scan has something to queue.
  private func seedUnsyncedAccount(
    in manager: ProfileContainerManager,
    profileId: UUID
  ) async throws -> UUID {
    try await manager.profileIndexRepository.upsert(
      Profile(
        id: profileId, label: "A", currencyCode: "AUD",
        financialYearStartMonth: 7, createdAt: Date()))

    let accountId = UUID()
    let database = try manager.database(for: profileId)
    try await database.write { database in
      try ProfileDataSyncHandlerTestSupport.accountRow(
        id: accountId, name: "A1"
      ).upsert(database)
    }
    return accountId
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
    _ = try await seedUnsyncedAccount(in: manager, profileId: profileId)
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
    _ = try await seedUnsyncedAccount(in: manager, profileId: profileId)
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
    _ = try await seedUnsyncedAccount(in: manager, profileId: profileId)
    _ = await coordinator.queueUnsyncedRecordsForAllProfiles()

    let zoneID = CKRecordZone.ID(
      zoneName: "profile-\(profileId.uuidString)",
      ownerName: CKCurrentUserDefaultName)
    coordinator.handleZoneDeletedForTesting(zoneID: zoneID)

    let key = "com.moolah.sync.backfillScanComplete.\(profileId.uuidString)"
    #expect(defaults.bool(forKey: key) == false)
  }
}
