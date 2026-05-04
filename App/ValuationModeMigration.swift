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
  let investmentRepository: any InvestmentRepository
  let userDefaults: UserDefaults

  private var gateKey: String { "didMigrateValuationMode_\(profileId)" }

  private var logger: Logger {
    Logger(subsystem: "com.moolah.app", category: "ValuationModeMigration")
  }

  func run() async throws {
    if userDefaults.bool(forKey: gateKey) { return }

    let accounts = try await accountRepository.fetchAll()
    for account in accounts where account.type == .investment {
      let page = try await investmentRepository.fetchValues(
        accountId: account.id, page: 0, pageSize: 1)
      if page.values.isEmpty {
        var updated = account
        updated.valuationMode = .calculatedFromTrades
        _ = try await accountRepository.update(updated)
        logger.info(
          "Migrated account \(account.name, privacy: .public) → calculatedFromTrades")
      }
      // else: snapshot exists → leave at .recordedValue (no-op write).
    }
    userDefaults.set(true, forKey: gateKey)
  }
}
