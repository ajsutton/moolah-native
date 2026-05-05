// MoolahTests/Shared/CryptoImport/WalletSyncTestDoubles.swift
import Foundation

@testable import Moolah

/// Namespace anchor so SwiftLint's `file_name` rule stays satisfied
/// alongside the loose top-level helpers and stubs declared below.
enum WalletSyncTestDoubles {}

/// Counting stub for `AlchemyClient` that returns a scripted transfer
/// list per `(chainId, walletAddress)` key. Records every call so tests
/// can assert on `fromBlock` derivation and call counts.
///
/// `@unchecked Sendable`: state lives behind an `NSLock`, mirroring the
/// project convention for non-actor concurrent test stubs (see
/// `AlchemyTestSupport.swift`, `CryptoTokenDiscoveryTestDoubles.swift`).
final class RecordingAlchemyClientStub: AlchemyClient, @unchecked Sendable {
  struct AssetTransfersCall: Sendable, Hashable {
    let chainId: Int
    let walletAddress: String
    let fromBlock: UInt64
  }

  enum Response: Sendable {
    case transfers([AlchemyTransfer])
    case failure(any Error)
  }

  /// Errors thrown when scripting hooks are unset and a test path hits
  /// the stub anyway. Keeps the failure message specific to the path.
  struct UnscriptedTransfersCall: Error { let chainId: Int }
  struct UnexpectedTokenMetadataCall: Error {}

  private let lock = NSLock()
  private var transfersResponse: Response?
  private var assetTransfersCalls: [AssetTransfersCall] = []
  /// Optional hook fired before the response is returned — the
  /// cancellation test installs a closure here that cancels the parent
  /// task so the engine throws on the next `checkCancellation()`.
  private var beforeAssetTransfers: (@Sendable () async -> Void)?

  func setTransfersResponse(_ response: Response) {
    lock.withLock { self.transfersResponse = response }
  }

  func setBeforeAssetTransfers(_ hook: (@Sendable () async -> Void)?) {
    lock.withLock { self.beforeAssetTransfers = hook }
  }

  var recordedCalls: [AssetTransfersCall] {
    lock.withLock { assetTransfersCalls }
  }

  func getAssetTransfers(
    chain: ChainConfig,
    walletAddress: String,
    fromBlock: UInt64
  ) async throws -> [AlchemyTransfer] {
    let (response, hook) = lock.withLock {
      assetTransfersCalls.append(
        AssetTransfersCall(
          chainId: chain.chainId,
          walletAddress: walletAddress,
          fromBlock: fromBlock))
      return (transfersResponse, beforeAssetTransfers)
    }
    if let hook { await hook() }
    try Task.checkCancellation()
    switch response {
    case .none:
      throw UnscriptedTransfersCall(chainId: chain.chainId)
    case let .failure(error):
      throw error
    case let .transfers(transfers):
      return transfers
    }
  }

  func getTokenMetadata(
    chain: ChainConfig,
    contractAddress: String
  ) async throws -> AlchemyTokenMetadata {
    throw UnexpectedTokenMetadataCall()
  }
}

/// In-memory `WalletSyncStateRepository` stub. Records every call so
/// tests can verify the engine reads but never writes.
///
/// `@unchecked Sendable`: state behind an `NSLock`, matching the project
/// convention.
final class RecordingWalletSyncStateRepository: WalletSyncStateRepository, @unchecked Sendable {
  private let lock = NSLock()
  private var seeded: [UUID: WalletSyncState] = [:]
  private(set) var saveCount: Int = 0
  private(set) var deleteCount: Int = 0

  func seed(_ state: WalletSyncState) {
    lock.withLock { seeded[state.id] = state }
  }

  func loadAll() async throws -> [WalletSyncState] {
    lock.withLock { Array(seeded.values) }
  }

  func load(accountId: UUID) async throws -> WalletSyncState? {
    lock.withLock { seeded[accountId] }
  }

  func save(_ state: WalletSyncState) async throws {
    lock.withLock {
      saveCount += 1
      seeded[state.id] = state
    }
  }

  func delete(accountId: UUID) async throws {
    lock.withLock {
      deleteCount += 1
      seeded[accountId] = nil
    }
  }
}

// MARK: - Builder shortcuts

/// Constructs an `AlchemyTransfer` with the fields tests inspect — `hash`,
/// `from`, `to`, `category`, `asset`, contract address / decimals, raw
/// hex amount. Defaults match a typical native ETH send so cases that
/// only change one or two fields read concisely.
func makeAlchemyTransfer(
  hash: String,
  from: String,
  to: String?,
  category: AlchemyTransferCategory,
  asset: String? = "ETH",
  contractAddress: String? = nil,
  decimalsHex: String? = "0x12",  // 18
  rawValueHex: String = "0x0de0b6b3a7640000",  // 1.0 * 10^18
  blockTimestamp: String? = "2024-09-12T12:34:56.000Z",
  blockNum: String = "0x12d4f0a"
) -> AlchemyTransfer {
  AlchemyTransfer(
    hash: hash,
    uniqueId: "\(hash):0",
    from: from,
    to: to,
    category: category,
    asset: asset,
    rawContract: AlchemyTransfer.RawContract(
      address: contractAddress?.lowercased(),
      decimal: decimalsHex,
      rawValue: rawValueHex),
    metadata: AlchemyTransfer.Metadata(blockTimestamp: blockTimestamp),
    blockNum: blockNum)
}

/// Builds an `ImportOrigin` keyed off the synced account id. Matches
/// the production factory shape Stage 9 will pass.
func makeWalletImportOrigin(
  for accountId: UUID,
  importedAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
  sessionId: UUID = UUID()
) -> ImportOrigin {
  ImportOrigin(
    rawDescription: "wallet:\(accountId.uuidString)",
    rawAmount: 0,
    importedAt: importedAt,
    importSessionId: sessionId,
    parserIdentifier: "alchemy-wallet-sync")
}

/// Builds a crypto `Account` for a given chain + wallet address.
func makeCryptoAccount(
  id: UUID = UUID(),
  walletAddress: String,
  chain: ChainConfig
) -> Account {
  Account(
    id: id,
    name: "Wallet",
    type: .crypto,
    instrument: chain.nativeInstrument,
    walletAddress: walletAddress.lowercased(),
    chainId: chain.chainId)
}
