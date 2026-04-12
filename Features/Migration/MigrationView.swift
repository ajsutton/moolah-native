import SwiftUI

/// Migration sheet UI presented when the user taps "Migrate to iCloud" in profile settings.
struct MigrationView: View {
  let sourceProfile: Profile
  let backend: any BackendProvider

  @Environment(ProfileStore.self) private var profileStore
  @Environment(ProfileContainerManager.self) private var containerManager
  @Environment(\.dismiss) private var dismiss
  #if os(macOS)
    @Environment(\.openWindow) private var openWindow
  #endif
  @State private var coordinator = MigrationCoordinator()

  var body: some View {
    VStack(spacing: 24) {
      switch coordinator.state {
      case .idle:
        migrationPrompt
      case .exporting(let step):
        progressState(title: "Downloading \(step)...")
      case .importing(let step, let progress):
        progressState(title: "Importing \(step)...", progress: progress)
      case .verifying:
        progressState(title: "Verifying data integrity...")
      case .succeeded(let result, let newProfileId, let balanceWarnings):
        migrationSuccess(result, newProfileId: newProfileId, balanceWarnings: balanceWarnings)
      case .verificationFailed(let verification, let newProfileId):
        verificationFailure(verification, newProfileId: newProfileId)
      case .failed(let error):
        migrationFailure(error)
      }
    }
    .padding(32)
    .frame(minWidth: 400, minHeight: 300)
    .interactiveDismissDisabled(!isIdle && !isComplete)
  }

  // MARK: - Idle / Prompt

  private var migrationPrompt: some View {
    VStack(spacing: 16) {
      Image(systemName: "icloud.and.arrow.up")
        .font(.system(size: 48))
        .foregroundStyle(.tint)
        .accessibilityHidden(true)

      Text("Migrate to iCloud")
        .font(.title)

      Text(
        "This will create a new iCloud profile with a copy of all your data from \"\(sourceProfile.label)\". Your current profile will be kept with \"(Migrated)\" added to its name so you can compare and verify the data."
      )
      .multilineTextAlignment(.center)
      .foregroundStyle(.secondary)

      Button("Start Migration") {
        Task {
          await coordinator.migrate(
            sourceProfile: sourceProfile,
            from: backend,
            to: containerManager,
            profileStore: profileStore
          )
        }
      }
      .buttonStyle(.borderedProminent)
      .controlSize(.large)
    }
  }

  // MARK: - Progress

  private func progressState(title: String, progress: Double? = nil) -> some View {
    VStack(spacing: 16) {
      if let progress {
        ProgressView(value: progress) {
          Text(title)
        }
        .progressViewStyle(.linear)
      } else {
        ProgressView {
          Text(title)
        }
      }

      Text("Please don't close this window.")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  // MARK: - Success

  private func migrationSuccess(
    _ result: ImportResult,
    newProfileId: UUID,
    balanceWarnings: [VerificationResult.BalanceMismatch]
  ) -> some View {
    VStack(spacing: 16) {
      Image(systemName: "checkmark.circle.fill")
        .font(.system(size: 48))
        .foregroundStyle(.green)
        .accessibilityHidden(true)

      Text("Migration Complete")
        .font(.title)

      VStack(alignment: .leading, spacing: 4) {
        summaryRow("Accounts", count: result.accountCount)
        summaryRow("Categories", count: result.categoryCount)
        summaryRow("Earmarks", count: result.earmarkCount)
        summaryRow("Transactions", count: result.transactionCount)
        if result.investmentValueCount > 0 {
          summaryRow("Investment Values", count: result.investmentValueCount)
        }
        if result.budgetItemCount > 0 {
          summaryRow("Budget Items", count: result.budgetItemCount)
        }
      }
      .font(.body.monospacedDigit())

      if !balanceWarnings.isEmpty {
        DisclosureGroup("Balance differences (\(balanceWarnings.count) accounts)") {
          VStack(alignment: .leading, spacing: 4) {
            ForEach(balanceWarnings, id: \.accountName) { mismatch in
              VStack(alignment: .leading, spacing: 2) {
                Text(mismatch.accountName)
                  .font(.subheadline)
                Text(
                  "server: \(Self.formatCents(mismatch.serverBalance))  computed: \(Self.formatCents(mismatch.localBalance))  diff: \(Self.formatCents(mismatch.serverBalance - mismatch.localBalance))"
                )
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
              }
            }
          }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
      }

      Button("Done") {
        #if os(macOS)
          openWindow(value: newProfileId)
        #endif
        dismiss()
      }
      .buttonStyle(.borderedProminent)
      .controlSize(.large)
    }
  }

  private func summaryRow(_ label: String, count: Int) -> some View {
    HStack {
      Text(label)
        .foregroundStyle(.secondary)
      Spacer()
      Text("\(count)")
    }
  }

  // MARK: - Verification Failure

  private func verificationFailure(
    _ verification: VerificationResult,
    newProfileId: UUID
  ) -> some View {
    VStack(spacing: 16) {
      Image(systemName: "exclamationmark.triangle.fill")
        .font(.system(size: 48))
        .foregroundStyle(.yellow)
        .accessibilityHidden(true)

      Text("Verification Issue")
        .font(.title)

      Text(
        "The migrated data doesn't match the source. You can keep the new profile for review or delete it and retry."
      )
      .multilineTextAlignment(.center)
      .foregroundStyle(.secondary)

      ScrollView {
        VStack(alignment: .leading, spacing: 8) {
          Text("Record counts:")
            .font(.headline)
          countRow(
            "Accounts", expected: verification.expectedCounts.accounts,
            actual: verification.actualCounts.accounts)
          countRow(
            "Categories", expected: verification.expectedCounts.categories,
            actual: verification.actualCounts.categories)
          countRow(
            "Earmarks", expected: verification.expectedCounts.earmarks,
            actual: verification.actualCounts.earmarks)
          countRow(
            "Transactions", expected: verification.expectedCounts.transactions,
            actual: verification.actualCounts.transactions)
          countRow(
            "Investment Values", expected: verification.expectedCounts.investmentValues,
            actual: verification.actualCounts.investmentValues)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
      }
      .frame(maxHeight: 200)
      .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))

      HStack(spacing: 12) {
        Button("Delete and Retry") {
          coordinator.deleteFailedMigration(
            profileId: newProfileId,
            profileStore: profileStore,
            containerManager: containerManager
          )
        }
        .controlSize(.large)

        Button("Keep for Review") {
          dismiss()
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
      }
    }
  }

  // MARK: - Error

  private func migrationFailure(_ error: MigrationError) -> some View {
    VStack(spacing: 16) {
      Image(systemName: "xmark.circle.fill")
        .font(.system(size: 48))
        .foregroundStyle(.red)
        .accessibilityHidden(true)

      Text("Migration Failed")
        .font(.title)

      Text(error.localizedDescription)
        .multilineTextAlignment(.center)
        .foregroundStyle(.secondary)

      HStack(spacing: 12) {
        Button("Cancel") {
          dismiss()
        }
        .controlSize(.large)

        Button("Retry") {
          Task {
            await coordinator.migrate(
              sourceProfile: sourceProfile,
              from: backend,
              to: containerManager,
              profileStore: profileStore
            )
          }
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
      }
    }
  }

  // MARK: - State Helpers

  private func countRow(_ label: String, expected: Int, actual: Int) -> some View {
    HStack {
      Text(label)
      Spacer()
      if expected == actual {
        Text("\(actual)")
          .foregroundStyle(.secondary)
      } else {
        Text("expected \(expected), got \(actual)")
          .foregroundStyle(.red)
      }
    }
    .font(.caption.monospacedDigit())
  }

  private static func formatCents(_ cents: Int) -> String {
    let dollars = Double(cents) / 100.0
    return String(format: "%.2f", dollars)
  }

  private var isIdle: Bool {
    if case .idle = coordinator.state { return true }
    return false
  }

  private var isComplete: Bool {
    switch coordinator.state {
    case .succeeded, .verificationFailed, .failed:
      return true
    default:
      return false
    }
  }
}
