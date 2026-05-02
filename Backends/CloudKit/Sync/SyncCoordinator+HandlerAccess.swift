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
  /// A GRDB repository bundle MUST have been registered via
  /// `setProfileGRDBRepositories(profileId:bundle:)` before this is
  /// called for the profile — production wiring guarantees this in
  /// `ProfileSession.registerWithSyncCoordinator`. If no bundle is
  /// registered and no `fallbackGRDBRepositoriesFactory` was injected
  /// at coordinator init, the call throws
  /// `SyncCoordinatorError.profileNotRegistered`. Each caller decides
  /// what to do with that error: outbound paths skip + log (records
  /// stay in GRDB and are picked up on the next backfill scan); the
  /// inbound apply path traps via `preconditionFailure` because
  /// `CKSyncEngine` would otherwise advance the server change token
  /// past unapplied records.
  ///
  /// Constructing an empty in-memory bundle on the fly is never an
  /// option — it would silently swallow GRDB writes. Tests that drive
  /// paths reaching here without staging a bundle inject the factory
  /// at init time so the throw doesn't fire — see
  /// `SyncCoordinator.init(... fallbackGRDBRepositoriesFactory:)`.
  func handlerForProfileZone(
    profileId: UUID, zoneID: CKRecordZone.ID
  ) throws -> ProfileDataSyncHandler {
    if let existing = dataHandlers[profileId] {
      return existing
    }
    let container = try containerManager.container(for: profileId)
    let grdbRepositories: ProfileGRDBRepositories
    if let registered = profileGRDBRepositories[profileId] {
      grdbRepositories = registered
    } else if let factory = fallbackGRDBRepositoriesFactory {
      grdbRepositories = try factory(profileId)
      profileGRDBRepositories[profileId] = grdbRepositories
    } else {
      throw SyncCoordinatorError.profileNotRegistered(profileId)
    }
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
