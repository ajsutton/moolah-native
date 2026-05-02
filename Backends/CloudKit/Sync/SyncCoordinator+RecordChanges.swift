// swiftlint:disable multiline_arguments
// Reason: swift-format wraps long initialisers / SwiftUI builders across
// multiple lines in a way the multiline_arguments rule disagrees with.

@preconcurrency import CloudKit
import Foundation
import OSLog
import SwiftData
import os

// Fetched-change application (off-main, hops to `@MainActor` for observer
// notifications) and sent-change handling (on-main, per-zone failure dispatch
// + quota tracking) for `SyncCoordinator`.
extension SyncCoordinator {

  // MARK: - Fetched Record Zone Changes

  /// Processes fetched record zone changes with heavy SwiftData work off the main actor.
  /// Resolves handlers and manages state on @MainActor; upsert/delete/save runs off-main.
  nonisolated func handleFetchedRecordZoneChangesAsync(
    _ changes: CKSyncEngine.Event.FetchedRecordZoneChanges
  ) async {
    // Group records by zone off-main
    var savedByZone: [CKRecordZone.ID: [CKRecord]] = [:]
    for modification in changes.modifications {
      let record = modification.record
      savedByZone[record.recordID.zoneID, default: []].append(record)
    }
    var deletedByZone: [CKRecordZone.ID: [(CKRecord.ID, String)]] = [:]
    for deletion in changes.deletions {
      deletedByZone[deletion.recordID.zoneID, default: []]
        .append((deletion.recordID, deletion.recordType))
    }

    // Pre-extract system fields off-main
    let preExtractedSystemFields: [(String, Data)] = changes.modifications
      .map { ($0.record.recordID.recordName, $0.record.encodedSystemFields) }

    // Hop to main to update SyncProgress with this batch's counts.
    // Settled state is tracked separately via endFetchingChanges.
    let modCount = changes.modifications.count
    let delCount = changes.deletions.count
    await MainActor.run {
      self.accumulateProgressCounts(modifications: modCount, deletions: delCount)
    }

    let allZones = Set(savedByZone.keys).union(deletedByZone.keys)
    for zoneID in allZones {
      let saved = savedByZone[zoneID] ?? []
      let deleted = deletedByZone[zoneID] ?? []
      await applyFetchedZoneChanges(
        zoneID: zoneID,
        saved: saved,
        deleted: deleted,
        preExtractedSystemFields: preExtractedSystemFields)
    }
  }

  /// Applies fetched changes for a single zone, wrapping the per-kind dispatch
  /// in a signpost and slow-zone log. Extracted so
  /// `handleFetchedRecordZoneChangesAsync` stays under the complexity / body
  /// length limits.
  nonisolated private func applyFetchedZoneChanges(
    zoneID: CKRecordZone.ID,
    saved: [CKRecord],
    deleted: [(CKRecord.ID, String)],
    preExtractedSystemFields: [(String, Data)]
  ) async {
    let zoneType = Self.parseZone(zoneID)

    let signpostID = OSSignpostID(log: Signposts.sync)
    os_signpost(
      .begin, log: Signposts.sync, name: "applyFetchedChanges", signpostID: signpostID,
      "%{public}@ %{public}d saves %{public}d deletes", zoneID.zoneName, saved.count,
      deleted.count)
    let zoneStart = ContinuousClock.now

    switch zoneType {
    case .profileIndex:
      await applyFetchedIndexChanges(saved: saved, deleted: deleted)

    case .profileData(let profileId):
      await applyFetchedProfileDataChanges(
        profileId: profileId,
        zoneID: zoneID,
        saved: saved,
        deleted: deleted,
        preExtractedSystemFields: preExtractedSystemFields)

    case .unknown:
      logger.warning("Received changes for unknown zone: \(zoneID.zoneName)")
    }

    os_signpost(.end, log: Signposts.sync, name: "applyFetchedChanges", signpostID: signpostID)
    let zoneMs = (ContinuousClock.now - zoneStart).inMilliseconds
    if zoneMs > 100 {
      logger.info(
        "applyFetchedChanges took \(zoneMs)ms (\(zoneID.zoneName), \(saved.count) saves, \(deleted.count) deletes)"
      )
    }
  }

  /// Applies fetched changes for the profile-index zone. Off-main apply + MainActor
  /// hop for observer / refetch bookkeeping. Schedules a re-fetch on save failure.
  nonisolated private func applyFetchedIndexChanges(
    saved: [CKRecord],
    deleted: [(CKRecord.ID, String)]
  ) async {
    let deletedIDs = deleted.map(\.0)
    // Index upsert is fast (few records), run off-main
    let indexResult = profileIndexHandler.applyRemoteChanges(saved: saved, deleted: deletedIDs)
    switch indexResult {
    case .success:
      await MainActor.run {
        // Successful apply proves local writes are working — reset the re-fetch
        // attempt counter so a future transient failure gets a full retry budget.
        resetRefetchAttempts()
        if isFetchingChanges {
          fetchSessionIndexChanged = true
        } else {
          notifyIndexObservers()
        }
      }
    case .saveFailed(let errorDescription):
      logger.error(
        "Profile index save failed, scheduling re-fetch: \(errorDescription, privacy: .public)")
      await scheduleRefetch()
    }
  }

  /// Applies fetched changes for a profile-data zone. Handler resolution runs on
  /// MainActor; the heavy upsert/delete/save runs off-main via a nonisolated
  /// handler method; observer notifications hop back to MainActor.
  nonisolated private func applyFetchedProfileDataChanges(
    profileId: UUID,
    zoneID: CKRecordZone.ID,
    saved: [CKRecord],
    deleted: [(CKRecord.ID, String)],
    preExtractedSystemFields: [(String, Data)]
  ) async {
    // Resolve handler on main (accesses @MainActor-isolated state).
    //
    // `profileNotRegistered` is fatal in this path: CKSyncEngine
    // advances the server change token after this delegate call
    // returns, so silently skipping the apply would lose records
    // permanently. Production wiring (`MoolahApp.configureSyncCoordinator`
    // → `coordinator.startAfter(profileIndexMigration:)`) defers
    // engine start until the GRDB profile-index migration commits and
    // `ProfileSession` registers its bundle, so reaching here with no
    // bundle is an invariant violation. Other thrown errors (e.g.
    // transient `containerManager.container(for:)` failures) fall
    // through to the existing log + skip path.
    let handler: ProfileDataSyncHandler? = await MainActor.run {
      do {
        return try handlerForProfileZone(profileId: profileId, zoneID: zoneID)
      } catch SyncCoordinatorError.profileNotRegistered(let id) {
        preconditionFailure(
          """
          applyFetchedProfileDataChanges called for profile \(id.uuidString) \
          before its GRDB repository bundle was registered. \
          startAfter(profileIndexMigration:) must complete before any \
          CKSyncEngine fetch event lands; reaching here means the gate \
          failed. Crashing rather than advancing the server change token \
          past unapplied records — restart will re-fetch.
          """)
      } catch {
        logger.error("Failed to get handler for profile \(profileId): \(error, privacy: .public)")
        return nil
      }
    }
    guard let handler else { return }

    // Filter pre-extracted system fields to this zone (off-main)
    let savedNames = Set(saved.map { $0.recordID.recordName })
    let zonePreExtracted = preExtractedSystemFields.filter { recordName, _ in
      savedNames.contains(recordName)
    }

    // Heavy upsert/delete/save runs off-main via nonisolated method
    let result = handler.applyRemoteChanges(
      saved: saved, deleted: deleted, preExtractedSystemFields: zonePreExtracted)

    // Notify observers on main — read isFetchingChanges live to avoid
    // stale snapshot if stop() was called during applyRemoteChanges
    switch result {
    case .success(let changedTypes):
      await MainActor.run {
        // Successful apply proves local writes are working — reset the re-fetch
        // attempt counter so a future transient failure gets a full retry budget.
        resetRefetchAttempts()
        if !changedTypes.isEmpty {
          if isFetchingChanges {
            accumulateFetchSessionChanges(for: profileId, changedTypes: changedTypes)
          } else {
            notifyObservers(for: profileId, changedTypes: changedTypes)
          }
        }
      }
    case .saveFailed(let errorDescription):
      logger.error(
        "Profile data save failed for \(profileId), scheduling re-fetch: \(errorDescription, privacy: .public)"
      )
      await scheduleRefetch()
    }
  }

  // MARK: - Sent Record Zone Changes

  @MainActor
  func handleSentRecordZoneChanges(
    _ sentChanges: CKSyncEngine.Event.SentRecordZoneChanges
  ) {
    let signpostID = OSSignpostID(log: Signposts.sync)
    os_signpost(
      .begin, log: Signposts.sync, name: "handleSentChanges", signpostID: signpostID,
      "%{public}d saved %{public}d failedSaves %{public}d failedDeletes",
      sentChanges.savedRecords.count, sentChanges.failedRecordSaves.count,
      sentChanges.failedRecordDeletes.count)
    defer {
      os_signpost(.end, log: Signposts.sync, name: "handleSentChanges", signpostID: signpostID)
    }
    logger.info(
      "sentRecordZoneChanges: saved=\(sentChanges.savedRecords.count) failedSaves=\(sentChanges.failedRecordSaves.count) failedDeletes=\(sentChanges.failedRecordDeletes.count)"
    )

    // Group saved records by zone
    var savedByZone: [CKRecordZone.ID: [CKRecord]] = [:]
    for record in sentChanges.savedRecords {
      savedByZone[record.recordID.zoneID, default: []].append(record)
    }

    // Group failed saves by zone
    var failedSavesByZone:
      [CKRecordZone.ID: [CKSyncEngine.Event.SentRecordZoneChanges
        .FailedRecordSave]] = [:]
    for failure in sentChanges.failedRecordSaves {
      failedSavesByZone[failure.record.recordID.zoneID, default: []].append(failure)
    }

    // Group failed deletes by zone
    var failedDeletesByZone: [CKRecordZone.ID: [(CKRecord.ID, CKError)]] = [:]
    for (recordID, error) in sentChanges.failedRecordDeletes {
      failedDeletesByZone[recordID.zoneID, default: []].append((recordID, error))
    }

    // Process each zone's results through the appropriate handler
    let allZones = Set(savedByZone.keys)
      .union(failedSavesByZone.keys)
      .union(failedDeletesByZone.keys)

    for zoneID in allZones {
      processSentZone(
        zoneID: zoneID,
        savedByZone: savedByZone,
        failedSavesByZone: failedSavesByZone,
        failedDeletesByZone: failedDeletesByZone)
    }

    updateQuotaExceededState(from: sentChanges)
  }

  /// Runs one zone's sent-change results through the appropriate handler and
  /// handles any zone-not-found failures by creating the zone and re-queuing.
  /// Extracted so `handleSentRecordZoneChanges` stays under the complexity /
  /// body length limits.
  @MainActor
  private func processSentZone(
    zoneID: CKRecordZone.ID,
    savedByZone: [CKRecordZone.ID: [CKRecord]],
    failedSavesByZone: [CKRecordZone.ID: [CKSyncEngine.Event.SentRecordZoneChanges
      .FailedRecordSave]],
    failedDeletesByZone: [CKRecordZone.ID: [(CKRecord.ID, CKError)]]
  ) {
    let zoneType = Self.parseZone(zoneID)
    let failures: SyncErrorRecovery.ClassifiedFailures

    switch zoneType {
    case .profileIndex:
      failures = profileIndexHandler.handleSentRecordZoneChanges(
        savedRecords: savedByZone[zoneID] ?? [],
        failedSaves: failedSavesByZone[zoneID] ?? [],
        failedDeletes: failedDeletesByZone[zoneID] ?? [])

    case .profileData(let profileId):
      guard let handler = try? handlerForProfileZone(profileId: profileId, zoneID: zoneID)
      else {
        logger.error("Failed to get handler for sent changes, profile \(profileId)")
        return
      }
      failures = handler.handleSentRecordZoneChanges(
        savedRecords: savedByZone[zoneID] ?? [],
        failedSaves: failedSavesByZone[zoneID] ?? [],
        failedDeletes: failedDeletesByZone[zoneID] ?? [])

    case .unknown:
      logger.warning("Sent changes for unknown zone: \(zoneID.zoneName)")
      return
    }

    // Re-queue failures (except zone-not-found which needs zone creation)
    let (zoneNotFoundSaves, zoneNotFoundDeletes) = SyncErrorRecovery.requeueFailures(
      failures, syncEngine: syncEngine, logger: logger)

    // Handle zone-not-found: store records and create zone
    if !zoneNotFoundSaves.isEmpty || !zoneNotFoundDeletes.isEmpty {
      var pendingChanges: [CKSyncEngine.PendingRecordZoneChange] = []
      pendingChanges += zoneNotFoundSaves.map { .saveRecord($0) }
      pendingChanges += zoneNotFoundDeletes.map { .deleteRecord($0) }
      ensureProfileZone(zoneID, pendingChanges: pendingChanges)
    }
  }

  /// Tracks whether the user's iCloud quota is exceeded across all zones in the
  /// current send cycle. Empty events (no saves, no failed saves) are ignored
  /// so the flag doesn't bounce to `false` on heartbeat send cycles.
  @MainActor
  private func updateQuotaExceededState(
    from sentChanges: CKSyncEngine.Event.SentRecordZoneChanges
  ) {
    let hasQuotaErrors = sentChanges.failedRecordSaves.contains { $0.error.code == .quotaExceeded }
    if hasQuotaErrors {
      applyQuotaState(true)
    } else if !sentChanges.failedRecordSaves.isEmpty || !sentChanges.savedRecords.isEmpty {
      // Only clear if we actually processed records (not an empty event)
      applyQuotaState(false)
    }
    refreshPendingUploadsMirror()
  }

  /// Routes batch totals into `progress`. Internal so unit tests can drive
  /// the counter without constructing a `CKSyncEngine.Event` value.
  @MainActor
  func accumulateProgressCounts(modifications: Int, deletions: Int) {
    progress.recordReceived(modifications: modifications, deletions: deletions)
  }

  /// Single setter for the quota-exceeded flag and its `progress` mirror.
  /// Replaces direct writes to `isQuotaExceeded` from the send path.
  @MainActor
  func applyQuotaState(_ exceeded: Bool) {
    isQuotaExceeded = exceeded
    progress.setQuotaExceeded(exceeded)
  }

  /// Pushes the live `pendingRecordZoneChanges.count` into `progress`.
  /// Called after every send event and after queueing changes.
  @MainActor
  func refreshPendingUploadsMirror() {
    let count = syncEngine?.state.pendingRecordZoneChanges.count ?? 0
    progress.updatePendingUploads(count)
  }
}
