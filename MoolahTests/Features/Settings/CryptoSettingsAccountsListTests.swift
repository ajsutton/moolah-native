// MoolahTests/Features/Settings/CryptoSettingsAccountsListTests.swift
import Foundation
import GRDB
import SwiftUI
import Testing

@testable import Moolah

/// Behavioural tests for the Crypto Accounts list section. Per CLAUDE.md
/// the testable surface is the data — what `AccountStore.accounts`
/// exposes after a load, which entries the view filters in, and
/// whether `CryptoSyncStore.syncAccount(_:)` actually fires when the
/// "Sync now" button is tapped (the view is a thin shell that calls
/// straight through).
///
/// `CryptoSyncStore.syncAccount` is exercised against a `TestBackend`
/// fixture identical to the existing `CryptoSyncStoreTests` setup so
/// the behaviour we verify here is the same one that runs in
/// production.
@Suite("Crypto Accounts list — data behaviour")
@MainActor
struct CryptoSettingsAccountsListTests {
  nonisolated static let pinnedNow = Date(timeIntervalSince1970: 1_700_000_000)

  private struct Fixture {
    let syncStore: CryptoSyncStore
    let backend: CloudKitBackend
    let database: DatabaseQueue
    let alchemy: RecordingAlchemyClientStub
  }

  /// Builds a `CryptoSyncStore` against `TestBackend` so the apply pass
  /// writes through the real repositories. Only Alchemy is stubbed —
  /// the same shape the existing Stage 9 tests use.
  private func makeFixture() throws -> Fixture {
    let (backend, database) = try TestBackend.create()
    let alchemy = RecordingAlchemyClientStub()
    alchemy.setTransfersResponse(.transfers([]))
    // Resolve through the backend's own shared profile-index registry;
    // there is no per-profile `instrument` table.
    let registry = backend.grdbInstruments
    let discovery = CryptoTokenDiscoveryService(
      registry: registry, resolver: CountingRegistrationResolver(), alchemy: alchemy)
    let walletSyncEngine = WalletSyncEngine(
      alchemy: alchemy,
      blockExplorer: BlockExplorerTestDoubles.empty,
      discovery: discovery,
      walletSyncState: backend.walletSyncState,
      importOriginFactory: { accountId in
        ImportOrigin(
          rawDescription: "wallet:\(accountId.uuidString)",
          rawAmount: 0,
          importedAt: Self.pinnedNow,
          importSessionId: UUID(),
          parserIdentifier: "alchemy-wallet-sync")
      })
    let walletApplyEngine = WalletApplyEngine(
      transactions: backend.transactions,
      walletSyncState: backend.walletSyncState,
      importRules: NoOpWalletImportRulesEngine(),
      clock: { Self.pinnedNow })
    let store = CryptoSyncStore(
      walletSyncEngine: walletSyncEngine,
      walletApplyEngine: walletApplyEngine,
      walletSyncState: backend.walletSyncState,
      accounts: backend.accounts,
      clock: { Self.pinnedNow })
    return Fixture(
      syncStore: store, backend: backend, database: database, alchemy: alchemy)
  }

  /// Seeds a crypto account so `accounts.fetchAll()` returns it.
  @discardableResult
  private func seedCryptoAccount(
    in backend: CloudKitBackend,
    walletAddress: String = "0x" + String(repeating: "a", count: 40),
    chain: ChainConfig = .ethereum
  ) async throws -> Account {
    let account = Account(
      name: "Wallet \(walletAddress.suffix(4))",
      type: .crypto,
      instrument: chain.nativeInstrument,
      walletAddress: walletAddress.lowercased(),
      chainId: chain.chainId)
    return try await backend.accounts.create(account, openingBalance: nil)
  }

  /// Seeds a non-crypto account to assert the filter excludes it.
  @discardableResult
  private func seedAssetAccount(in backend: CloudKitBackend) async throws -> Account {
    let account = Account(
      name: "Savings",
      type: .asset,
      instrument: .AUD)
    return try await backend.accounts.create(account, openingBalance: nil)
  }

  // MARK: - Filtering

  @Test("Crypto filter surfaces only crypto-typed accounts")
  func filterSurfacesOnlyCryptoAccounts() async throws {
    let fixture = try makeFixture()
    let crypto = try await seedCryptoAccount(in: fixture.backend)
    _ = try await seedAssetAccount(in: fixture.backend)
    let all = try await fixture.backend.accounts.fetchAll()

    let cryptoOnly = all.filter { $0.type == .crypto }
    #expect(cryptoOnly.count == 1)
    #expect(cryptoOnly.first?.id == crypto.id)
  }

  // MARK: - Sync now action

  @Test("syncAccount fires for a crypto account regardless of stale threshold")
  func syncNowDispatchesEvenWhenFresh() async throws {
    let fixture = try makeFixture()
    let account = try await seedCryptoAccount(in: fixture.backend)

    await fixture.syncStore.syncAccount(account)

    // The recording stub sees one transfers call per (account, chain).
    #expect(fixture.alchemy.recordedCalls.count >= 1)
    // Per-account state is now populated.
    #expect(fixture.syncStore.statePerAccount[account.id] != nil)
  }

  @Test("syncAccount is a no-op for non-crypto accounts")
  func syncIgnoresNonCryptoAccounts() async throws {
    let fixture = try makeFixture()
    let asset = try await seedAssetAccount(in: fixture.backend)

    await fixture.syncStore.syncAccount(asset)

    #expect(fixture.alchemy.recordedCalls.isEmpty)
    #expect(fixture.syncStore.statePerAccount[asset.id] == nil)
  }

  // MARK: - Last-synced state

  @Test("After a successful sync, statePerAccount records lastSyncedAt")
  func lastSyncedTimestampPopulatedOnSuccess() async throws {
    let fixture = try makeFixture()
    let account = try await seedCryptoAccount(in: fixture.backend)

    await fixture.syncStore.syncAccount(account)

    let state = try #require(fixture.syncStore.statePerAccount[account.id])
    // Apply pass uses the injected clock; we pinned it to `pinnedNow`,
    // so the timestamp should equal that. Comparing equality (not
    // "approximate") catches drift if the clock injection regresses.
    #expect(state.lastSyncedAt == Self.pinnedNow)
    #expect(state.lastError == nil)
  }
}
