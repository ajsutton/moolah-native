@preconcurrency import CloudKit
import Foundation
import OSLog

/// Errors thrown by `SyncCoordinator.handlerForProfileZone(profileId:zoneID:)`.
///
/// `profileNotRegistered` indicates a wiring-order bug: a sync event
/// arrived for a profile whose `ProfileSession` has not yet called
/// `SyncCoordinator.setProfileGRDBRepositories(profileId:bundle:)`.
/// Outbound paths (backfill, zone deletion / purge / encrypted reset,
/// upload-batch building) treat this as recoverable and skip the
/// profile — the records remain durable in GRDB and are re-queued by
/// the next backfill scan or local-mutation hook. The inbound apply
/// path (`applyFetchedProfileDataChanges`) treats it as fatal because
/// `CKSyncEngine` advances the server change token after the delegate
/// returns, so a silent skip would lose records permanently.
enum SyncCoordinatorError: Error, Equatable {
  case profileNotRegistered(UUID)
}

extension SyncCoordinator {
  // MARK: - Handler Access

  /// Returns (or creates) a `ProfileDataSyncHandler` for the given profile zone.
  ///
  /// Bundle resolution is delegated to `resolveGRDBRepositories(for:)`:
  /// a session-registered bundle wins; a test-injected factory is next;
  /// otherwise a fresh apply-path bundle is built via
  /// `ProfileGRDBRepositories.forApply(database:)` backed by
  /// `containerManager.database(for:)`. This last branch allows sync
  /// apply for un-sessionized profiles (multi-profile background apply,
  /// pre-render race, encrypted reset on an unopened profile) — the
  /// scenario that motivated issue #619.
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

  /// Returns the per-profile GRDB repository bundle. Prefers a bundle
  /// registered by `ProfileSession.registerWithSyncCoordinator` (so the
  /// session and the coordinator share an instance during normal app
  /// lifetime), then a test-injected factory, then a freshly-built
  /// apply-path bundle backed by `containerManager.database(for:)`.
  /// The last branch is what allows sync apply for un-sessionized
  /// profiles — see issue #619.
  private func resolveGRDBRepositories(for profileId: UUID) throws -> ProfileGRDBRepositories {
    if let registered = profileGRDBRepositories[profileId] {
      return registered
    }
    if let factory = fallbackGRDBRepositoriesFactory {
      let bundle = try factory(profileId)
      profileGRDBRepositories[profileId] = bundle
      return bundle
    }
    let database = try containerManager.database(for: profileId)
    let bundle = ProfileGRDBRepositories.forApply(database: database)
    profileGRDBRepositories[profileId] = bundle
    return bundle
  }

  /// Registers the GRDB repository bundle for a profile. Must be called
  /// before the first sync event arrives for the profile so
  /// `handlerForProfileZone` can construct a handler.
  ///
  /// If a handler was already cached (e.g. an earlier call constructed
  /// it via the test-only fallback bundle), the cached entry is cleared
  /// so the next `handlerForProfileZone` call rebuilds it against the
  /// freshly-registered bundle. This makes registration idempotent
  /// across the test/production boundary.
  func setProfileGRDBRepositories(
    profileId: UUID, bundle: ProfileGRDBRepositories
  ) {
    if dataHandlers[profileId] != nil {
      logger.info(
        """
        GRDB repository bundle registered for profile \
        \(profileId, privacy: .public) after handler was cached; \
        clearing cached handler so the next handlerForProfileZone \
        call rebuilds against the new bundle
        """
      )
      dataHandlers.removeValue(forKey: profileId)
    }
    profileGRDBRepositories[profileId] = bundle
  }

  /// Removes the per-profile GRDB repository bundle (e.g. on session
  /// teardown so the database queue it captures can be released).
  func removeProfileGRDBRepositories(profileId: UUID) {
    profileGRDBRepositories.removeValue(forKey: profileId)
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
}
