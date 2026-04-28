@preconcurrency import CloudKit
import Foundation
import GRDB
import OSLog

extension SyncCoordinator {
  // MARK: - Handler Access

  /// Returns (or creates) a `ProfileDataSyncHandler` for the given profile zone.
  ///
  /// When no GRDB repository bundle has been registered via
  /// `setProfileGRDBRepositories(profileId:bundle:)`, a fallback bundle
  /// is created on the fly with a fresh in-memory `DatabaseQueue`. The
  /// fallback isolates the handler so the GRDB record types don't bleed
  /// across profiles, but it has none of the rows the production bundle
  /// would have — appropriate for SyncCoordinator unit tests that don't
  /// exercise the GRDB-backed record types. Production registers the
  /// real bundle in `ProfileSession.registerWithSyncCoordinator` before
  /// any sync event arrives, so this fallback path is never taken in
  /// app builds.
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
    } else {
      grdbRepositories = try makeFallbackGRDBRepositories(profileId: profileId)
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

  /// Builds an empty in-memory GRDB repository bundle for tests that
  /// don't supply a real one. Logged at warning level so production
  /// uses (where this path indicates a wiring bug in
  /// `ProfileSession.registerWithSyncCoordinator`) leave a breadcrumb.
  private func makeFallbackGRDBRepositories(
    profileId: UUID
  ) throws -> ProfileGRDBRepositories {
    Logger(subsystem: "com.moolah.app", category: "SyncCoordinator").warning(
      """
      No GRDB repository bundle registered for profile \
      \(profileId, privacy: .public); using empty in-memory fallback. \
      This is expected only in unit tests that drive SyncCoordinator \
      without standing up a ProfileSession.
      """)
    let database = try ProfileDatabase.openInMemory()
    return ProfileGRDBRepositories(
      csvImportProfiles: GRDBCSVImportProfileRepository(database: database),
      importRules: GRDBImportRuleRepository(database: database))
  }

  /// Registers the GRDB repository bundle for a profile. Must be called
  /// before the first sync event arrives for the profile so
  /// `handlerForProfileZone` can construct a handler.
  func setProfileGRDBRepositories(
    profileId: UUID, bundle: ProfileGRDBRepositories
  ) {
    if dataHandlers[profileId] != nil {
      logger.warning(
        """
        GRDB repository bundle registered for profile \(profileId, privacy: .public) \
        after handler was cached; the handler retains its original bundle until the \
        cached entry is cleared
        """
      )
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
