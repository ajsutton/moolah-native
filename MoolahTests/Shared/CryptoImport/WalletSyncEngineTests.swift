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
    blockExplorer: RecordingBlockExplorerClientStub = BlockExplorerTestDoubles.empty,
    syncState: RecordingWalletSyncStateRepository = .init()
  ) -> (WalletSyncEngine, CryptoTokenDiscoverySubject) {
    let subject = makeDiscoverySubject()
    let engine = WalletSyncEngine(
      alchemy: alchemy,
      blockExplorer: blockExplorer,
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
          hash: "0xa", from: Self.counterparty, to: Self.wallet, category: .erc20,
          contractAddress: "0xtoken1", decimalsHex: "0x12"),
        makeAlchemyTransfer(
          hash: "0xb", from: Self.counterparty, to: Self.wallet, category: .erc20,
          contractAddress: "0xtoken2", decimalsHex: "0x12"),
        makeAlchemyTransfer(
          hash: "0xc", from: Self.wallet, to: Self.counterparty, category: .erc20,
          contractAddress: "0xtoken3", decimalsHex: "0x12"),
      ]))
    let syncState = RecordingWalletSyncStateRepository()
    let (engine, _) = makeEngine(alchemy: alchemy, syncState: syncState)
    let account = makeCryptoAccount(walletAddress: Self.wallet, chain: .ethereum)

    let result = try await engine.build(account: account, chain: .ethereum)

    #expect(result.candidates.count == 3)
    #expect(result.candidates.allSatisfy { $0.originAccountId == account.id })
    // `makeAlchemyTransfer` defaults `blockNum = "0x12d4f0a"` → 19_746_570.
    #expect(result.headBlockNumber == 19_746_570)
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
          // Category is irrelevant: cancellation fires in the Alchemy
          // stub hook before the response returns, so the .erc20
          // filter is never reached.
          hash: "0xa", from: Self.counterparty, to: Self.wallet, category: .external)
      ]))
    let (engine, _) = makeEngine(alchemy: alchemy)
    let account = makeCryptoAccount(walletAddress: Self.wallet, chain: .ethereum)

    let task = Task<WalletSyncBuildResult, Error> {
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

  // MARK: - Head block

  @Test("Head block is the maximum blockNum across all returned transfers")
  func headBlockTracksMaximumBlockNumber() async throws {
    let alchemy = RecordingAlchemyClientStub()
    alchemy.setTransfersResponse(
      .transfers([
        makeAlchemyTransfer(
          hash: "0xa", from: Self.counterparty, to: Self.wallet,
          category: .erc20, contractAddress: "0xt1", decimalsHex: "0x12",
          blockNum: "0x10"),  // 16
        makeAlchemyTransfer(
          hash: "0xb", from: Self.counterparty, to: Self.wallet,
          category: .erc20, contractAddress: "0xt2", decimalsHex: "0x12",
          blockNum: "0x20"),  // 32
        makeAlchemyTransfer(
          hash: "0xc", from: Self.counterparty, to: Self.wallet,
          category: .erc20, contractAddress: "0xt3", decimalsHex: "0x12",
          blockNum: "0x18"),  // 24
      ]))
    let (engine, _) = makeEngine(alchemy: alchemy)
    let account = makeCryptoAccount(walletAddress: Self.wallet, chain: .ethereum)

    let result = try await engine.build(account: account, chain: .ethereum)
    #expect(result.headBlockNumber == 32)
  }

  @Test("No transfers + prior checkpoint → head block falls back to prior")
  func headBlockFallsBackToPriorCheckpoint() async throws {
    let alchemy = RecordingAlchemyClientStub()
    alchemy.setTransfersResponse(.transfers([]))
    let syncState = RecordingWalletSyncStateRepository()
    let account = makeCryptoAccount(walletAddress: Self.wallet, chain: .ethereum)
    syncState.seed(
      WalletSyncState(
        id: account.id,
        lastSyncedBlockNumber: 1234,
        lastSyncedAt: Date(timeIntervalSince1970: 1_700_000_000),
        lastError: nil))
    let (engine, _) = makeEngine(alchemy: alchemy, syncState: syncState)

    let result = try await engine.build(account: account, chain: .ethereum)
    #expect(result.headBlockNumber == 1234)
  }

  @Test("No transfers + no prior checkpoint → head block 0")
  func headBlockGenesisFallsBackToZero() async throws {
    let alchemy = RecordingAlchemyClientStub()
    alchemy.setTransfersResponse(.transfers([]))
    let (engine, _) = makeEngine(alchemy: alchemy)
    let account = makeCryptoAccount(walletAddress: Self.wallet, chain: .ethereum)

    let result = try await engine.build(account: account, chain: .ethereum)
    #expect(result.headBlockNumber == 0)
  }

  // MARK: - Read-only invariant

  @Test("End-to-end run never writes to WalletSyncStateRepository")
  func endToEndDoesNotWriteRepositories() async throws {
    let alchemy = RecordingAlchemyClientStub()
    alchemy.setTransfersResponse(
      .transfers([
        makeAlchemyTransfer(
          hash: "0xa", from: Self.counterparty, to: Self.wallet, category: .erc20,
          contractAddress: "0xtoken", decimalsHex: "0x12"),
        makeAlchemyTransfer(
          hash: "0xb", from: Self.wallet, to: Self.counterparty, category: .erc20,
          contractAddress: "0xtoken", decimalsHex: "0x12", uniqueIdSuffix: "1"),
      ]))
    let syncState = RecordingWalletSyncStateRepository()
    let (engine, _) = makeEngine(alchemy: alchemy, syncState: syncState)
    let account = makeCryptoAccount(walletAddress: Self.wallet, chain: .ethereum)

    _ = try await engine.build(account: account, chain: .ethereum)

    #expect(syncState.saveCount == 0)
    #expect(syncState.deleteCount == 0)
  }
}

/// Behavioural tests for `WalletSyncEngine`'s Blockscout integration:
/// Alchemy native rows are dropped and Blockscout is the authoritative
/// native-ETH index; Blockscout failures propagate as `WalletSyncError`
/// without fallback; the reorg-adjusted `fromBlock` is forwarded to
/// Blockscout the same way it is to Alchemy.
@Suite("WalletSyncEngine — Blockscout integration")
struct WalletSyncEngineBlockscoutTests {
  private func makeEngine(
    alchemy: RecordingAlchemyClientStub = .init(),
    blockExplorer: RecordingBlockExplorerClientStub = BlockExplorerTestDoubles.empty,
    syncState: RecordingWalletSyncStateRepository = .init()
  ) -> WalletSyncEngine {
    let subject = makeDiscoverySubject()
    return WalletSyncEngine(
      alchemy: alchemy,
      blockExplorer: blockExplorer,
      discovery: subject.service,
      walletSyncState: syncState,
      importOriginFactory: { accountId in makeWalletImportOrigin(for: accountId) })
  }

  @Test("Alchemy external rows dropped; Blockscout native + Alchemy ERC-20 kept")
  func filtersAlchemyToErc20AndSourcesNativeFromBlockscout() async throws {
    let wallet = "0xa4b572ea1b6f734fc88a0a004c5301f8dad54d60"
    let alchemy = RecordingAlchemyClientStub()
    alchemy.setTransfersResponse(
      .transfers([
        AlchemyTransfer(
          hash: "0xNAT", uniqueId: "0xNAT:external:0", from: wallet, to: "0xD",
          category: .external, asset: nil,
          rawContract: .init(address: nil, decimal: nil, rawValue: "0x1"),
          metadata: .init(blockTimestamp: "2024-09-12T12:00:00.000000Z"), blockNum: "0x64"),
        AlchemyTransfer(
          hash: "0xERC", uniqueId: "0xERC:erc20:0", from: "0xS", to: wallet,
          category: .erc20, asset: "USDC",
          rawContract: .init(address: "0xtoken", decimal: "0x6", rawValue: "0xf4240"),
          metadata: .init(blockTimestamp: "2024-09-12T12:00:00.000000Z"), blockNum: "0x65"),
      ]))
    let blockscout = RecordingBlockExplorerClientStub()
    blockscout.setNative(
      .txs([
        BlockscoutTransaction(
          hash: "0xNAT", blockNumber: 100, timestamp: "2024-09-12T12:00:00.000000Z",
          from: .init(hash: wallet), to: .init(hash: "0xD"),
          value: "1", status: "ok", result: "success")
      ]))
    let engine = makeEngine(alchemy: alchemy, blockExplorer: blockscout)
    let result = try await engine.build(
      account: makeCryptoAccount(walletAddress: wallet, chain: .ethereum), chain: .ethereum)
    let externalIds = result.candidates.flatMap { $0.transaction.legs.map(\.externalId) }
    #expect(externalIds.contains("0xERC:erc20:0"))  // Alchemy ERC-20 kept
    #expect(externalIds.contains("0xNAT:external:0"))  // native from Blockscout
    #expect(externalIds.filter { $0 == "0xNAT:external:0" }.count == 1)  // no double-count
  }

  @Test("Blockscout failure propagates as WalletSyncError, not swallowed")
  func blockscoutFailurePropagatesAsWalletSyncError() async throws {
    let alchemy = RecordingAlchemyClientStub()
    alchemy.setTransfersResponse(.transfers([]))
    let blockscout = RecordingBlockExplorerClientStub()
    blockscout.setNative(
      .failure(WalletSyncError.network(underlyingDescription: "blockscout down")))
    let engine = makeEngine(alchemy: alchemy, blockExplorer: blockscout)
    await #expect(throws: WalletSyncError.self) {
      _ = try await engine.build(
        account: makeCryptoAccount(walletAddress: "0xabc", chain: .ethereum), chain: .ethereum)
    }
  }

  @Test("Blockscout receives reorg-adjusted fromBlock from prior sync state")
  func blockscoutReceivesReorgAdjustedFromBlock() async throws {
    let alchemy = RecordingAlchemyClientStub()
    alchemy.setTransfersResponse(.transfers([]))
    let blockscout = RecordingBlockExplorerClientStub()
    let syncState = RecordingWalletSyncStateRepository()
    let account = makeCryptoAccount(walletAddress: "0xabc", chain: .ethereum)
    syncState.seed(
      WalletSyncState(
        id: account.id,
        lastSyncedBlockNumber: 100,
        lastSyncedAt: Date(timeIntervalSince1970: 1_700_000_000),
        lastError: nil))
    let engine = makeEngine(alchemy: alchemy, blockExplorer: blockscout, syncState: syncState)

    _ = try await engine.build(account: account, chain: .ethereum)

    #expect(blockscout.recordedNativeCalls.first?.fromBlock == 68)  // 100 - 32
    #expect(blockscout.recordedInternalCalls.first?.fromBlock == 68)  // 100 - 32
  }
}
