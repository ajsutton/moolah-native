import Foundation
import OSLog

/// One-shot per-profile migration that derives each investment
/// account's initial `valuationMode` from snapshot presence.
///
/// Runs on first launch after upgrade, gated by a per-profile
/// `UserDefaults` flag. Re-running with the flag already set is a
/// no-op. See `plans/2026-05-04-per-account-valuation-mode-design.md`
/// §4 for the algorithm and §Migration & Rollout for ordering.
@MainActor
struct ValuationModeMigration {
  let profileId: UUID
  let accountRepository: any AccountRepository
  let userDefaults: UserDefaults

  /// Stable symbol exposed so the UI-test reset path
  /// (`SwiftDataToGRDBMigrator.resetMigrationFlags`) can clear the
  /// per-profile gate flag without duplicating the format string.
  static func gateKey(for profileId: UUID) -> String {
    "didMigrateValuationMode_\(profileId)"
  }

  /// Common prefix shared by every per-profile gate key. Used by
  /// `resetGateFlags(in:)` to enumerate all keys this migration owns
  /// in `UserDefaults` without needing each profile id up front.
  static let gateKeyPrefix = "didMigrateValuationMode_"

  /// Wipes every per-profile gate key under `gateKeyPrefix` from the
  /// passed-in `UserDefaults`. Intended for `--ui-testing` launches
  /// only — each UI test launches a fresh in-memory profile container
  /// with new ids, so leftover keys from prior launches must not
  /// short-circuit the migration. No production code path should
  /// invoke this.
  static func resetGateFlags(in defaults: UserDefaults) {
    for key in defaults.dictionaryRepresentation().keys
    where key.hasPrefix(gateKeyPrefix) {
      defaults.removeObject(forKey: key)
    }
  }

  private static let logger = Logger(
    subsystem: "com.moolah.app", category: "ValuationModeMigration")

  private var gateKey: String { Self.gateKey(for: profileId) }

  func run() async throws {
    if userDefaults.bool(forKey: gateKey) { return }
    guard !Task.isCancelled else { return }
    let count =
      try await accountRepository
      .backfillValuationModeForUnsnapshotInvestmentAccounts()
    Self.logger.info(
      "Migrated \(count, privacy: .public) account(s) → calculatedFromTrades")
    guard !Task.isCancelled else { return }
    userDefaults.set(true, forKey: gateKey)
  }
}
