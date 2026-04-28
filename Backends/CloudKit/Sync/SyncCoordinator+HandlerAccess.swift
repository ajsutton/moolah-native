@preconcurrency import CloudKit
import Foundation
import GRDB
import OSLog

extension SyncCoordinator {
  // MARK: - Handler Access

  /// Returns (or creates) a `ProfileDataSyncHandler` for the given profile zone.
  ///
  /// A GRDB repository bundle MUST have been registered via
  /// `setProfileGRDBRepositories(profileId:bundle:)` before this is
  /// called for the profile — production wiring guarantees this in
  /// `ProfileSession.registerWithSyncCoordinator`. If no bundle is
  /// registered, the fallback path runs only in test builds (detected
  /// via `NSClassFromString("XCTestCase") != nil`) so SyncCoordinator
  /// unit tests can drive the handler without standing up a full
  /// `ProfileSession`. In a non-test build, a missing bundle is a
  /// production data-loss hazard (writes would land in an in-memory DB
  /// nobody else reads), so we trap loudly via `preconditionFailure`
  /// instead of silently constructing one.
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

  /// Builds an empty in-memory GRDB repository bundle for SyncCoordinator
  /// unit tests that don't supply a real one. **Production must never
  /// reach this path** — the empty in-memory queue would silently swallow
  /// every GRDB write driven by the data handler. We `preconditionFailure`
  /// when running outside an XCTest host so a missing
  /// `setProfileGRDBRepositories` call surfaces as a hard crash in
  /// development rather than silent data loss in shipping builds.
  private func makeFallbackGRDBRepositories(
    profileId: UUID
  ) throws -> ProfileGRDBRepositories {
    let isRunningTests = NSClassFromString("XCTestCase") != nil
    if !isRunningTests {
      preconditionFailure(
        """
        SyncCoordinator.handlerForProfileZone called for profile \
        \(profileId.uuidString) without a registered GRDB repository \
        bundle. This is a wiring bug — \
        ProfileSession.registerWithSyncCoordinator must call \
        setProfileGRDBRepositories(profileId:bundle:) before any sync \
        event for this profile. Falling back to an empty in-memory \
        bundle in production would silently swallow GRDB writes.
        """)
    }
    Logger(subsystem: "com.moolah.app", category: "SyncCoordinator").warning(
      """
      No GRDB repository bundle registered for profile \
      \(profileId, privacy: .public); using empty in-memory fallback. \
      Test-only path — production traps via preconditionFailure.
      """)
    let database = try ProfileDatabase.openInMemory()
    return ProfileGRDBRepositories(
      csvImportProfiles: GRDBCSVImportProfileRepository(database: database),
      importRules: GRDBImportRuleRepository(database: database))
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
