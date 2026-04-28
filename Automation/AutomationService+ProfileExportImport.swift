#if os(macOS)
  import Foundation
  import OSLog

  private let exportImportLogger = Logger(
    subsystem: "com.moolah.app",
    category: "AutomationExportImport"
  )

  extension AutomationService {
    /// Exports the given profile's data to a JSON file at `url`. Overwrites any
    /// existing file atomically.
    func exportProfile(profileIdentifier: String, to url: URL) async throws {
      let session = try resolveSession(for: profileIdentifier)
      exportImportLogger.info(
        "Export: starting for profile \(session.profile.label, privacy: .public) to \(url.path, privacy: .public)"
      )
      do {
        let coordinator = ExportCoordinator()
        try await coordinator.exportToFile(
          url: url,
          backend: session.backend,
          profile: session.profile
        )
        exportImportLogger.info(
          "Export: complete — saved to \(url.path, privacy: .public)")
      } catch {
        exportImportLogger.error(
          "Export: failed — \(error.localizedDescription, privacy: .public)")
        throw AutomationError.operationFailed(error.localizedDescription)
      }
    }

    /// Imports a profile from the JSON file at `url`, creating a new cloud profile.
    /// The new profile is queued for CloudKit sync when a sync coordinator is configured.
    ///
    /// Production callers omit the trailing arguments; they default to the
    /// services registered via `ScriptingContext.configure(...)`. Tests pass
    /// explicit values so they do not touch global state.
    @discardableResult
    func importProfile(
      from url: URL,
      profileStore: ProfileStore? = ScriptingContext.profileStore,
      containerManager: ProfileContainerManager? = ScriptingContext.containerManager,
      syncCoordinator: SyncCoordinator? = ScriptingContext.syncCoordinator
    ) async throws -> Profile {
      guard let profileStore, let containerManager else {
        throw AutomationError.operationFailed(
          "Import requires a configured profile store and container manager")
      }

      exportImportLogger.info("Import: starting from \(url.path, privacy: .public)")

      let newProfileId: UUID
      do {
        let coordinator = ExportCoordinator()
        newProfileId = try await coordinator.importNewProfileFromFile(
          url: url,
          profileStore: profileStore,
          containerManager: containerManager,
          syncCoordinator: syncCoordinator
        )
      } catch {
        exportImportLogger.error(
          "Import: failed — \(error.localizedDescription, privacy: .public)")
        throw AutomationError.operationFailed(error.localizedDescription)
      }

      guard let newProfile = profileStore.profiles.first(where: { $0.id == newProfileId }) else {
        throw AutomationError.operationFailed("Imported profile not found after import")
      }
      exportImportLogger.info(
        "Import: complete — profile '\(newProfile.label, privacy: .public)'")
      return newProfile
    }
  }
#endif
