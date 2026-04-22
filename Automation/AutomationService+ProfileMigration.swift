#if os(macOS)
  import Foundation
  import OSLog

  private let migrationLogger = Logger(
    subsystem: "com.moolah.app",
    category: "AutomationMigration"
  )

  extension AutomationService {
    /// Exports the given profile's data to a JSON file at `url`. Overwrites any
    /// existing file atomically.
    func exportProfile(profileIdentifier: String, to url: URL) async throws {
      let session = try resolveSession(for: profileIdentifier)
      migrationLogger.info(
        "Export: starting for profile \(session.profile.label, privacy: .public) to \(url.path, privacy: .public)"
      )
      do {
        let coordinator = MigrationCoordinator()
        try await coordinator.exportToFile(
          url: url,
          backend: session.backend,
          profile: session.profile
        )
        migrationLogger.info(
          "Export: complete — saved to \(url.path, privacy: .public)")
      } catch {
        migrationLogger.error(
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

      migrationLogger.info("Import: starting from \(url.path, privacy: .public)")

      let jsonData: Data
      let exported: ExportedData
      do {
        jsonData = try Data(contentsOf: url)
        exported = try JSONDecoder.exportDecoder.decode(ExportedData.self, from: jsonData)
      } catch {
        migrationLogger.error(
          "Import: failed to read file — \(error.localizedDescription, privacy: .public)")
        throw AutomationError.operationFailed(
          "Failed to read import file: \(error.localizedDescription)")
      }

      let newProfile = Profile(
        label: exported.profileLabel,
        backendType: .cloudKit,
        currencyCode: exported.currencyCode,
        financialYearStartMonth: exported.financialYearStartMonth
      )
      profileStore.addProfile(newProfile)

      do {
        let container = try containerManager.container(for: newProfile.id)
        let coordinator = MigrationCoordinator()
        _ = try await coordinator.importFromFile(
          url: url,
          modelContainer: container,
          profileId: newProfile.id,
          syncCoordinator: syncCoordinator
        )
        migrationLogger.info(
          "Import: complete — profile '\(newProfile.label, privacy: .public)'")
        return newProfile
      } catch {
        containerManager.deleteStore(for: newProfile.id)
        profileStore.removeProfile(newProfile.id)
        migrationLogger.error(
          "Import: failed — \(error.localizedDescription, privacy: .public)")
        throw AutomationError.operationFailed(error.localizedDescription)
      }
    }
  }
#endif
