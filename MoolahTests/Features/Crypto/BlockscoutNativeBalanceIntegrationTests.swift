// MoolahTests/Features/Crypto/BlockscoutNativeBalanceIntegrationTests.swift
import Foundation
import GRDB
import Testing

@testable import Moolah

/// End-to-end proof that #918 (Blockscout contract-internal credits) and
/// #919 (approve-only gas legs) are both reflected in the reconstructed
/// native-ETH balance.
///
/// Drives `WalletSyncEngine` (real `RecordingBlockExplorerClientStub` +
/// `RecordingAlchemyClientStub`) → `WalletApplyEngine` against `TestBackend`
/// (real `CloudKitBackend` + in-memory GRDB — never mocked), then reads
/// the account's native-ETH balance from the repository and asserts it
/// equals 1.5 − 0.000021 = 1.499979 ETH.
@Suite("Blockscout native balance — #918 + #919 end-to-end")
@MainActor
struct BlockscoutNativeBalanceIntegrationTests {
  /// Expected native-ETH balance after applying the three test events:
  ///
  /// - 1.0 ETH inbound external tx (wallet is `to`)
  /// - 0.5 ETH inbound contract-internal credit (#918; wallet is `to`)
  /// - `approve()` gas-only tx (#919; gasUsed=21 000, effectiveGasPrice=1 gwei)
  ///
  /// Gas fee = 21 000 gas × 1 gwei/gas = 21 000 gwei
  ///         = 21 000 × 10^9 wei / 10^18 wei·ETH^-1 = 0.000021 ETH
  /// Balance = 1.0 + 0.5 − 0.000021 = 1.499979 ETH.
  ///
  /// Constructed as `Decimal(sign:exponent:significand:)` to avoid Double's
  /// 53-bit mantissa imprecision. `1_499_979 × 10^-6` is exact in NSDecimal.
  private static let expectedBalance = Decimal(
    sign: .plus, exponent: -6, significand: 1_499_979)

  @Test("Internal credit and approve gas are both reflected in native balance")
  func internalCreditAndApproveGasAreBothReflectedInNativeBalance() async throws {
    let wallet = "0xa4b572ea1b6f734fc88a0a004c5301f8dad54d60"
    let approveHash = "0xAPPROVE"
    let (alchemy, blockscout) = makeStubs(wallet: wallet, approveHash: approveHash)
    let (backend, database) = try TestBackend.create()
    let account = makeSyncedAccount(wallet: wallet, in: database)

    let buildResult = try await buildPhase(
      account: account, alchemy: alchemy, blockscout: blockscout)
    _ = try await applyPhase(account: account, buildResult: buildResult, backend: backend)

    try await assertBalance(
      account: account, backend: backend, approveHash: approveHash)
  }

  // MARK: - Build helpers

  private func makeStubs(
    wallet: String,
    approveHash: String
  ) -> (RecordingAlchemyClientStub, RecordingBlockExplorerClientStub) {
    let alchemy = RecordingAlchemyClientStub()
    alchemy.setTransfersResponse(.transfers([]))
    // 21 000 gas × 1 gwei (1e9 wei/gas) = 21 000 gwei = 0.000021 ETH (#919).
    alchemy.setReceiptResponse(
      .receipt(
        AlchemyTransactionReceipt(
          hash: approveHash,
          gasUsed: Decimal(21_000),
          effectiveGasPrice: Decimal(1_000_000_000),
          from: wallet)),
      for: approveHash)

    let blockscout = RecordingBlockExplorerClientStub()
    // 1.0 ETH inbound external: 1e18 wei = "1000000000000000000" decimal.
    blockscout.setNative(
      .txs([
        BlockscoutTransaction(
          hash: "0xIN",
          blockNumber: 100,
          timestamp: "2024-09-12T12:00:00.000000Z",
          from: .init(hash: "0xSENDER"),
          to: .init(hash: wallet),
          value: "1000000000000000000",
          status: "ok",
          result: "success"),
        // approve() — wallet is sender, zero value; lands in signedGasTxs (#919).
        BlockscoutTransaction(
          hash: approveHash,
          blockNumber: 101,
          timestamp: "2024-09-12T12:05:00.000000Z",
          from: .init(hash: wallet),
          to: .init(hash: "0xTOKEN"),
          value: "0",
          status: "ok",
          result: "success"),
      ]))
    // 0.5 ETH contract-internal credit (#918): 5e17 wei = "500000000000000000".
    blockscout.setInternal(
      .txs([
        BlockscoutInternalTx(
          transactionHash: "0xP",
          blockNumber: 102,
          timestamp: "2024-09-12T12:10:00.000000Z",
          from: .init(hash: "0xROUTER"),
          to: .init(hash: wallet),
          value: "500000000000000000",
          index: 0,
          success: true)
      ]))
    return (alchemy, blockscout)
  }

  /// Seeds and returns a crypto account for `wallet` in the given database.
  /// Mirrors the `seedCryptoAccount` helper in `WalletApplyEngineTests`.
  private func makeSyncedAccount(wallet: String, in database: any DatabaseWriter) -> Account {
    let account = Account(
      name: "Wallet",
      type: .crypto,
      instrument: ChainConfig.ethereum.nativeInstrument,
      walletAddress: wallet.lowercased(),
      chainId: ChainConfig.ethereum.chainId)
    _ = TestBackend.seed(accounts: [account], in: database)
    return account
  }

  private func buildPhase(
    account: Account,
    alchemy: RecordingAlchemyClientStub,
    blockscout: RecordingBlockExplorerClientStub
  ) async throws -> WalletSyncBuildResult {
    let subject = makeDiscoverySubject()
    let engine = WalletSyncEngine(
      alchemy: alchemy,
      blockExplorer: blockscout,
      discovery: subject.service,
      walletSyncState: RecordingWalletSyncStateRepository(),
      importOriginFactory: { accountId in makeWalletImportOrigin(for: accountId) })
    return try await engine.build(account: account, chain: .ethereum)
  }

  @discardableResult
  private func applyPhase(
    account: Account,
    buildResult: WalletSyncBuildResult,
    backend: CloudKitBackend
  ) async throws -> [Transaction] {
    let engine = WalletApplyEngine(
      transactions: backend.transactions,
      walletSyncState: backend.walletSyncState,
      importRules: NoOpWalletImportRulesEngine())
    return try await engine.apply(perAccount: [
      .init(
        account: account,
        headBlockNumber: buildResult.headBlockNumber,
        candidates: buildResult.candidates)
    ])
  }

  private func assertBalance(
    account: Account,
    backend: CloudKitBackend,
    approveHash: String
  ) async throws {
    let stored = try await backend.transactions.fetchAll(
      filter: TransactionFilter(accountId: account.id))
    let nativeInstrument = ChainConfig.ethereum.nativeInstrument
    let accountLegs = stored.flatMap(\.legs).filter {
      $0.instrument == nativeInstrument && $0.accountId == account.id
    }
    // Sum via Int64 storageValues rather than raw Decimal quantities.
    // Decimal division chains (HexDecimal.parse → /10^18 → storageValue →
    // /10^8) accumulate NSDecimalRound artefacts that prevent exact Decimal
    // equality at the sum level. Int64 addition is exact; the single /10^8
    // conversion at the end gives the representable 1.499979.
    let rawBalance = accountLegs.map { $0.amount.storageValue }.reduce(Int64.zero, +)
    let balance = InstrumentAmount(storageValue: rawBalance, instrument: nativeInstrument).quantity

    // Exact: 100_000_000 + 50_000_000 − 2_100 = 149_997_900 / 10^8 = 1.499979.
    #expect(
      balance == Self.expectedBalance,
      "Expected \(Self.expectedBalance) ETH but got \(balance) ETH")

    // Structural: internal credit (#918) present.
    #expect(
      accountLegs.contains { $0.quantity > 0 && $0.externalId?.contains("0xP:internal:0") == true },
      "Internal credit leg (0xP) missing — #918 not fixed")

    // Structural: approve-only gas leg (#919) present.
    let gasExternalId = TransferReceiptCoalescer.gasLegExternalId(hash: approveHash)
    #expect(
      accountLegs.contains { $0.quantity < 0 && $0.externalId == gasExternalId },
      "approve() gas leg missing — #919 not fixed")
  }
}
