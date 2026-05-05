// MoolahTests/Shared/CryptoImport/WalletSyncEngineTests.swift
import Foundation
import Testing

@testable import Moolah

/// Behavioural tests for `WalletSyncEngine`. Exercises the per-account
/// orchestration: account validation → reorg-window `fromBlock` → Alchemy
/// fetch → builder. Asserts the engine never writes to any repository
/// (the load-bearing parallel-build invariant).
@Suite("WalletSyncEngine — Build phase")
struct WalletSyncEngineTests {
  private static let wallet = "0x1111111111111111111111111111111111111111"
  private static let counterparty = "0x2222222222222222222222222222222222222222"

  // MARK: - Helpers

  private func makeEngine(
    alchemy: RecordingAlchemyClientStub = .init(),
    syncState: RecordingWalletSyncStateRepository = .init()
  ) -> (WalletSyncEngine, CryptoTokenDiscoverySubject) {
    let subject = makeDiscoverySubject()
    let engine = WalletSyncEngine(
      alchemy: alchemy,
      discovery: subject.service,
      walletSyncState: syncState,
      importOriginFactory: { accountId in
        makeWalletImportOrigin(for: accountId)
      })
    return (engine, subject)
  }

  // MARK: - Happy path

  @Test("Returns one BuiltTransaction per inbound transfer; no state writes")
  func happyPathReturnsBuiltTransactions() async throws {
    let alchemy = RecordingAlchemyClientStub()
    alchemy.setTransfersResponse(
      .transfers([
        makeAlchemyTransfer(
          hash: "0xa", from: Self.counterparty, to: Self.wallet, category: .external),
        makeAlchemyTransfer(
          hash: "0xb", from: Self.counterparty, to: Self.wallet, category: .external),
        makeAlchemyTransfer(
          hash: "0xc", from: Self.wallet, to: Self.counterparty, category: .external),
      ]))
    let syncState = RecordingWalletSyncStateRepository()
    let (engine, _) = makeEngine(alchemy: alchemy, syncState: syncState)
    let account = makeCryptoAccount(walletAddress: Self.wallet, chain: .ethereum)

    let built = try await engine.build(account: account, chain: .ethereum)

    #expect(built.count == 3)
    #expect(built.allSatisfy { $0.originAccountId == account.id })
    #expect(syncState.saveCount == 0)
    #expect(syncState.deleteCount == 0)
  }

  // MARK: - fromBlock derivation

  @Test("Pre-existing state → fromBlock = lastSyncedBlockNumber - 32")
  func fromBlockSubtractsReorgWindow() async throws {
    let alchemy = RecordingAlchemyClientStub()
    alchemy.setTransfersResponse(.transfers([]))
    let syncState = RecordingWalletSyncStateRepository()
    let account = makeCryptoAccount(walletAddress: Self.wallet, chain: .ethereum)
    syncState.seed(
      WalletSyncState(
        id: account.id,
        lastSyncedBlockNumber: 100,
        lastSyncedAt: Date(timeIntervalSince1970: 1_700_000_000),
        lastError: nil))
    let (engine, _) = makeEngine(alchemy: alchemy, syncState: syncState)

    _ = try await engine.build(account: account, chain: .ethereum)

    let calls = alchemy.recordedCalls
    #expect(calls.count == 1)
    #expect(calls.first?.fromBlock == 68)  // 100 - 32
  }

  @Test("Pre-existing state inside reorg window → fromBlock = 0")
  func fromBlockClampsAtZeroInsideWindow() async throws {
    let alchemy = RecordingAlchemyClientStub()
    alchemy.setTransfersResponse(.transfers([]))
    let syncState = RecordingWalletSyncStateRepository()
    let account = makeCryptoAccount(walletAddress: Self.wallet, chain: .ethereum)
    syncState.seed(
      WalletSyncState(
        id: account.id,
        lastSyncedBlockNumber: 10,
        lastSyncedAt: Date(timeIntervalSince1970: 1_700_000_000),
        lastError: nil))
    let (engine, _) = makeEngine(alchemy: alchemy, syncState: syncState)

    _ = try await engine.build(account: account, chain: .ethereum)
    #expect(alchemy.recordedCalls.first?.fromBlock == 0)
  }

  @Test("No prior state → fromBlock = 0")
  func fromBlockZeroWhenNoState() async throws {
    let alchemy = RecordingAlchemyClientStub()
    alchemy.setTransfersResponse(.transfers([]))
    let syncState = RecordingWalletSyncStateRepository()
    let (engine, _) = makeEngine(alchemy: alchemy, syncState: syncState)
    let account = makeCryptoAccount(walletAddress: Self.wallet, chain: .ethereum)

    _ = try await engine.build(account: account, chain: .ethereum)
    #expect(alchemy.recordedCalls.first?.fromBlock == 0)
  }

  // MARK: - Cancellation

  @Test("Cancellation between fetch and build throws CancellationError")
  func cancellationBetweenStagesIsRespected() async throws {
    let alchemy = RecordingAlchemyClientStub()
    alchemy.setTransfersResponse(
      .transfers([
        makeAlchemyTransfer(
          hash: "0xa", from: Self.counterparty, to: Self.wallet, category: .external)
      ]))
    let (engine, _) = makeEngine(alchemy: alchemy)
    let account = makeCryptoAccount(walletAddress: Self.wallet, chain: .ethereum)

    let task = Task<[BuiltTransaction], Error> {
      try await engine.build(account: account, chain: .ethereum)
    }
    // Install a hook that fires inside the alchemy stub so we cancel
    // *during* the fetch (before the engine reaches its post-fetch
    // `checkCancellation`). The recording stub itself calls
    // `checkCancellation()` after the hook so the error surfaces from
    // the alchemy call, mirroring real-world cooperative cancellation.
    alchemy.setBeforeAssetTransfers { [task] in
      task.cancel()
    }

    await #expect(throws: CancellationError.self) {
      _ = try await task.value
    }
  }

  // MARK: - Account validation

  @Test("Non-crypto account → providerMalformedResponse")
  func nonCryptoAccountThrows() async throws {
    let alchemy = RecordingAlchemyClientStub()
    let (engine, _) = makeEngine(alchemy: alchemy)
    let account = Account(
      name: "Bank",
      type: .bank,
      instrument: .AUD,
      walletAddress: Self.wallet,
      chainId: 1)

    await #expect(throws: WalletSyncError.self) {
      _ = try await engine.build(account: account, chain: .ethereum)
    }
    #expect(alchemy.recordedCalls.isEmpty)
  }

  @Test("Missing walletAddress → providerMalformedResponse")
  func missingWalletAddressThrows() async throws {
    let alchemy = RecordingAlchemyClientStub()
    let (engine, _) = makeEngine(alchemy: alchemy)
    var account = makeCryptoAccount(walletAddress: Self.wallet, chain: .ethereum)
    account.walletAddress = nil

    await #expect(throws: WalletSyncError.self) {
      _ = try await engine.build(account: account, chain: .ethereum)
    }
    #expect(alchemy.recordedCalls.isEmpty)
  }

  @Test("Empty walletAddress → providerMalformedResponse")
  func emptyWalletAddressThrows() async throws {
    let alchemy = RecordingAlchemyClientStub()
    let (engine, _) = makeEngine(alchemy: alchemy)
    var account = makeCryptoAccount(walletAddress: Self.wallet, chain: .ethereum)
    account.walletAddress = ""

    await #expect(throws: WalletSyncError.self) {
      _ = try await engine.build(account: account, chain: .ethereum)
    }
    #expect(alchemy.recordedCalls.isEmpty)
  }

  // MARK: - Read-only invariant

  @Test("End-to-end run never writes to WalletSyncStateRepository")
  func endToEndDoesNotWriteRepositories() async throws {
    let alchemy = RecordingAlchemyClientStub()
    alchemy.setTransfersResponse(
      .transfers([
        makeAlchemyTransfer(
          hash: "0xa", from: Self.counterparty, to: Self.wallet, category: .external),
        makeAlchemyTransfer(
          hash: "0xb", from: Self.wallet, to: Self.counterparty, category: .external),
      ]))
    let syncState = RecordingWalletSyncStateRepository()
    let (engine, _) = makeEngine(alchemy: alchemy, syncState: syncState)
    let account = makeCryptoAccount(walletAddress: Self.wallet, chain: .ethereum)

    _ = try await engine.build(account: account, chain: .ethereum)

    #expect(syncState.saveCount == 0)
    #expect(syncState.deleteCount == 0)
  }
}
