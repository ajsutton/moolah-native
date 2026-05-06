// Shared/CryptoImport/TransferEventBuilder.swift
import Foundation
import OSLog
import os

/// Pure builder that converts raw Alchemy transfers (already grouped by
/// `hash`) into `BuiltTransaction`s. Stateless and `Sendable` — every
/// dependency is supplied per call.
///
/// Produces multi-leg transactions:
/// - One `.transfer` leg in the value token per token movement involving
///   this wallet (negative quantity outbound; positive inbound).
/// - The gas leg (`.expense` in the chain native token, on the from-side
///   wallet only) is **deferred to a follow-up** — it requires an
///   `eth_getTransactionReceipt` round-trip that Stage 4's `AlchemyClient`
///   does not yet expose. See issue #762. Stage 6 ships transfer-leg-only
///   `BuiltTransaction`s and the gas leg is added once that client method
///   lands.
///
/// Each leg's `externalId` is set to the event's `hash`. NFT categories
/// are filtered upstream at the request level; if one slips through (the
/// decoder's lenient `.unknown` case) the builder skips it with a
/// `Logger.notice` and continues so a single bad row doesn't fail the
/// whole sync.
struct TransferEventBuilder: Sendable {
  /// Shared static `Logger` — `Logger` is `Sendable`, so this is safe
  /// across actor boundaries without per-instance allocation.
  private static let logger = Logger(
    subsystem: "com.moolah.app", category: "TransferEventBuilder")

  /// Builds candidate transactions for a single account from a list of
  /// transfers fetched from Alchemy. Resolves token instruments via the
  /// supplied discovery service so concurrent build calls coalesce on
  /// the same `(chainId, contractAddress)` key.
  ///
  /// `account.walletAddress` is the user's wallet on this chain. The
  /// builder lowercases it before comparison — Alchemy returns `from` /
  /// `to` lowercased but callers may have stored the address in
  /// checksummed form. Transfers where `from` matches the wallet are
  /// outbound; matches on `to` are inbound. A self-send (both sides on
  /// this wallet) emits a single inbound leg — Stage 7's apply pass
  /// pairs the matching outbound from the build phase if the user
  /// happens to track the same wallet under two accounts (rare).
  ///
  /// `importOrigin` carries the per-import audit context (sync session
  /// id, parser identifier). Caller supplies; the builder echoes it on
  /// every produced transaction.
  ///
  /// Throws: surfaces only `CancellationError` from the discovery actor
  /// and `WalletSyncError.providerMalformedResponse` when a transfer
  /// the builder cannot interpret reaches the produced-leg stage.
  /// Per-row decode failures (malformed hex, missing decimals on a
  /// non-native transfer) are logged and skipped — they shouldn't fail
  /// the whole account.
  func build(
    transfers: [AlchemyTransfer],
    account: Account,
    chain: ChainConfig,
    discovery: CryptoTokenDiscoveryService,
    importOrigin: ImportOrigin
  ) async throws -> [BuiltTransaction] {
    let signpostID = OSSignpostID(log: Signposts.cryptoSync)
    os_signpost(
      .begin,
      log: Signposts.cryptoSync,
      name: "transferEventBuilder.build",
      signpostID: signpostID,
      "%{public}d transfers",
      transfers.count)
    defer {
      os_signpost(
        .end,
        log: Signposts.cryptoSync,
        name: "transferEventBuilder.build",
        signpostID: signpostID)
    }
    guard let rawAddress = account.walletAddress else {
      throw WalletSyncError.providerMalformedResponse(stage: "buildEvents-walletAddress")
    }
    let context = BuildContext(
      account: account,
      walletAddress: rawAddress.lowercased(),
      chain: chain,
      discovery: discovery,
      importOrigin: importOrigin)

    // Stable order: group preserves first-seen order so test fixtures
    // and signposts are deterministic.
    let groups = groupByHash(transfers)
    var results: [BuiltTransaction] = []
    results.reserveCapacity(groups.count)

    for events in groups {
      try Task.checkCancellation()
      guard let built = try await buildEvent(events: events, context: context) else {
        continue
      }
      results.append(built)
    }
    return results
  }

  // MARK: - Internals

  /// Groups transfers by `hash` while preserving first-seen order so the
  /// emitted `[BuiltTransaction]` is stable across runs (helps with
  /// signpost tracing and snapshot assertions in tests). Each event in a
  /// group already carries its own `hash`, so the key is dropped after
  /// grouping to keep call sites simple.
  private func groupByHash(_ transfers: [AlchemyTransfer]) -> [[AlchemyTransfer]] {
    var order: [String] = []
    var buckets: [String: [AlchemyTransfer]] = [:]
    for transfer in transfers {
      if buckets[transfer.hash] == nil {
        order.append(transfer.hash)
      }
      buckets[transfer.hash, default: []].append(transfer)
    }
    return order.compactMap { buckets[$0] }
  }

  /// Builds one `BuiltTransaction` from a hash group, or returns `nil`
  /// when the group produces no usable legs (every transfer was unknown
  /// category or malformed).
  private func buildEvent(
    events: [AlchemyTransfer],
    context: BuildContext
  ) async throws -> BuiltTransaction? {
    var legs: [TransactionLeg] = []
    var earliestTimestamp: Date?

    for event in events {
      try Task.checkCancellation()
      guard let leg = try await makeTransferLeg(event: event, context: context) else {
        continue
      }
      legs.append(leg)
      if let timestamp = parseTimestamp(event.metadata.blockTimestamp) {
        if let current = earliestTimestamp {
          earliestTimestamp = min(current, timestamp)
        } else {
          earliestTimestamp = timestamp
        }
      }
    }

    guard !legs.isEmpty else { return nil }

    // Date precedence: earliest block timestamp across the group, falling
    // back to `importedAt` so the transaction never lands with a zero
    // date if Alchemy omitted metadata for every event in this hash
    // (possible only when `withMetadata: false`, which the production
    // client doesn't request; guard anyway for defensiveness).
    let date = earliestTimestamp ?? context.importOrigin.importedAt
    let transaction = Transaction(
      date: date,
      legs: legs,
      importOrigin: context.importOrigin)
    return BuiltTransaction(
      originAccountId: context.account.id,
      transaction: transaction)
  }

  /// Builds a single `.transfer` leg for one Alchemy event, or returns
  /// `nil` when the event is unusable (NFT category slipped through,
  /// malformed amount, or a touched-but-not-on-this-wallet event that
  /// doesn't apply to the synced account).
  private func makeTransferLeg(
    event: AlchemyTransfer,
    context: BuildContext
  ) async throws -> TransactionLeg? {
    guard event.category != .unknown else {
      Self.logger.notice(
        "Skipping unknown-category transfer hash \(event.hash, privacy: .private)"
      )
      return nil
    }

    let direction = TransferDirection(
      fromAddress: event.from,
      toAddress: event.to,
      walletAddress: context.walletAddress)
    guard direction != .unrelated else {
      // Defensive — Alchemy's two-pass query should never surface a
      // transfer that doesn't touch this wallet, but a malformed reply
      // shouldn't fail the whole sync.
      Self.logger.notice(
        "Skipping transfer not involving wallet for hash \(event.hash, privacy: .private)"
      )
      return nil
    }

    guard
      let unsignedQuantity = scaledQuantity(
        rawDecimalValue: event.rawContract.rawDecimalValue,
        decimalsValue: event.rawContract.decimalsValue,
        category: event.category,
        chain: context.chain)
    else {
      Self.logger.notice(
        "Skipping malformed-amount transfer hash \(event.hash, privacy: .private)"
      )
      return nil
    }

    let instrument = try await resolveInstrument(event: event, context: context)

    let signedQuantity: Decimal
    switch direction {
    case .outbound:
      signedQuantity = -unsignedQuantity
    case .inbound, .selfSend:
      signedQuantity = unsignedQuantity
    case .unrelated:
      // Already handled above; unreachable here. `precondition` would be
      // overkill for a defensive branch, so re-route to nil.
      return nil
    }

    return TransactionLeg(
      accountId: context.account.id,
      instrument: instrument,
      quantity: signedQuantity,
      externalId: event.hash,
      type: .transfer)
  }

  /// Resolves the leg's `Instrument`. For native transfers (`.external`,
  /// `.internal`) returns the chain's native instrument directly — no
  /// discovery round-trip needed. For ERC-20 transfers, defers to
  /// `CryptoTokenDiscoveryService` so concurrent build calls share the
  /// same in-flight `Task` per `(chainId, contractAddress)` key.
  private func resolveInstrument(
    event: AlchemyTransfer,
    context: BuildContext
  ) async throws -> Instrument {
    switch event.category {
    case .external, .internal:
      return context.chain.nativeInstrument
    case .erc20:
      let contract = event.rawContract.address
      let decimals = event.rawContract.decimalsValue ?? 18
      let symbol = event.asset ?? "TOKEN"
      let registration = try await context.discovery.resolveOrLoad(
        chain: context.chain,
        contractAddress: contract,
        symbol: symbol,
        name: symbol,
        decimals: decimals)
      return registration.instrument
    case .unknown:
      // Filtered by caller; preserve the path so the type-checker keeps
      // the switch exhaustive.
      throw WalletSyncError.providerMalformedResponse(stage: "resolveInstrument-unknown")
    }
  }

  /// Converts an integer-units token amount into a human-scaled
  /// `Decimal`. Returns `nil` when the underlying hex parse failed (the
  /// caller logs and skips).
  ///
  /// For native transfers Alchemy may omit `decimal` — we substitute the
  /// chain's native decimals so a dropped field doesn't lose the row.
  private func scaledQuantity(
    rawDecimalValue: Decimal?,
    decimalsValue: Int?,
    category: AlchemyTransferCategory,
    chain: ChainConfig
  ) -> Decimal? {
    guard let rawDecimalValue else { return nil }
    let decimals: Int
    switch category {
    case .external, .internal:
      decimals = decimalsValue ?? chain.nativeInstrument.decimals
    case .erc20:
      // ERC-20 with no decimals reported is essentially uninterpretable —
      // refuse rather than guess.
      guard let decimalsValue else { return nil }
      decimals = decimalsValue
    case .unknown:
      return nil
    }
    guard decimals >= 0 else { return nil }
    return rawDecimalValue / Decimal(sign: .plus, exponent: decimals, significand: 1)
  }

  /// Parses Alchemy's ISO-8601 block timestamp (`"2024-09-12T12:34:56.000Z"`).
  /// Returns `nil` on malformed input — caller falls back to
  /// `ImportOrigin.importedAt`.
  ///
  /// `ISO8601DateFormatter` is allocated per call to keep the builder a
  /// pure `Sendable` value type (no `nonisolated(unsafe)` static state).
  /// The build hot path is dominated by the Alchemy round-trip and the
  /// discovery actor, so a per-row allocation here is a non-event.
  private func parseTimestamp(_ raw: String?) -> Date? {
    guard let raw else { return nil }
    let withFraction = ISO8601DateFormatter()
    withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = withFraction.date(from: raw) { return date }
    let plain = ISO8601DateFormatter()
    plain.formatOptions = [.withInternetDateTime]
    return plain.date(from: raw)
  }
}

/// Per-call context bundle so `TransferEventBuilder`'s helpers stay
/// inside SwiftLint's parameter-count budget while still getting at the
/// account, chain, discovery actor, and import audit fields. Built once
/// in `build(...)` and passed by value down the call tree.
private struct BuildContext: Sendable {
  let account: Account
  let walletAddress: String
  let chain: ChainConfig
  let discovery: CryptoTokenDiscoveryService
  let importOrigin: ImportOrigin
}

/// Direction a single Alchemy transfer takes relative to the synced
/// wallet. Computed from the lowercased `from` / `to` fields.
private enum TransferDirection {
  case outbound
  case inbound
  case selfSend
  case unrelated

  init(fromAddress: String, toAddress: String?, walletAddress: String) {
    let from = fromAddress.lowercased()
    let to = toAddress?.lowercased()
    let fromIsUs = from == walletAddress
    let toIsUs = to == walletAddress
    switch (fromIsUs, toIsUs) {
    case (true, true): self = .selfSend
    case (true, false): self = .outbound
    case (false, true): self = .inbound
    case (false, false): self = .unrelated
    }
  }
}
