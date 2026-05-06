import Foundation
import OSLog

/// Local logger for the valuation-mode migration extension. Scoped to
/// the extension file so the helper does not need access to
/// `ProfileSession`'s private `logger`. Same subsystem / category for
/// log-stream continuity.
private let valuationMigrationLogger = Logger(
  subsystem: "com.moolah.app", category: "ProfileSession")

// `ValuationModeMigration` per-profile bootstrap. Lives here rather
// than in the main `ProfileSession` body so the latter stays under
// SwiftLint's `file_length` threshold. The migration itself is
// non-fatal — auto-detect read sites are still in place at this
// rollout stage, so a thrown error gets logged but never surfaces to
// the caller.
extension ProfileSession {
  /// Runs `ValuationModeMigration` for this profile. Called from
  /// `setUp()` after the SwiftData → GRDB migration so the account /
  /// investment-value rows are visible to GRDB-backed repositories.
  /// Module-internal so `setUp()` (which lives on the main session
  /// type) can call it without bouncing through a closure.
  func runValuationModeMigration() async {
    let migration = ValuationModeMigration(
      profileId: profile.id,
      accountRepository: backend.accounts,
      userDefaults: .standard)
    do {
      try await migration.run()
    } catch {
      valuationMigrationLogger.error(
        "ValuationModeMigration failed: \(error.localizedDescription, privacy: .public)")
    }
  }
}
