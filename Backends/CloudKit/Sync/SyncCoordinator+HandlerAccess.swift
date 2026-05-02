@preconcurrency import CloudKit
import Foundation
import OSLog

extension SyncCoordinator {
  // MARK: - Handler Access

  /// Returns (or creates) a `ProfileDataSyncHandler` for the given profile zone.
  ///
  /// Bundle resolution is delegated to `resolveGRDBRepositories(for:)`, which
  /// returns a cached bundle if one was built before, or constructs a fresh
  /// apply-path bundle via `ProfileGRDBRepositories.makeForApply(database:)` backed
  /// by `containerManager.database(for:)`. This allows sync apply for
  /// un-sessionized profiles (multi-profile background apply, pre-render race,
  /// encrypted reset on an unopened profile) — the scenario that motivated
  /// issue #619.
  func handlerForProfileZone(
    profileId: UUID, zoneID: CKRecordZone.ID
  ) throws -> ProfileDataSyncHandler {
    if let existing = dataHandlers[profileId] {
      return existing
    }
    let container = try containerManager.container(for: profileId)
    let grdbRepositories = try resolveGRDBRepositories(for: profileId)
    let onInstrumentRemoteChange = instrumentRemoteChangeCallbacks[profileId] ?? {}
    let handler = ProfileDataSyncHandler(
      profileId: profileId,
      zoneID: zoneID,
      modelContainer: container,
      grdbRepositories: grdbRepositories,
      onInstrumentRemoteChange: onInstrumentRemoteChange)
    dataHandlers[profileId] = handler
    return handler
  }

  /// Returns the per-profile GRDB repository bundle, constructing and caching
  /// it on first access. The bundle is built via
  /// `ProfileGRDBRepositories.makeForApply(database:)` backed by
  /// `containerManager.database(for:)`, which allows sync apply for
  /// un-sessionized profiles — see issue #619.
  ///
  /// **Main-actor I/O.** First-access resolution opens the per-profile
  /// `DatabaseQueue` synchronously on `@MainActor`. This matches the
  /// pre-existing pattern of `containerManager.container(for:)` two
  /// lines above. The work is bounded (queue init + idempotent schema
  /// migration) and only happens once per profile per process. Moving
  /// it off-actor would require `ProfileContainerManager` to expose
  /// async open methods — a separate refactor.
  private func resolveGRDBRepositories(for profileId: UUID) throws -> ProfileGRDBRepositories {
    if let cached = cachedGRDBRepositories[profileId] {
      return cached
    }
    let database = try containerManager.database(for: profileId)
    let bundle = ProfileGRDBRepositories.makeForApply(database: database)
    cachedGRDBRepositories[profileId] = bundle
    return bundle
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
    if dataHandlers[profileId] != nil {
      logger.warning(
        """
        instrument-change callback registered for profile \
        \(profileId, privacy: .public) after handler was cached; \
        the new closure will not be picked up until \
        removeInstrumentRemoteChangeCallback() is called and the handler is rebuilt
        """
      )
    }
    instrumentRemoteChangeCallbacks[profileId] = callback
  }

  /// Removes the per-profile instrument-change callback (e.g. on session
  /// teardown so the registry it captures can be released).
  func removeInstrumentRemoteChangeCallback(profileId: UUID) {
    instrumentRemoteChangeCallbacks.removeValue(forKey: profileId)
  }

  /// Drops the cached handler and GRDB repository bundle for a profile
  /// being removed locally. The coordinator's caches retain
  /// `DatabaseQueue` references which `ProfileContainerManager.deleteStore`
  /// is about to invalidate; without this eviction a delayed sync event
  /// for the deleted profile would write through a stale queue against
  /// an unlinked file.
  func evictCachedState(for profileId: UUID) {
    dataHandlers.removeValue(forKey: profileId)
    cachedGRDBRepositories.removeValue(forKey: profileId)
  }
}
