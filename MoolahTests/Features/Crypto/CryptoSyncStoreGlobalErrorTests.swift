// MoolahTests/Features/Crypto/CryptoSyncStoreGlobalErrorTests.swift
import Foundation
import GRDB
import Testing

@testable import Moolah

/// Tests for `CryptoSyncStore.globalError`. The banner powers
/// `CryptoSettingsView.alchemyStatusBadge`: it must surface whenever a
/// build phase produces a process-wide failure (`.missingApiKey` /
/// `.invalidApiKey`) — either of those means no account can sync, so
/// the user needs the global affordance, not a per-account caption —
/// and clear once a sync cycle runs without one. It must NOT clear on
/// apply success when every account failed in the build phase (the
/// apply pass succeeds with empty input); doing so would leave the
/// user staring at a per-row error caption with no global affordance
/// to fix the underlying problem. These tests pin that contract.
@Suite("CryptoSyncStore — globalError banner")
@MainActor
struct CryptoSyncStoreGlobalErrorTests {
  nonisolated static let pinnedNow = Date(timeIntervalSince1970: 1_700_000_000)

  private struct Fixture {
    let store: CryptoSyncStore
    let backend: CloudKitBackend
    let database: DatabaseQueue
    let alchemy: RecordingAlchemyClientStub
  }

  private func makeStore() throws -> Fixture {
    let (backend, database) = try TestBackend.create()
    let alchemy = RecordingAlchemyClientStub()
    alchemy.setTransfersResponse(.transfers([]))
    let registry = GRDBInstrumentRegistryRepository(database: database)
    let discovery = CryptoTokenDiscoveryService(
      registry: registry,
      resolver: CountingRegistrationResolver(),
      alchemy: alchemy)
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
      store: store, backend: backend, database: database, alchemy: alchemy)
  }

  private func seedCryptoAccount(
    in database: DatabaseQueue,
    walletAddress: String = "0x" + String(UUID().uuidString.prefix(40)),
    chain: ChainConfig = .ethereum
  ) -> Account {
    let account = Account(
      name: "Wallet \(walletAddress.suffix(4))",
      type: .crypto,
      instrument: chain.nativeInstrument,
      walletAddress: walletAddress.lowercased(),
      chainId: chain.chainId)
    _ = TestBackend.seed(accounts: [account], in: database)
    return account
  }

  @Test("Successful sync clears any prior globalError")
  func successfulSyncClearsGlobalError() async throws {
    let fixture = try makeStore()
    let account = seedCryptoAccount(in: fixture.database)
    try await fixture.backend.walletSyncState.save(
      WalletSyncState(
        id: account.id, lastSyncedBlockNumber: 0,
        lastSyncedAt: .distantPast, lastError: nil))
    await fixture.store.loadInitialState()
    fixture.store.setGlobalError(.invalidApiKey)

    await fixture.store.syncStaleAccounts()

    #expect(fixture.store.globalError == nil)
  }

  @Test(".invalidApiKey from a build phase surfaces as globalError")
  func invalidApiKeyRaisesGlobalError() async throws {
    let fixture = try makeStore()
    let account = seedCryptoAccount(in: fixture.database)
    try await fixture.backend.walletSyncState.save(
      WalletSyncState(
        id: account.id, lastSyncedBlockNumber: 0,
        lastSyncedAt: .distantPast, lastError: nil))
    await fixture.store.loadInitialState()
    let address = try #require(account.walletAddress)
    fixture.alchemy.setTransfersResponse(
      .failure(WalletSyncError.invalidApiKey), for: address)

    await fixture.store.syncStaleAccounts()

    #expect(fixture.store.globalError == .invalidApiKey)
  }

  @Test(".missingApiKey from a build phase surfaces as globalError")
  func missingApiKeyRaisesGlobalError() async throws {
    let fixture = try makeStore()
    let account = seedCryptoAccount(in: fixture.database)
    try await fixture.backend.walletSyncState.save(
      WalletSyncState(
        id: account.id, lastSyncedBlockNumber: 0,
        lastSyncedAt: .distantPast, lastError: nil))
    await fixture.store.loadInitialState()
    let address = try #require(account.walletAddress)
    fixture.alchemy.setTransfersResponse(
      .failure(WalletSyncError.missingApiKey), for: address)

    await fixture.store.syncStaleAccounts()

    #expect(fixture.store.globalError == .missingApiKey)
  }

  @Test(".missingApiKey wins over .invalidApiKey when both are present")
  func missingApiKeyWinsOverInvalidApiKey() async throws {
    let fixture = try makeStore()
    let invalidAccount = seedCryptoAccount(in: fixture.database)
    let missingAccount = seedCryptoAccount(in: fixture.database)
    try await fixture.backend.walletSyncState.save(
      WalletSyncState(
        id: invalidAccount.id, lastSyncedBlockNumber: 0,
        lastSyncedAt: .distantPast, lastError: nil))
    try await fixture.backend.walletSyncState.save(
      WalletSyncState(
        id: missingAccount.id, lastSyncedBlockNumber: 0,
        lastSyncedAt: .distantPast, lastError: nil))
    await fixture.store.loadInitialState()
    let invalidAddress = try #require(invalidAccount.walletAddress)
    let missingAddress = try #require(missingAccount.walletAddress)
    fixture.alchemy.setTransfersResponse(
      .failure(WalletSyncError.invalidApiKey), for: invalidAddress)
    fixture.alchemy.setTransfersResponse(
      .failure(WalletSyncError.missingApiKey), for: missingAddress)

    await fixture.store.syncStaleAccounts()

    #expect(fixture.store.globalError == .missingApiKey)
  }

  @Test("Per-account network errors do not raise globalError")
  func networkErrorDoesNotRaiseGlobalError() async throws {
    let fixture = try makeStore()
    let account = seedCryptoAccount(in: fixture.database)
    try await fixture.backend.walletSyncState.save(
      WalletSyncState(
        id: account.id, lastSyncedBlockNumber: 0,
        lastSyncedAt: .distantPast, lastError: nil))
    await fixture.store.loadInitialState()
    let address = try #require(account.walletAddress)
    fixture.alchemy.setTransfersResponse(
      .failure(WalletSyncError.network(underlyingDescription: "offline")),
      for: address)

    await fixture.store.syncStaleAccounts()

    #expect(fixture.store.globalError == nil)
  }

  @Test("All-success cycle after .invalidApiKey clears globalError")
  func subsequentSuccessClearsGlobalError() async throws {
    let fixture = try makeStore()
    let account = seedCryptoAccount(in: fixture.database)
    try await fixture.backend.walletSyncState.save(
      WalletSyncState(
        id: account.id, lastSyncedBlockNumber: 0,
        lastSyncedAt: .distantPast, lastError: nil))
    await fixture.store.loadInitialState()
    let address = try #require(account.walletAddress)
    fixture.alchemy.setTransfersResponse(
      .failure(WalletSyncError.invalidApiKey), for: address)

    await fixture.store.syncStaleAccounts()
    #expect(fixture.store.globalError == .invalidApiKey)

    // Now the user sets a valid key — the next cycle returns transfers
    // (or an empty list) and the banner clears.
    fixture.alchemy.setTransfersResponse(.transfers([]), for: address)
    await fixture.store.syncAccount(account)

    #expect(fixture.store.globalError == nil)
  }
}
