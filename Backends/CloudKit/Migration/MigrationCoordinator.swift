@preconcurrency import CloudKit
import Foundation
import OSLog
import Observation
import SwiftData

// MARK: - Migration Profile Naming

/// Pure naming logic for migration: determines labels for source (Remote) and target (iCloud) profiles.
enum MigrationProfileNaming {
  private static let remoteSuffix = " (Remote)"
  private static let iCloudSuffix = " (iCloud)"

  /// Label for the original remote profile: appends "(Remote)" unless it already has it
  /// (possibly with a dedup number like "(Remote) 2").
  static func sourceLabel(for label: String) -> String {
    if label.hasSuffix(remoteSuffix) {
      return label
    }
    // Check for deduplicated remote names like "Foo (Remote) 2"
    if let range = label.range(of: remoteSuffix, options: .backwards) {
      let remainder = label[range.upperBound...]
      if remainder.isEmpty || Int(remainder.trimmingCharacters(in: .whitespaces)) != nil {
        return label
      }
    }
    return label + remoteSuffix
  }

  /// Label for the new iCloud profile: replaces trailing "(Remote)" with "(iCloud)", or appends "(iCloud)".
  static func targetLabel(for label: String) -> String {
    if label.hasSuffix(remoteSuffix) {
      return String(label.dropLast(remoteSuffix.count)) + iCloudSuffix
    }
    if label.hasSuffix(iCloudSuffix) {
      return label
    }
    return label + iCloudSuffix
  }

  /// Returns `name` if it is not in `existingLabels`, otherwise appends " 2", " 3", etc.
  static func uniqueName(_ name: String, among existingLabels: [String]) -> String {
    let existing = Set(existingLabels)
    if !existing.contains(name) { return name }
    var counter = 2
    while existing.contains("\(name) \(counter)") {
      counter += 1
    }
    return "\(name) \(counter)"
  }

  /// Returns `(sourceLabel, targetLabel)` with deduplication against existing profile labels.
  static func migratedLabels(
    sourceLabel: String,
    existingLabels: [String]
  ) -> (source: String, target: String) {
    let rawSource = self.sourceLabel(for: sourceLabel)
    let rawTarget = self.targetLabel(for: sourceLabel)

    let dedupedTarget = uniqueName(rawTarget, among: existingLabels)
    // For source dedup, also exclude the original sourceLabel since it will be renamed
    let dedupedSource = uniqueName(rawSource, among: existingLabels)

    return (dedupedSource, dedupedTarget)
  }
}

// MARK: - Migration Coordinator

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
      // 1. Export all data from the source backend
      let exporter = DataExporter(backend: backend)
      let exported = try await exporter.export(
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

      // 2. Create a new iCloud profile with migration naming
      // Exclude the source profile from existing labels since it will be renamed in place
      let existingLabels = profileStore.profiles
        .filter { $0.id != sourceProfile.id }
        .map(\.label)
      let (sourceLabel, targetLabel) = MigrationProfileNaming.migratedLabels(
        sourceLabel: sourceProfile.label,
        existingLabels: existingLabels
      )
      let newProfileId = UUID()
      let newProfile = Profile(
        id: newProfileId,
        label: targetLabel,
        backendType: .cloudKit,
        currencyCode: sourceProfile.currencyCode,
        financialYearStartMonth: sourceProfile.financialYearStartMonth
      )
      profileStore.addProfile(newProfile)

      // 3. Import data into the new profile
      state = .importing(step: "starting", progress: 0)
      let profileContainer = try containerManager.container(for: newProfileId)
      let importer = CloudKitDataImporter(
        modelContainer: profileContainer,
        currencyCode: sourceProfile.currencyCode
      )
      let result: ImportResult
      do {
        result = try await importer.importData(exported) { [weak self] step, progress in
          self?.state = .importing(step: step, progress: progress)
        }
      } catch {
        // Import failed — clean up the partially created profile
        profileStore.removeProfile(newProfileId)
        containerManager.deleteStore(for: newProfileId)
        throw error
      }

      // 4. Verify imported data
      state = .verifying
      let verifier = MigrationVerifier()
      let verification = try await verifier.verify(
        exported: exported,
        modelContainer: profileContainer
      )

      // Log verification results
      logger.info(
        "Verification: counts match=\(verification.countMatch) accounts=\(verification.actualCounts.accounts)/\(verification.expectedCounts.accounts) categories=\(verification.actualCounts.categories)/\(verification.expectedCounts.categories) earmarks=\(verification.actualCounts.earmarks)/\(verification.expectedCounts.earmarks) transactions=\(verification.actualCounts.transactions)/\(verification.expectedCounts.transactions) investmentValues=\(verification.actualCounts.investmentValues)/\(verification.expectedCounts.investmentValues)"
      )
      for mismatch in verification.balanceMismatches {
        logger.info(
          "Balance mismatch: \(mismatch.accountName) server=\(mismatch.serverBalance) computed=\(mismatch.localBalance) diff=\(mismatch.serverBalance - mismatch.localBalance)"
        )
      }

      if !verification.countMatch {
        // Mark the new profile as incomplete so the user knows it needs review
        var incompleteProfile = newProfile
        incompleteProfile.label = "\(sourceProfile.label) (Incomplete)"
        profileStore.updateProfile(incompleteProfile)
        state = .verificationFailed(verification, newProfileId: newProfileId)
        return
      }

      // 5. Rename the source profile to indicate it is the remote copy
      var updatedSource = sourceProfile
      updatedSource.label = sourceLabel
      profileStore.updateProfile(updatedSource)

      // 6. Switch to the new iCloud profile
      profileStore.setActiveProfile(newProfileId)

      // 7. Queue the imported records with the sync coordinator so they upload to
      // CloudKit and propagate to other devices. `CloudKitDataImporter` writes records
      // directly to SwiftData and so bypasses the repository `onRecordChanged` hooks —
      // without this step the new profile's data would only ever exist on the device
      // that performed the migration.
      if let syncCoordinator {
        let queued = await syncCoordinator.queueAllRecordsAfterImport(for: newProfileId)
        lastRecordIDsQueuedForUpload = queued
        if !queued.isEmpty {
          await syncCoordinator.sendChanges()
        }
      }

      state = .succeeded(
        result, newProfileId: newProfileId, balanceWarnings: verification.balanceMismatches)

    } catch {
      state = .failed(error as? MigrationError ?? .unexpected(error))
    }
  }

  /// Exports all data from a profile to a JSON file.
  ///
  /// - Parameters:
  ///   - url: The file URL to write the exported JSON to
  ///   - backend: The backend for the profile (provides repositories)
  ///   - profile: The profile to export
  func exportToFile(
    url: URL,
    backend: any BackendProvider,
    profile: Profile
  ) async throws {
    state = .exporting(step: "Starting...")

    let exporter = DataExporter(backend: backend)
    let exported = try await exporter.export(
      profileLabel: profile.label,
      currencyCode: profile.currencyCode,
      financialYearStartMonth: profile.financialYearStartMonth
    ) { [weak self] progress in
      Task { @MainActor in
        switch progress {
        case .downloading(let step):
          self?.state = .exporting(step: step)
        default: break
        }
      }
    }

    let data = try JSONEncoder.exportEncoder.encode(exported)
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
