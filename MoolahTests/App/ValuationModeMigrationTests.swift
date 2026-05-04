import Foundation
import Testing

@testable import Moolah

@MainActor
@Suite("ValuationModeMigration")
struct ValuationModeMigrationTests {
  /// Bundle of references each test needs from `makeFixture`.
  private struct Fixture {
    let backend: CloudKitBackend
    let defaults: UserDefaults
    let migration: ValuationModeMigration
  }

  /// Builds a fresh in-memory backend and migration with a unique
  /// `UserDefaults` suite per test so gate flags don't bleed between tests.
  private func makeFixture(
    profileId: UUID = UUID()
  ) throws -> Fixture {
    let suiteName = "test-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)
    let (backend, _) = try TestBackend.create()
    let migration = ValuationModeMigration(
      profileId: profileId,
      accountRepository: backend.accounts,
      investmentRepository: backend.investments,
      userDefaults: defaults)
    return Fixture(backend: backend, defaults: defaults, migration: migration)
  }

  @Test("investment account with snapshot stays at recordedValue")
  func snapshotAccountUntouched() async throws {
    let fixture = try makeFixture()
    let saved = try await fixture.backend.accounts.create(
      Account(name: "Brokerage", type: .investment, instrument: .AUD))
    try await fixture.backend.investments.setValue(
      accountId: saved.id, date: Date(),
      value: InstrumentAmount(quantity: 100, instrument: .AUD))

    try await fixture.migration.run()

    let allAccounts = try await fixture.backend.accounts.fetchAll()
    let after = try #require(allAccounts.first { $0.id == saved.id })
    #expect(after.valuationMode == .recordedValue)
  }

  @Test("investment account without snapshot flips to calculatedFromTrades")
  func emptyAccountFlips() async throws {
    let fixture = try makeFixture()
    let saved = try await fixture.backend.accounts.create(
      Account(name: "Crypto", type: .investment, instrument: .AUD))

    try await fixture.migration.run()

    let allAccounts = try await fixture.backend.accounts.fetchAll()
    let after = try #require(allAccounts.first { $0.id == saved.id })
    #expect(after.valuationMode == .calculatedFromTrades)
  }

  @Test("non-investment account is left alone")
  func nonInvestmentSkipped() async throws {
    let fixture = try makeFixture()
    let saved = try await fixture.backend.accounts.create(
      Account(name: "Checking", type: .bank, instrument: .AUD))

    try await fixture.migration.run()

    let allAccounts = try await fixture.backend.accounts.fetchAll()
    let after = try #require(allAccounts.first { $0.id == saved.id })
    #expect(after.valuationMode == .recordedValue)
  }

  @Test("re-running with the gate flag set is a no-op")
  func gateFlagShortCircuits() async throws {
    let fixture = try makeFixture()
    _ = try await fixture.backend.accounts.create(
      Account(name: "Brokerage", type: .investment, instrument: .AUD))
    try await fixture.migration.run()
    #expect(
      fixture.defaults.bool(
        forKey: "didMigrateValuationMode_\(fixture.migration.profileId)"))

    // Pre-flip an account to recordedValue; re-running must not flip it back.
    let allAccounts = try await fixture.backend.accounts.fetchAll()
    var account = allAccounts[0]
    account.valuationMode = .recordedValue
    _ = try await fixture.backend.accounts.update(account)

    try await fixture.migration.run()
    let after = (try await fixture.backend.accounts.fetchAll())[0]
    #expect(after.valuationMode == .recordedValue)
  }

  @Test("per-profile gate flags are independent")
  func perProfileGateIsolation() async throws {
    let fixture = try makeFixture()
    let migrationA = fixture.migration
    let migrationB = ValuationModeMigration(
      profileId: UUID(),
      accountRepository: migrationA.accountRepository,
      investmentRepository: migrationA.investmentRepository,
      userDefaults: fixture.defaults)

    try await migrationA.run()
    #expect(
      fixture.defaults.bool(
        forKey: "didMigrateValuationMode_\(migrationA.profileId)"))
    #expect(
      !fixture.defaults.bool(
        forKey: "didMigrateValuationMode_\(migrationB.profileId)"))
  }
}
