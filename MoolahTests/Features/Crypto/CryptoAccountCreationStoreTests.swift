// MoolahTests/Features/Crypto/CryptoAccountCreationStoreTests.swift
import Foundation
import GRDB
import Testing

@testable import Moolah

/// End-to-end tests for `CryptoAccountCreationLogic.submit(...)`.
///
/// Drives the full create-and-sync sequence through real `AccountStore`
/// and `CryptoSyncStore` instances backed by `TestBackend`. The Alchemy
/// client is the only piece stubbed — these tests own the contract that
/// a successful save kicks off the per-account sync, and a failed
/// validation skips it.
@Suite("CryptoAccountCreationLogic — submit")
@MainActor
struct CryptoAccountCreationStoreTests {
  // Pinned clock matches the `CryptoSyncStore` test pattern; keeps
  // `lastSyncedAt` deterministic when we assert against post-sync state.
  nonisolated static let pinnedNow = Date(timeIntervalSince1970: 1_700_000_000)
  // Canonical lowercase address used for happy-path tests; matches the
  // 42-char `0x…` regex enforced by `Account.validatedWalletAddress`.
  static let validAddress = "0x" + String(repeating: "a", count: 40)

  private struct Fixture {
    let accountStore: AccountStore
    let cryptoSyncStore: CryptoSyncStore
    let backend: CloudKitBackend
    let database: DatabaseQueue
    let alchemy: RecordingAlchemyClientStub
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
    let cryptoSyncStore = CryptoSyncStore(
      walletSyncEngine: walletSyncEngine,
      walletApplyEngine: walletApplyEngine,
      walletSyncState: backend.walletSyncState,
      accounts: backend.accounts,
      clock: { Self.pinnedNow })
    let accountStore = AccountStore(
      repository: backend.accounts,
      conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument)
    return Fixture(
      accountStore: accountStore,
      cryptoSyncStore: cryptoSyncStore,
      backend: backend,
      database: database,
      alchemy: alchemy)
  }

  @Test("Successful submit creates the account with the chain's native instrument")
  func successfulSubmitCreatesCryptoAccount() async throws {
    let fixture = try makeFixture()
    let logic = CryptoAccountCreationLogic(
      accountStore: fixture.accountStore,
      cryptoSyncStore: fixture.cryptoSyncStore)

    let outcome = await logic.submit(
      name: "Hardware Wallet",
      chain: .ethereum,
      walletAddressInput: Self.validAddress)

    guard case .created(let created) = outcome else {
      Issue.record("Expected .created outcome, got \(outcome)")
      return
    }
    #expect(created.type == .crypto)
    #expect(created.walletAddress == Self.validAddress)
    #expect(created.chainId == ChainConfig.ethereum.chainId)
    #expect(created.instrument == ChainConfig.ethereum.nativeInstrument)
    #expect(created.name == "Hardware Wallet")

    // The store optimistically populates its observable list, so the
    // new account is visible immediately without a reload round-trip.
    #expect(fixture.accountStore.accounts.count == 1)
    #expect(fixture.accountStore.accounts.first?.id == created.id)
  }

  @Test("Polygon chain produces a MATIC-native account")
  func polygonChainSetsMaticInstrument() async throws {
    let fixture = try makeFixture()
    let logic = CryptoAccountCreationLogic(
      accountStore: fixture.accountStore,
      cryptoSyncStore: fixture.cryptoSyncStore)

    let outcome = await logic.submit(
      name: "Polygon Hot Wallet",
      chain: .polygon,
      walletAddressInput: Self.validAddress)

    guard case .created(let created) = outcome else {
      Issue.record("Expected .created outcome, got \(outcome)")
      return
    }
    #expect(created.chainId == ChainConfig.polygon.chainId)
    #expect(created.instrument == ChainConfig.polygon.nativeInstrument)
    #expect(created.instrument.ticker == "MATIC")
  }

  @Test("Successful submit kicks off the initial Alchemy sync for the new account")
  func successfulSubmitTriggersInitialSync() async throws {
    let fixture = try makeFixture()
    let logic = CryptoAccountCreationLogic(
      accountStore: fixture.accountStore,
      cryptoSyncStore: fixture.cryptoSyncStore)

    let outcome = await logic.submit(
      name: "Sync Wallet",
      chain: .ethereum,
      walletAddressInput: Self.validAddress)
    guard case .created = outcome else {
      Issue.record("Expected .created outcome, got \(outcome)")
      return
    }

    // The store invokes the build phase exactly once for the newly-
    // created account, with the canonical wallet address it persisted.
    #expect(fixture.alchemy.recordedCalls.count == 1)
    #expect(fixture.alchemy.recordedCalls.first?.walletAddress == Self.validAddress)
  }

  @Test("Invalid address aborts before any repository or sync work")
  func invalidAddressShortCircuits() async throws {
    let fixture = try makeFixture()
    let logic = CryptoAccountCreationLogic(
      accountStore: fixture.accountStore,
      cryptoSyncStore: fixture.cryptoSyncStore)

    let outcome = await logic.submit(
      name: "Bad Address Wallet",
      chain: .ethereum,
      walletAddressInput: "vitalik.eth")

    guard case .invalidAddress = outcome else {
      Issue.record("Expected .invalidAddress, got \(outcome)")
      return
    }
    // No account was persisted and the build phase was never invoked.
    #expect(fixture.accountStore.accounts.isEmpty)
    #expect(fixture.alchemy.recordedCalls.isEmpty)
  }

  @Test("Empty/whitespace-only name is rejected without persisting")
  func emptyNameShortCircuits() async throws {
    let fixture = try makeFixture()
    let logic = CryptoAccountCreationLogic(
      accountStore: fixture.accountStore,
      cryptoSyncStore: fixture.cryptoSyncStore)

    let outcome = await logic.submit(
      name: "   ",
      chain: .ethereum,
      walletAddressInput: Self.validAddress)

    guard case .invalidAddress = outcome else {
      Issue.record("Expected .invalidAddress for empty name, got \(outcome)")
      return
    }
    #expect(fixture.accountStore.accounts.isEmpty)
    #expect(fixture.alchemy.recordedCalls.isEmpty)
  }

  @Test("Whitespace and mixed case in the address are normalised before persisting")
  func addressIsTrimmedAndLowercased() async throws {
    let fixture = try makeFixture()
    let logic = CryptoAccountCreationLogic(
      accountStore: fixture.accountStore,
      cryptoSyncStore: fixture.cryptoSyncStore)

    // Mix of leading whitespace, mixed case, and trailing newline.
    let raw = "  0xABCDEF0123456789ABCDEF0123456789ABCDEF01\n"
    let outcome = await logic.submit(
      name: "Padded Address Wallet",
      chain: .ethereum,
      walletAddressInput: raw)

    guard case .created(let created) = outcome else {
      Issue.record("Expected .created outcome, got \(outcome)")
      return
    }
    #expect(
      created.walletAddress == raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
  }

  @Test("Nil cryptoSyncStore: account is created, sync is skipped")
  func nilSyncStoreSkipsKickOff() async throws {
    let fixture = try makeFixture()
    let logic = CryptoAccountCreationLogic(
      accountStore: fixture.accountStore,
      cryptoSyncStore: nil)

    let outcome = await logic.submit(
      name: "Degraded Launch Wallet",
      chain: .ethereum,
      walletAddressInput: Self.validAddress)
    guard case .created = outcome else {
      Issue.record("Expected .created outcome, got \(outcome)")
      return
    }
    // Account persisted but no sync work fired (the test's sync store
    // exists but was never handed to the logic, so the alchemy stub
    // saw no activity).
    #expect(fixture.accountStore.accounts.count == 1)
    #expect(fixture.alchemy.recordedCalls.isEmpty)
  }
}
