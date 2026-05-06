// Shared/CryptoImport/TransferReceiptCoalescer.swift
import Foundation
import OSLog

/// Receipt coalescing + gas-leg construction helpers, factored out of
/// `TransferEventBuilder.swift` so the main builder file stays inside
/// SwiftLint's `file_length` / `type_body_length` budgets. Internal to
/// the module — only the builder calls these — but file-private would
/// hide them from `TransferEventBuilder.swift`. All functions are
/// `Sendable`-pure (no captured state) so they're safe to call from
/// inside the parallel build path.
enum TransferReceiptCoalescer {
  /// Shared static `Logger`; matches the builder's pattern so receipt
  /// failures appear under the same subsystem in Console.app.
  static let logger = Logger(
    subsystem: "com.moolah.app", category: "TransferEventBuilder")

  /// Fetches `eth_getTransactionReceipt` for every unique outbound
  /// transfer hash in `groups`, in parallel via a `TaskGroup`. Coalescing
  /// happens at the hash level: a transaction with N outbound transfer
  /// legs (e.g. a multi-token swap) triggers exactly one receipt fetch.
  /// Inbound-only events don't trigger fetches — gas-leg construction
  /// is restricted to the from-side wallet per the design's "from-side
  /// wallet only" rule.
  ///
  /// Per-receipt fetch failures (network blip, rate limit on a single
  /// hash, malformed response) log and are dropped from the returned
  /// dictionary; affected events ship without a gas leg. This keeps a
  /// single bad receipt from failing the whole account, mirroring the
  /// builder's per-row decode-failure policy elsewhere. Cancellation is
  /// re-thrown so the group cancels every sibling and the caller sees
  /// the cancellation rather than a missing leg.
  static func fetchReceipts(
    groups: [[AlchemyTransfer]],
    walletAddress: String,
    chain: ChainConfig,
    alchemy: any AlchemyClient
  ) async throws -> [String: AlchemyTransactionReceipt] {
    let hashes = outboundHashes(in: groups, walletAddress: walletAddress)
    guard !hashes.isEmpty else { return [:] }
    var receipts: [String: AlchemyTransactionReceipt] = [:]
    receipts.reserveCapacity(hashes.count)
    try await withThrowingTaskGroup(of: AlchemyTransactionReceipt?.self) { group in
      for hash in hashes {
        group.addTask {
          try await fetchOne(hash: hash, chain: chain, alchemy: alchemy)
        }
      }
      for try await maybeReceipt in group {
        if let receipt = maybeReceipt {
          receipts[receipt.hash] = receipt
        }
      }
    }
    return receipts
  }

  /// Single-hash receipt fetch with the per-hash error-containment
  /// policy. `CancellationError` re-throws so the enclosing `TaskGroup`
  /// (and the outer build) terminate cleanly; every other failure logs
  /// and returns `nil` so the affected event ships without a gas leg.
  /// This keeps a transient receipt failure from blocking the rest of
  /// the account's sync.
  private static func fetchOne(
    hash: String,
    chain: ChainConfig,
    alchemy: any AlchemyClient
  ) async throws -> AlchemyTransactionReceipt? {
    do {
      return try await alchemy.getTransactionReceipt(chain: chain, hash: hash)
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      logger.notice(
        "Skipping gas leg for hash \(hash, privacy: .private) — receipt fetch failed: \(error.localizedDescription, privacy: .public)"
      )
      return nil
    }
  }

  /// Walks the grouped transfers and returns the set of `txHash` values
  /// that have at least one outbound transfer for this wallet —
  /// `external` for native sends, `erc20` (or `internal`) where this
  /// wallet is the from-side token sender. The Alchemy transfer
  /// endpoint reports `from` as the EOA on a top-level call
  /// (`external`) and as the token sender on an `erc20` row; in the
  /// simple `transfer()` case those are the same address, so a `from ==
  /// walletAddress` match across any accepted category is a reliable
  /// signal that this wallet paid the gas. NFT (`unknown`) categories
  /// are filtered out — gas-leg attribution is only meaningful for
  /// accepted categories.
  ///
  /// The walk preserves first-seen order so receipt fetches retire in a
  /// deterministic sequence (helps with signpost tracing).
  static func outboundHashes(
    in groups: [[AlchemyTransfer]],
    walletAddress: String
  ) -> [String] {
    var seen: Set<String> = []
    var ordered: [String] = []
    for events in groups {
      guard let first = events.first else { continue }
      let isOutbound = events.contains { event in
        event.category != .unknown
          && event.from.lowercased() == walletAddress
      }
      guard isOutbound, seen.insert(first.hash).inserted else { continue }
      ordered.append(first.hash)
    }
    return ordered
  }

  /// Builds the gas leg for an outbound transaction from a fetched
  /// receipt. The leg is `.expense` typed, denominated in the chain's
  /// native instrument, and carries a negative quantity — gas is always
  /// paid out (this wallet is the sender). Per the project sign rule
  /// (CLAUDE.md "Monetary Sign Convention") the negative is preserved
  /// rather than `abs()`-stripped; downstream display logic handles the
  /// sign.
  ///
  /// Returns `nil` when the receipt's `gasUsed` or `effectiveGasPrice`
  /// produces a non-positive product (e.g. a zero-gas synthetic). A
  /// zero gas leg would clutter the transaction without representing
  /// any real expense, so we drop it rather than persist a noise row.
  static func makeGasLeg(
    receipt: AlchemyTransactionReceipt,
    accountId: UUID,
    chain: ChainConfig
  ) -> TransactionLeg? {
    let gasFeeWei = receipt.totalGasFeeWei
    guard gasFeeWei > 0 else { return nil }
    let nativeDecimals = chain.nativeInstrument.decimals
    guard nativeDecimals >= 0 else { return nil }
    let scale = Decimal(sign: .plus, exponent: nativeDecimals, significand: 1)
    let gasFeeNative = gasFeeWei / scale
    return TransactionLeg(
      accountId: accountId,
      instrument: chain.nativeInstrument,
      quantity: -gasFeeNative,
      externalId: receipt.hash,
      type: .expense)
  }
}
