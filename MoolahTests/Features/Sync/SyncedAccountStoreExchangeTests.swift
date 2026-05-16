// MoolahTests/Features/Sync/SyncedAccountStoreExchangeTests.swift
import Foundation
import GRDB
import Testing

@testable import Moolah

/// Integration test: one `SyncedAccountStore` syncs an `.exchange`
/// account through the SAME parallel-build -> sequential-apply pipeline
/// the crypto path uses, via a registered `CoinstashSyncSource` — no
/// exchange-specific store, no duplicated orchestration.
///
/// Mirrors the crypto suites' `TestBackend` fixture shape (there is no
/// shared `SyncedAccountStoreTestHarness` in this codebase — the
/// per-suite `Fixture` + `makeStore` helper is the real scaffolding).
/// The store is built first, then the exchange source is registered via
/// the test-only `appendSourceForTesting(_:)` so it can use
/// fixture-owned collaborators.
@Suite("SyncedAccountStore — exchange via shared pipeline")
@MainActor
struct SyncedAccountStoreExchangeTests {
  nonisolated static let pinnedNow = Date(timeIntervalSince1970: 1_700_000_000)

  private struct Fixture {
    let store: SyncedAccountStore
    let backend: CloudKitBackend
    let database: DatabaseQueue
  }

  private func makeFixture() throws -> Fixture {
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
    let store = SyncedAccountStore(
      sources: [WalletSyncSource(engine: walletSyncEngine)],
      walletApplyEngine: walletApplyEngine,
      walletSyncState: backend.walletSyncState,
      accounts: backend.accounts,
      clock: { Self.pinnedNow })
    return Fixture(store: store, backend: backend, database: database)
  }

  /// Seeds an `.exchange` account, saves its token, and registers a
  /// `CoinstashSyncSource` whose stub client returns one fiat deposit.
  private func makeExchangeAccount(
    in fixture: Fixture, token: String
  ) throws -> Account {
    let account = Account(
      name: "Coinstash", type: .exchange, instrument: .AUD,
      valuationMode: .calculatedFromTrades, exchangeProvider: .coinstash)
    _ = TestBackend.seed(accounts: [account], in: fixture.database)
    let tokenStore = ExchangeTokenStore(synchronizable: false)
    try tokenStore.save(token: token, for: account.id)
    let registry = GRDBInstrumentRegistryRepository(database: fixture.database)
    fixture.store.appendSourceForTesting(
      CoinstashSyncSource(
        tokenStore: tokenStore,
        client: StubExchangeClient(deposit: 100),
        engine: ExchangeSyncEngine(
          resolver: ExchangeInstrumentResolver(
            registry: registry, fiatInstrument: .AUD))))
    return account
  }

  @Test("Store syncs an exchange account through the shared pipeline")
  func storeSyncsExchangeAccountThroughSharedPipeline() async throws {
    let fixture = try makeFixture()
    let account = try makeExchangeAccount(in: fixture, token: "TOK")
    try await fixture.backend.walletSyncState.save(
      WalletSyncState(
        id: account.id, lastSyncedBlockNumber: 0,
        lastSyncedAt: .distantPast, lastError: nil))
    await fixture.store.loadInitialState()

    await fixture.store.syncAccount(account)

    // No per-account error recorded — the exchange build + apply landed.
    let state = try await fixture.backend.walletSyncState.load(accountId: account.id)
    #expect(state?.lastError == nil)
    // The deposit row reached the DB through the shared apply pass, with
    // its provider `externalId` preserved on the leg.
    let txns = try await fixture.backend.transactions.fetchAll(
      filter: TransactionFilter())
    #expect(txns.contains { txn in txn.legs.contains { $0.externalId != nil } })
  }
}
