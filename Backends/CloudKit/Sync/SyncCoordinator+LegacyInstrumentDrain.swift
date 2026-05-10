@preconcurrency import CloudKit
import Foundation

extension SyncCoordinator {
  // MARK: - Legacy InstrumentRecord Drain

  /// Returns the subset of `changes` that are leftover legacy
  /// `InstrumentRecord` pending changes routed to a per-profile zone.
  ///
  /// Two shapes can survive the shared-instrument-registry rollout
  /// (PR #861):
  /// - Prefixed `"InstrumentRecord|<UUID>"` recordNames queued by a
  ///   pre-rollout build.
  /// - Bare string-keyed recordNames (`"AUD"`, `"0:native"`) queued by
  ///   the even-older `<scope>:<id>` instrument shape — these have no
  ///   `|` separator and don't parse as a UUID.
  ///
  /// Both shapes can only have come from a pre-rollout build: post-
  /// rollout, every instrument upload routes through the shared
  /// registry on the `profile-index` zone, and the DEBUG trap in
  /// `ProfileDataSyncHandler.recordToSave` aborts the process if one
  /// reaches the per-profile handler. Dropping these from
  /// CKSyncEngine state at start lets upgraded peers self-heal on
  /// next launch instead of crashing.
  ///
  /// Pure function: takes the input changes and returns the legacy
  /// subset. Caller applies the removal via
  /// `state.remove(pendingRecordZoneChanges:)`. Splitting the filter
  /// keeps this testable without spinning up a real `CKSyncEngine`.
  ///
  /// Companion to `purgeStaleBareUUIDPendingChanges` (issue #416),
  /// which targets the orthogonal bare-UUID legacy shape on UUID-
  /// keyed records — running both at start covers every leftover
  /// shape we know about.
  nonisolated static func legacyInstrumentPendingChanges(
    in changes: some Sequence<CKSyncEngine.PendingRecordZoneChange>
  ) -> [CKSyncEngine.PendingRecordZoneChange] {
    changes.compactMap { change in
      let recordID: CKRecord.ID
      switch change {
      case .saveRecord(let id): recordID = id
      case .deleteRecord(let id): recordID = id
      @unknown default: return nil
      }
      guard case .profileData = parseZone(recordID.zoneID) else { return nil }
      if recordID.prefixedRecordType == InstrumentRow.recordType {
        return change
      }
      let name = recordID.recordName
      if !name.contains("|"), UUID(uuidString: name) == nil {
        return change
      }
      return nil
    }
  }

  /// Removes any pending changes returned by
  /// `legacyInstrumentPendingChanges(in:)` from the live engine state.
  /// Called from `completeStart` next to
  /// `purgeStaleBareUUIDPendingChanges()`. No-op when the engine isn't
  /// running yet or when no legacy entries remain.
  func purgeLegacyInstrumentPendingChanges() {
    guard let syncEngine else { return }
    let stale = Self.legacyInstrumentPendingChanges(
      in: syncEngine.state.pendingRecordZoneChanges)
    guard !stale.isEmpty else { return }
    logger.warning(
      """
      Purging \(stale.count, privacy: .public) legacy InstrumentRecord \
      pending changes routed to per-profile zones — every InstrumentRecord \
      write now flows through the shared registry on the profile-index zone.
      """)
    syncEngine.state.remove(pendingRecordZoneChanges: stale)
  }
}
