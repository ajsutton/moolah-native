// Shared/CryptoImport/WalletSyncEngine.swift
import Foundation
import OSLog

/// Result of one per-account build pass. Stage 9's apply pass needs
/// both the candidate transactions and the head block number so it can
/// advance `WalletSyncState.lastSyncedBlockNumber`. Returned together
/// (rather than threading the head block through `BuiltTransaction`) so
/// the build phase has a single, type-safe handoff to the apply phase.
///
/// `headBlockNumber` is the largest block number observed across the
/// fetched transfers. When the fetch returns no transfers (e.g. account
/// has no recent activity), the value falls back to the prior
/// `lastSyncedBlockNumber` so the next cycle's reorg-window math still
/// holds, or `0` on a genesis-style fetch.
struct WalletSyncBuildResult: Sendable, Hashable {
  let candidates: [BuiltTransaction]
  let headBlockNumber: UInt64
}

/// Per-account orchestrator of the build phase. **No repository writes.**
/// Stage 7's apply pass consumes `WalletSyncBuildResult` and persists.
///
/// The engine is a `Sendable` struct — every dependency is itself `Sendable`
/// (actor or stateless) and there is no mutable state on `Self`. This makes
/// it safe to call concurrently from `Stage 9`'s `withTaskGroup` parallel
/// build phase.
struct WalletSyncEngine: Sendable {
  private let alchemy: any AlchemyClient
  private let discovery: CryptoTokenDiscoveryService
  private let walletSyncState: any WalletSyncStateRepository
  private let importOriginFactory: @Sendable (UUID) -> ImportOrigin
  /// Shared static `Logger` — `Logger` is `Sendable`, so a static let is
  /// safe across actor boundaries without per-instance allocation.
  private static let logger = Logger(
    subsystem: "com.moolah.app", category: "WalletSyncEngine")

  /// - Parameters:
  ///   - alchemy: Stage 4's `AlchemyClient`. The engine itself doesn't
  ///     hold the rate limiter — `LiveAlchemyClient` does, so callers
  ///     don't need to plumb it through here.
  ///   - discovery: Stage 5's actor-coalesced token registry resolver.
  ///   - walletSyncState: Per-device sync checkpoint store. The engine
  ///     reads `lastSyncedBlockNumber` to compute `fromBlock`; **it does
  ///     not write back** — Stage 7's apply pass is the single writer.
  ///   - importOriginFactory: Builds an `ImportOrigin` keyed to the
  ///     account being synced. Stage 9 supplies a closure that captures
  ///     the per-cycle session id; tests pass a deterministic factory.
  init(
    alchemy: any AlchemyClient,
    discovery: CryptoTokenDiscoveryService,
    walletSyncState: any WalletSyncStateRepository,
    importOriginFactory: @Sendable @escaping (UUID) -> ImportOrigin
  ) {
    self.alchemy = alchemy
    self.discovery = discovery
    self.walletSyncState = walletSyncState
    self.importOriginFactory = importOriginFactory
  }

  /// Runs the build phase for a single crypto account. Returns the
  /// candidate `BuiltTransaction`s and the head block number the apply
  /// pass should record on `WalletSyncState`. Throws on transient
  /// failures (network, rate-limit, malformed account); the orchestrator
  /// (Stage 9) handles per-account error containment so other accounts
  /// still apply.
  ///
  /// Cancellation: respects `Task.checkCancellation()` between stages.
  /// A cancelled task throws `CancellationError` and writes nothing
  /// anywhere — the apply pass is the single writer regardless.
  func build(
    account: Account, chain: ChainConfig
  ) async throws -> WalletSyncBuildResult {
    // 1. Validate account is a crypto account with required fields.
    guard
      account.type == .crypto,
      let walletAddress = account.walletAddress,
      !walletAddress.isEmpty
    else {
      Self.logger.error(
        "WalletSyncEngine: invalid account \(account.id, privacy: .public)"
      )
      throw WalletSyncError.providerMalformedResponse(stage: "account-validation")
    }
    try Task.checkCancellation()

    // 2. Determine fromBlock (reorg window — re-fetch covers the last
    //    32 blocks below the prior checkpoint).
    let state = try await walletSyncState.load(accountId: account.id)
    let priorBlock = state?.lastSyncedBlockNumber ?? 0
    let fromBlock = state.map { Self.subtractingReorgWindow($0.lastSyncedBlockNumber) } ?? 0

    // 3. Fetch transfers (rate-limited inside AlchemyClient).
    try Task.checkCancellation()
    let transfers = try await alchemy.getAssetTransfers(
      chain: chain, walletAddress: walletAddress, fromBlock: fromBlock)
    try Task.checkCancellation()

    // 4. Compute head block from raw transfers before discovery — once
    //    Alchemy has acknowledged the fetch we know the watermark even
    //    if discovery cancels mid-build. Falls back to the prior
    //    checkpoint when Alchemy returns no rows so the next cycle's
    //    reorg-window math advances exactly once.
    let headBlock = Self.maxBlockNumber(in: transfers) ?? priorBlock

    // 5. Build candidates. Discovery actor handles its own coalescing;
    //    no repository writes happen here.
    let builder = TransferEventBuilder()
    let importOrigin = importOriginFactory(account.id)
    let built = try await builder.build(
      transfers: transfers,
      account: account,
      chain: chain,
      discovery: discovery,
      importOrigin: importOrigin)
    return WalletSyncBuildResult(candidates: built, headBlockNumber: headBlock)
  }

  /// Per design: re-fetch covers `[lastSyncedBlockNumber - 32, head]`.
  /// Returns 0 when the prior checkpoint sits inside the reorg window
  /// (genesis-fetch on a new device).
  static func subtractingReorgWindow(_ block: UInt64) -> UInt64 {
    block > 32 ? block - 32 : 0
  }

  /// Maximum `blockNum` parsed from a list of `AlchemyTransfer`s as
  /// `UInt64`. Returns `nil` when the list is empty or every entry has
  /// an unparseable `blockNum` field — the caller falls back to the
  /// prior checkpoint so the watermark only advances on a confirmed
  /// fetch result. Internal so Stage 9 can reuse the same parse rule
  /// from tests.
  static func maxBlockNumber(in transfers: [AlchemyTransfer]) -> UInt64? {
    var maximum: UInt64?
    for transfer in transfers {
      guard let value = parseHexUInt64(transfer.blockNum) else { continue }
      if let current = maximum {
        maximum = Swift.max(current, value)
      } else {
        maximum = value
      }
    }
    return maximum
  }

  /// Parses a 0x-prefixed hex string into a `UInt64`. Returns `nil`
  /// on malformed input — callers log/skip rather than failing the
  /// entire sync. `private` because the only call site is the
  /// in-engine head-block computation; the matching `Decimal` parse on
  /// `AlchemyTransfer.RawContract` lives elsewhere.
  private static func parseHexUInt64(_ raw: String) -> UInt64? {
    let trimmed: Substring =
      raw.hasPrefix("0x") || raw.hasPrefix("0X")
      ? raw.dropFirst(2)
      : Substring(raw)
    return UInt64(trimmed, radix: 16)
  }
}
