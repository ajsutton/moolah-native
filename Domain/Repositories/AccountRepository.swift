import Foundation

protocol AccountRepository: Sendable {
  func fetchAll() async throws -> [Account]
  func create(_ account: Account, openingBalance: InstrumentAmount?) async throws -> Account
  func update(_ account: Account) async throws -> Account
  func delete(id: UUID) async throws
  /// Sets every investment account that has no `InvestmentValue`
  /// snapshot to `valuationMode = .calculatedFromTrades`. Single SQL
  /// UPDATE in one transaction; idempotent — re-running is a no-op once
  /// every empty investment account has been flipped because the row
  /// matches its target value. Returns the number of rows changed.
  ///
  /// Used by `ValuationModeMigration` so the per-profile bootstrap
  /// happens in one transaction / one fsync rather than per-account.
  func backfillValuationModeForUnsnapshotInvestmentAccounts() async throws -> Int
}

extension AccountRepository {
  func create(_ account: Account) async throws -> Account {
    try await create(account, openingBalance: nil)
  }
}
