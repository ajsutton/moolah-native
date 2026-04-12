import Foundation
import OSLog
import Observation
import SwiftData

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
  private let logger = Logger(subsystem: "com.moolah.app", category: "Migration")

  /// Migrates data from a remote profile to a new iCloud profile.
  ///
  /// - Parameters:
  ///   - sourceProfile: The remote profile to migrate from
  ///   - backend: The backend for the source profile (provides repositories)
  ///   - containerManager: The per-profile container manager used to create the target store
  ///   - profileStore: The profile store for creating the new profile and renaming the old one
  func migrate(
    sourceProfile: Profile,
    from backend: any BackendProvider,
    to containerManager: ProfileContainerManager,
    profileStore: ProfileStore
  ) async {
    state = .exporting(step: "Starting...")

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

      // 2. Create a new iCloud profile
      let newProfileId = UUID()
      let newProfile = Profile(
        id: newProfileId,
        label: sourceProfile.label,
        backendType: .cloudKit,
        currencyCode: sourceProfile.currencyCode,
        financialYearStartMonth: sourceProfile.financialYearStartMonth
      )
      profileStore.addProfile(newProfile)

      // 3. Import data into the new profile
      state = .importing(step: "saving", progress: 0)
      let profileContainer = try containerManager.container(for: newProfileId)
      let importer = CloudKitDataImporter(
        modelContainer: profileContainer,
        currencyCode: sourceProfile.currencyCode
      )
      let result: ImportResult
      do {
        result = try importer.importData(exported)
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

      // 5. Rename the source profile to indicate it has been migrated
      var updatedSource = sourceProfile
      updatedSource.label = "\(sourceProfile.label) (Migrated)"
      profileStore.updateProfile(updatedSource)

      // 6. Switch to the new iCloud profile
      profileStore.setActiveProfile(newProfileId)

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
  /// - Returns: The import result with counts of imported records
  func importFromFile(
    url: URL,
    modelContainer: ModelContainer
  ) async throws -> ImportResult {
    state = .importing(step: "reading file", progress: 0)

    let jsonData = try Data(contentsOf: url)
    let exported: ExportedData
    do {
      exported = try JSONDecoder.exportDecoder.decode(ExportedData.self, from: jsonData)
    } catch {
      throw MigrationError.importFailed(underlying: error)
    }

    state = .importing(step: "saving", progress: 0.3)

    let importer = CloudKitDataImporter(
      modelContainer: modelContainer,
      currencyCode: exported.currencyCode
    )

    let result: ImportResult
    do {
      result = try importer.importData(exported)
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
