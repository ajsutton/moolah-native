@preconcurrency import CloudKit
import Foundation
import OSLog
import Observation
import SwiftData

// `MigrationProfileNaming` lives in `MigrationProfileNaming.swift`.

@Observable
@MainActor
final class MigrationCoordinator {
  enum State: Sendable {
    case idle
    case exporting(step: String)
    case importing(step: String, progress: Double)
    case verifying
    case succeeded(
      ImportResult, newProfileId: UUID, balanceWarnings: [VerificationResult.BalanceMismatch])
    case verificationFailed(VerificationResult, newProfileId: UUID)
    case failed(MigrationError)
  }

  private(set) var state: State = .idle

  /// Record IDs queued with the sync coordinator by the most recent successful
  /// `migrate(...)` call. Empty if no sync coordinator was provided, the migration
  /// failed, or the profile had no records to queue. Exposed for test verification.
  private(set) var lastRecordIDsQueuedForUpload: [CKRecord.ID] = []

  private let logger = Logger(subsystem: "com.moolah.app", category: "Migration")

  /// Migrates data from a remote profile to a new iCloud profile.
  ///
  /// - Parameters:
  ///   - sourceProfile: The remote profile to migrate from
  ///   - backend: The backend for the source profile (provides repositories)
  ///   - containerManager: The per-profile container manager used to create the target store
  ///   - profileStore: The profile store for creating the new profile and renaming the old one
  ///   - syncCoordinator: Optional sync coordinator. When provided, the newly-imported
  ///     profile's zone is created on CloudKit and every imported record is queued for
  ///     upload so other devices receive the migrated data. Pass `nil` for tests that
  ///     don't exercise sync.
  func migrate(
    sourceProfile: Profile,
    from backend: any BackendProvider,
    to containerManager: ProfileContainerManager,
    profileStore: ProfileStore,
    syncCoordinator: SyncCoordinator? = nil
  ) async {
    state = .exporting(step: "Starting...")
    lastRecordIDsQueuedForUpload = []

    do {
      let exported = try await exportForMigration(
        sourceProfile: sourceProfile, backend: backend)
      let (sourceLabel, newProfile) = addNewMigrationProfile(
        sourceProfile: sourceProfile, profileStore: profileStore)

      let imported = try await performMigrationImport(
        exported: exported,
        sourceProfile: sourceProfile,
        newProfile: newProfile,
        containerManager: containerManager,
        profileStore: profileStore)

      let verification = try await verifyMigration(
        exported: exported, container: imported.container)

      if !verification.countMatch {
        // Mark the new profile as incomplete so the user knows it needs review.
        var incompleteProfile = newProfile
        incompleteProfile.label = "\(sourceProfile.label) (Incomplete)"
        profileStore.updateProfile(incompleteProfile)
        state = .verificationFailed(verification, newProfileId: newProfile.id)
        return
      }

      // Rename the source profile to indicate it is the remote copy, then
      // switch to the new iCloud profile.
      var updatedSource = sourceProfile
      updatedSource.label = sourceLabel
      profileStore.updateProfile(updatedSource)
      profileStore.setActiveProfile(newProfile.id)

      await queueImportedRecordsForUpload(
        newProfileId: newProfile.id, syncCoordinator: syncCoordinator)

      state = .succeeded(
        imported.result,
        newProfileId: newProfile.id,
        balanceWarnings: verification.balanceMismatches)
    } catch {
      state = .failed(error as? MigrationError ?? .unexpected(error))
    }
  }

  /// Step 1: export every record from the source backend.
  private func exportForMigration(
    sourceProfile: Profile, backend: any BackendProvider
  ) async throws -> ExportedData {
    let exporter = DataExporter(backend: backend)
    return try await exporter.export(
      profileLabel: sourceProfile.label,
      currencyCode: sourceProfile.currencyCode,
      financialYearStartMonth: sourceProfile.financialYearStartMonth
    ) { [weak self] progress in
      Task { @MainActor in
        switch progress {
        case .downloading(let step):
          self?.state = .exporting(step: step)
        default: break
        }
      }
    }
  }

  /// Step 2: compute the new profile label, register it with the profile
  /// store, and return both the chosen source rename and the fresh profile.
  /// Excludes the source profile from the existing-labels set since it's
  /// about to be renamed in place.
  private func addNewMigrationProfile(
    sourceProfile: Profile, profileStore: ProfileStore
  ) -> (sourceLabel: String, newProfile: Profile) {
    let existingLabels = profileStore.profiles
      .filter { $0.id != sourceProfile.id }
      .map(\.label)
    let (sourceLabel, targetLabel) = MigrationProfileNaming.migratedLabels(
      sourceLabel: sourceProfile.label,
      existingLabels: existingLabels
    )
    let newProfile = Profile(
      id: UUID(),
      label: targetLabel,
      backendType: .cloudKit,
      currencyCode: sourceProfile.currencyCode,
      financialYearStartMonth: sourceProfile.financialYearStartMonth
    )
    profileStore.addProfile(newProfile)
    return (sourceLabel, newProfile)
  }

  private struct MigrationImportOutput {
    let container: ModelContainer
    let result: ImportResult
  }

  /// Step 3: import the exported data into the new profile's container.
  /// Cleans up the partially-created profile on failure.
  private func performMigrationImport(
    exported: ExportedData,
    sourceProfile: Profile,
    newProfile: Profile,
    containerManager: ProfileContainerManager,
    profileStore: ProfileStore
  ) async throws -> MigrationImportOutput {
    state = .importing(step: "starting", progress: 0)
    let profileContainer = try containerManager.container(for: newProfile.id)
    let importer = CloudKitDataImporter(
      modelContainer: profileContainer,
      currencyCode: sourceProfile.currencyCode
    )
    do {
      let result = try await importer.importData(exported) { [weak self] step, progress in
        self?.state = .importing(step: step, progress: progress)
      }
      return MigrationImportOutput(container: profileContainer, result: result)
    } catch {
      profileStore.removeProfile(newProfile.id)
      containerManager.deleteStore(for: newProfile.id)
      throw error
    }
  }

  /// Step 4: verify the imported data. Logs the result and returns it to
  /// the caller for the mismatch branch.
  private func verifyMigration(
    exported: ExportedData, container: ModelContainer
  ) async throws -> VerificationResult {
    state = .verifying
    let verifier = MigrationVerifier()
    let verification = try await verifier.verify(
      exported: exported, modelContainer: container)
    logVerification(verification)
    return verification
  }

  private func logVerification(_ verification: VerificationResult) {
    logger.info(
      "Verification: counts match=\(verification.countMatch) accounts=\(verification.actualCounts.accounts)/\(verification.expectedCounts.accounts) categories=\(verification.actualCounts.categories)/\(verification.expectedCounts.categories) earmarks=\(verification.actualCounts.earmarks)/\(verification.expectedCounts.earmarks) transactions=\(verification.actualCounts.transactions)/\(verification.expectedCounts.transactions) investmentValues=\(verification.actualCounts.investmentValues)/\(verification.expectedCounts.investmentValues)"
    )
    for mismatch in verification.balanceMismatches {
      logger.info(
        "Balance mismatch: \(mismatch.accountName) server=\(mismatch.serverBalance) computed=\(mismatch.localBalance) diff=\(mismatch.serverBalance - mismatch.localBalance)"
      )
    }
  }

  /// Step 7: queue the imported records with the sync coordinator so they
  /// upload to CloudKit and propagate to other devices.
  /// `CloudKitDataImporter` writes records directly to SwiftData and so
  /// bypasses the repository `onRecordChanged` hooks — without this step
  /// the new profile's data would only ever exist on the device that
  /// performed the migration.
  private func queueImportedRecordsForUpload(
    newProfileId: UUID, syncCoordinator: SyncCoordinator?
  ) async {
    guard let syncCoordinator else { return }
    let queued = await syncCoordinator.queueAllRecordsAfterImport(for: newProfileId)
    lastRecordIDsQueuedForUpload = queued
    if !queued.isEmpty {
      await syncCoordinator.sendChanges()
    }
  }

  /// Exports all data from a profile to a JSON file.
  ///
  /// - Parameters:
  ///   - url: The file URL to write the exported JSON to
  ///   - backend: The backend for the profile (provides repositories)
  ///   - profile: The profile to export
  ///   - progress: Optional callback fired on `@MainActor` with a stage name
  ///     (`accounts`, `categories`, `earmarks`, `transactions`,
  ///     `investment values`, `encoding`, `writing`) so the UI can render a
  ///     progress indicator (see issue #359). The download stages are forwarded
  ///     from `DataExporter`; `encoding` and `writing` are emitted around the
  ///     JSON serialisation and atomic file write that run inside this
  ///     method.
  func exportToFile(
    url: URL,
    backend: any BackendProvider,
    profile: Profile,
    progress: @escaping @MainActor (String) -> Void = { _ in }
  ) async throws {
    state = .exporting(step: "Starting...")
    progress("starting")

    let exporter = DataExporter(backend: backend)
    let exported = try await exporter.export(
      profileLabel: profile.label,
      currencyCode: profile.currencyCode,
      financialYearStartMonth: profile.financialYearStartMonth
    ) { [weak self] exportProgress in
      Task { @MainActor in
        switch exportProgress {
        case .downloading(let step):
          self?.state = .exporting(step: step)
          progress(step)
        default: break
        }
      }
    }

    state = .exporting(step: "encoding")
    progress("encoding")
    let data = try JSONEncoder.exportEncoder.encode(exported)

    state = .exporting(step: "writing")
    progress("writing")
    try data.write(to: url, options: .atomic)

    state = .idle
  }

  /// Imports data from a JSON file into a SwiftData container.
  ///
  /// - Parameters:
  ///   - url: The file URL to read the exported JSON from
  ///   - modelContainer: The target container to import data into
  ///   - profileId: The UUID of the new profile that owns `modelContainer`. Required
  ///     when `syncCoordinator` is non-nil so imported records can be queued for upload.
  ///   - syncCoordinator: Optional sync coordinator. When provided, all imported records
  ///     are queued for upload so the profile syncs to CloudKit and other devices.
  /// - Returns: The import result with counts of imported records
  func importFromFile(
    url: URL,
    modelContainer: ModelContainer,
    profileId: UUID? = nil,
    syncCoordinator: SyncCoordinator? = nil
  ) async throws -> ImportResult {
    state = .importing(step: "reading file", progress: 0)

    let jsonData: Data
    do {
      jsonData = try Data(contentsOf: url)
    } catch {
      throw MigrationError.fileReadFailed(url, underlying: error)
    }

    let exported: ExportedData
    do {
      exported = try JSONDecoder.exportDecoder.decode(ExportedData.self, from: jsonData)
    } catch {
      throw MigrationError.importFailed(underlying: error)
    }

    guard exported.version <= 1 else {
      throw MigrationError.unsupportedVersion(exported.version)
    }

    state = .importing(step: "saving", progress: 0.3)

    let importer = CloudKitDataImporter(
      modelContainer: modelContainer,
      currencyCode: exported.currencyCode
    )

    let result: ImportResult
    do {
      result = try await importer.importData(exported)
    } catch {
      throw MigrationError.importFailed(underlying: error)
    }

    state = .verifying
    let verifier = MigrationVerifier()
    let verification = try await verifier.verify(
      exported: exported,
      modelContainer: modelContainer
    )

    if !verification.countMatch {
      state = .idle
      throw MigrationError.verificationFailed(verification)
    }

    // Queue every imported record for upload so the new profile actually syncs to
    // CloudKit. Without this the container has data but CKSyncEngine never hears
    // about it — the profile would be iCloud-backed in name only.
    if let syncCoordinator, let profileId {
      let queued = await syncCoordinator.queueAllRecordsAfterImport(for: profileId)
      lastRecordIDsQueuedForUpload = queued
      if !queued.isEmpty {
        await syncCoordinator.sendChanges()
      }
    }

    state = .idle
    return result
  }

  /// Deletes a failed migration's profile and resets state.
  func deleteFailedMigration(
    profileId: UUID,
    profileStore: ProfileStore,
    containerManager: ProfileContainerManager
  ) {
    profileStore.removeProfile(profileId)
    containerManager.deleteStore(for: profileId)
    state = .idle
  }
}
