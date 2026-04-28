@preconcurrency import CloudKit
import Foundation

extension SyncCoordinator {
  // MARK: - Handler Access

  /// Returns (or creates) a `ProfileDataSyncHandler` for the given profile zone.
  func handlerForProfileZone(
    profileId: UUID, zoneID: CKRecordZone.ID
  ) throws -> ProfileDataSyncHandler {
    if let existing = dataHandlers[profileId] {
      return existing
    }
    let container = try containerManager.container(for: profileId)
    let onInstrumentRemoteChange = instrumentRemoteChangeCallbacks[profileId] ?? {}
    let handler = ProfileDataSyncHandler(
      profileId: profileId,
      zoneID: zoneID,
      modelContainer: container,
      onInstrumentRemoteChange: onInstrumentRemoteChange)
    dataHandlers[profileId] = handler
    return handler
  }

  /// Registers the per-profile closure fired by the data handler whenever a
  /// remote pull touches an `InstrumentRecord` row. The closure is captured
  /// by `ProfileDataSyncHandler` at handler-construction time, so callers
  /// MUST register it before the first sync session for the profile (in
  /// practice, from `ProfileSession.registerWithSyncCoordinator`).
  /// Re-registering for a profile whose handler is already cached is a no-op
  /// — `dataHandlers` is not cleared by `stop()`, so the cached handler
  /// retains its original `nonisolated let` closure for its full lifetime.
  /// Pair with `removeInstrumentRemoteChangeCallback(profileId:)` on session
  /// teardown so the dictionary doesn't accumulate stale entries.
  func setInstrumentRemoteChangeCallback(
    profileId: UUID,
    _ callback: @escaping @Sendable () -> Void
  ) {
    instrumentRemoteChangeCallbacks[profileId] = callback
  }

  /// Removes the per-profile instrument-change callback (e.g. on session
  /// teardown so the registry it captures can be released).
  func removeInstrumentRemoteChangeCallback(profileId: UUID) {
    instrumentRemoteChangeCallbacks.removeValue(forKey: profileId)
  }
}
