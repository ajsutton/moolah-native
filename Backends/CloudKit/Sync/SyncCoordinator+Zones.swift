@preconcurrency import CloudKit
import Foundation
import OSLog
import SwiftData

// Zone-level handling for `SyncCoordinator`: proactive zone creation, remote
// zone-deletion responses, and iCloud account-change handling.
@MainActor
extension SyncCoordinator {

  // MARK: - Zone Creation

  func ensureZoneExists(_ zoneID: CKRecordZone.ID) async {
    do {
      let zone = CKRecordZone(zoneID: zoneID)
      _ = try await CloudKitContainer.app.privateCloudDatabase.save(zone)
      logger.info("Ensured zone exists: \(zoneID.zoneName)")
    } catch {
      logger.error("Failed to ensure zone exists \(zoneID.zoneName): \(error, privacy: .public)")
    }
  }

  /// Creates a zone and re-queues pending records after creation succeeds.
  /// Records are stored in `pendingZoneCreation` so `nextRecordZoneChangeBatch` skips them.
  func ensureProfileZone(
    _ zoneID: CKRecordZone.ID,
    pendingChanges: [CKSyncEngine.PendingRecordZoneChange]
  ) {
    // Merge with any existing pending changes for this zone
    pendingZoneCreation[zoneID, default: []].append(contentsOf: pendingChanges)

    // Don't start a duplicate task
    guard zoneCreationTasks[zoneID] == nil else { return }

    zoneCreationTasks[zoneID] = Task {
      await self.ensureZoneExists(zoneID)
      // Re-queue the stored records
      if let changes = self.pendingZoneCreation.removeValue(forKey: zoneID) {
        self.syncEngine?.state.add(pendingRecordZoneChanges: changes)
        self.refreshPendingUploadsMirror()
        self.logger.info(
          "Re-queued \(changes.count) changes after zone creation for \(zoneID.zoneName)")
      }
      self.zoneCreationTasks.removeValue(forKey: zoneID)
    }
  }

  // MARK: - Account Changes

  /// Single setter for iCloud availability and its `progress` mirror.
  /// Replaces direct writes to `iCloudAvailability` from `handleAccountChange`
  /// and `completeStart`. When transitioning to `.available` the call also
  /// fires `progress.didStart(iCloudAvailable: true)` so the indicator
  /// enters `.connecting` once the async availability probe resolves —
  /// `completeStart` runs before the probe returns.
  @MainActor
  func applyICloudAvailability(_ availability: ICloudAvailability) {
    let wasAvailable = iCloudAvailability == .available
    iCloudAvailability = availability
    let reason: ICloudAvailability.UnavailableReason?
    if case .unavailable(let unavailableReason) = availability {
      reason = unavailableReason
    } else {
      reason = nil
    }
    progress.setICloudUnavailable(reason: reason)
    if availability == .available && !wasAvailable {
      progress.didStart(iCloudAvailable: true)
    }
  }

  /// Maps a CloudKit account-change type to ``ICloudAvailability`` and
  /// applies it. Pure assignment — safe to call on every event, including
  /// the synthetic first-launch `.signIn`.
  ///
  /// `.signIn` / `.switchAccounts` both mean "we now have a usable
  /// account" → `.available`. `.signOut` → `.unavailable(.notSignedIn)`.
  func applyAvailability(
    from changeType: CKSyncEngine.Event.AccountChange.ChangeType
  ) {
    switch changeType {
    case .signIn, .switchAccounts:
      applyICloudAvailability(.available)
    case .signOut:
      applyICloudAvailability(.unavailable(reason: .notSignedIn))
    @unknown default:
      logger.warning(
        "Unhandled account-change type — iCloudAvailability not updated"
      )
    }
  }

  func handleAccountChange(_ change: CKSyncEngine.Event.AccountChange) async {
    // Update observable availability first — pure assignment that is
    // safe to fire on every event (including the synthetic first-launch
    // `.signIn`), so views react immediately. The isFirstLaunch-gated
    // zone-reset work below runs exactly as before.
    applyAvailability(from: change.changeType)

    switch change.changeType {
    case .signIn:
      if isFirstLaunch {
        logger.info("Synthetic sign-in on first launch — skipping re-upload")
        isFirstLaunch = false
      } else {
        logger.info("Account signed in — re-uploading all local data")
        await queueAllExistingRecordsForAllZones()
      }

    case .signOut:
      logger.info("Account signed out — deleting all local data and sync state")
      await deleteAllLocalData()
      deleteStateSerialization()
      clearAllBackfillScanFlags()
      isFetchingChanges = false

    case .switchAccounts:
      logger.info("Account switched — full reset")
      await deleteAllLocalData()
      deleteStateSerialization()
      clearAllBackfillScanFlags()
      isFetchingChanges = false

    @unknown default:
      break
    }
  }

  func deleteAllLocalData() async {
    // Delete profile-index data
    profileIndexHandler.deleteLocalData()
    notifyIndexObservers()

    // Delete all profile data
    for profileId in await containerManager.allProfileIds() {
      let zoneID = CKRecordZone.ID(
        zoneName: "profile-\(profileId.uuidString)",
        ownerName: CKCurrentUserDefaultName)
      if let handler = try? handlerForProfileZone(profileId: profileId, zoneID: zoneID) {
        let changedTypes = handler.deleteLocalData()
        if !changedTypes.isEmpty {
          notifyObservers(for: profileId, changedTypes: changedTypes)
        }
      }
    }
    dataHandlers.removeAll()
  }

  // MARK: - Fetched Database Changes (Zone Deletions)

  func handleFetchedDatabaseChanges(
    _ changes: CKSyncEngine.Event.FetchedDatabaseChanges
  ) {
    for deletion in changes.deletions {
      let zoneType = Self.parseZone(deletion.zoneID)

      switch deletion.reason {
      case .deleted:
        handleZoneDeleted(deletion.zoneID, zoneType: zoneType)

      case .purged:
        handleZonePurged(deletion.zoneID, zoneType: zoneType)

      case .encryptedDataReset:
        handleEncryptedDataReset(deletion.zoneID, zoneType: zoneType)

      @unknown default:
        logger.warning("Unknown zone deletion reason for \(deletion.zoneID.zoneName)")
      }
    }
  }

  func handleZoneDeleted(_ zoneID: CKRecordZone.ID, zoneType: ZoneType) {
    switch zoneType {
    case .profileIndex:
      logger.warning("Profile-index zone was deleted remotely — removing local data")
      profileIndexHandler.deleteLocalData()
      notifyIndexObservers()

    case .profileData(let profileId):
      logger.warning("Profile zone deleted: \(profileId) — removing local data")
      if let handler = try? handlerForProfileZone(profileId: profileId, zoneID: zoneID) {
        let changedTypes = handler.deleteLocalData()
        if !changedTypes.isEmpty {
          notifyObservers(for: profileId, changedTypes: changedTypes)
        }
      }
      // Records have been wiped; any re-created zone starts with no system fields and
      // must be re-scanned. Clear the flag so the next backfill pass picks it up.
      clearBackfillScanFlag(for: profileId)

    case .unknown:
      break
    }
  }

  func handleZonePurged(_ zoneID: CKRecordZone.ID, zoneType: ZoneType) {
    // Purge: delete data AND state file (forces full re-fetch of all zones)
    switch zoneType {
    case .profileIndex:
      logger.warning("Profile-index zone purged — deleting data and state")
      profileIndexHandler.deleteLocalData()
      notifyIndexObservers()

    case .profileData(let profileId):
      logger.warning("Profile zone purged: \(profileId) — deleting data")
      if let handler = try? handlerForProfileZone(profileId: profileId, zoneID: zoneID) {
        let changedTypes = handler.deleteLocalData()
        if !changedTypes.isEmpty {
          notifyObservers(for: profileId, changedTypes: changedTypes)
        }
      }
      clearBackfillScanFlag(for: profileId)

    case .unknown:
      break
    }
    // Delete shared state file — all zones re-fetch
    deleteStateSerialization()
  }

  func handleEncryptedDataReset(_ zoneID: CKRecordZone.ID, zoneType: ZoneType) {
    // Delete state file, clear system fields, re-queue records
    deleteStateSerialization()

    switch zoneType {
    case .profileIndex:
      logger.warning("Encrypted data reset for profile-index — re-uploading")
      profileIndexHandler.clearAllSystemFields()
      let recordIDs = profileIndexHandler.queueAllExistingRecords()
      if !recordIDs.isEmpty {
        syncEngine?.state.add(
          pendingRecordZoneChanges: recordIDs.map { .saveRecord($0) })
        refreshPendingUploadsMirror()
      }

    case .profileData(let profileId):
      logger.warning("Encrypted data reset for profile \(profileId) — re-uploading")
      if let handler = try? handlerForProfileZone(profileId: profileId, zoneID: zoneID) {
        handler.clearAllSystemFields()
        let recordIDs = handler.queueAllExistingRecords()
        if !recordIDs.isEmpty {
          syncEngine?.state.add(
            pendingRecordZoneChanges: recordIDs.map { .saveRecord($0) })
          refreshPendingUploadsMirror()
        }
      }
      // TODO(#619): if `handlerForProfileZone` threw because the profile's
      // session has not yet been registered, the records keep their stale
      // (non-nil) `encodedSystemFields` and the backfill scan won't re-queue
      // them — `queueUnsyncedRecords` only picks up records where the
      // system field is nil. Eager session construction will close this gap.
      // https://github.com/ajsutton/moolah-native/issues/619
      //
      // System fields were cleared; if a later crash happens before the re-upload
      // persists, the next backfill scan must revisit this profile instead of
      // trusting a stale "complete" flag from before the reset.
      clearBackfillScanFlag(for: profileId)

    case .unknown:
      break
    }
  }
}
