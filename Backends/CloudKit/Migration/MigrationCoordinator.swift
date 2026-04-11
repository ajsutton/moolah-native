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
    case succeeded(ImportResult, balanceWarnings: [VerificationResult.BalanceMismatch])
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
  ///   - modelContainer: The shared SwiftData model container
  ///   - profileStore: The profile store for creating the new profile and renaming the old one
  func migrate(
    sourceProfile: Profile,
    from backend: any BackendProvider,
    to modelContainer: ModelContainer,
    profileStore: ProfileStore
  ) async {
    state = .exporting(step: "Starting...")

    do {
      // 1. Export all data from the source backend
      let exporter = ServerDataExporter(
        accountRepo: backend.accounts,
        categoryRepo: backend.categories,
        earmarkRepo: backend.earmarks,
        transactionRepo: backend.transactions,
        investmentRepo: backend.investments
      )
      let exported = try await exporter.export { [weak self] progress in
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
      let importer = CloudKitDataImporter(
        modelContainer: modelContainer,
        profileId: newProfileId,
        currencyCode: sourceProfile.currencyCode
      )
      let result: ImportResult
      do {
        result = try await importer.importData(exported) {
          [weak self] (progress: CloudKitDataImporter.ImportProgress) in
          Task { @MainActor in
            if case .importing(let step, let current, let total) = progress {
              let pct = total > 0 ? Double(current) / Double(total) : 0
              self?.state = .importing(step: step, progress: pct)
            }
          }
        }
      } catch {
        // Import failed — clean up the partially created profile
        profileStore.removeProfile(newProfileId)
        throw error
      }

      // 4. Verify imported data
      state = .verifying
      let verifier = MigrationVerifier()
      let verification = try await verifier.verify(
        exported: exported,
        modelContainer: modelContainer,
        profileId: newProfileId
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

      state = .succeeded(result, balanceWarnings: verification.balanceMismatches)

    } catch {
      state = .failed(error as? MigrationError ?? .unexpected(error))
    }
  }

  /// Deletes a failed migration's profile and resets state.
  func deleteFailedMigration(profileId: UUID, profileStore: ProfileStore) {
    profileStore.removeProfile(profileId)
    state = .idle
  }
}
