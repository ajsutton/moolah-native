import Foundation
import OSLog

/// Builds `BuiltTransaction` candidates from imported exchange transactions,
/// for the existing `WalletApplyEngine`. Trades (sharing an `orderId`) become
/// one multi-leg `Transaction`; deposits/withdrawals/awards become single-leg
/// transactions. If ANY leg in a group has an unresolvable instrument the
/// WHOLE group is dropped (a partial, unbalanced trade is worse than no
/// trade) and the drop is logged for diagnosis.
///
/// `Sendable` struct with no mutable state — mirrors `WalletSyncEngine` so it
/// is safe to call concurrently from the orchestrator's parallel build phase.
struct ExchangeSyncEngine: Sendable {
  private let resolver: ExchangeInstrumentResolver
  /// Shared static `Logger` — `Logger` is `Sendable`, so a static let is
  /// safe across actor boundaries without per-instance allocation.
  private static let logger = Logger(
    subsystem: "com.moolah.app", category: "ExchangeSyncEngine")

  init(resolver: ExchangeInstrumentResolver) {
    self.resolver = resolver
  }

  /// Coinstash category -> Moolah leg type. DEPOSIT/AWARD are inbound
  /// (`.income`); WITHDRAW is outbound (`.expense`); TRADE/TRADEFEE (and any
  /// unmapped category) are the legs of a swap (`.trade`). The signed
  /// quantity already encodes direction; this only sets the per-leg type
  /// bucket the UI groups by — mirroring `TransferEventBuilder.legType(for:)`
  /// where leg type lives on the leg, not the `Transaction`.
  static func legType(for category: String) -> TransactionType {
    switch category {
    case "DEPOSIT", "AWARD": return .income
    case "WITHDRAW": return .expense
    default: return .trade
    }
  }

  /// Runs the build phase for a single exchange account. Returns the
  /// candidate `BuiltTransaction`s; `headBlockNumber` is always `0` for
  /// exchanges (no block-watermark concept — the apply pass dedups by
  /// per-leg `externalId`).
  ///
  /// Cancellation: respects `Task.checkCancellation()` between groups and
  /// per row. A cancelled task throws `CancellationError` and writes nothing
  /// anywhere — the apply pass is the single writer regardless.
  func build(
    account: Account, imported: [ExchangeImportedTransaction]
  ) async throws -> WalletSyncBuildResult {
    // Trades share an `orderId`; deposits/withdrawals/awards have none, so
    // their `externalId` keys a singleton group (one single-leg transaction
    // each).
    let groups = Dictionary(grouping: imported) { row -> String in
      row.orderId ?? row.externalId
    }

    var candidates: [BuiltTransaction] = []
    for (groupKey, rows) in groups {
      try Task.checkCancellation()
      var legs: [TransactionLeg] = []
      var groupResolvable = true
      for row in rows {
        try Task.checkCancellation()
        guard
          let instrument = try await resolver.instrument(
            forSymbol: row.assetSymbol, isFiat: row.isFiat)
        else {
          Self.logger.warning(
            """
            Dropping group \(groupKey, privacy: .public): unresolvable \
            instrument externalId=\(row.externalId, privacy: .public) \
            symbol=\(row.assetSymbol ?? "nil", privacy: .public) \
            isFiat=\(row.isFiat, privacy: .public)
            """)
          groupResolvable = false
          break
        }
        // `.trade` legs preserve source-entered signs: CREDIT=+, DEBIT=-.
        // Never abs() and never auto-sign by leg position.
        let quantity = row.direction.multiplier * row.amount
        legs.append(
          TransactionLeg(
            accountId: account.id,
            instrument: instrument,
            quantity: quantity,
            externalId: row.externalId,
            type: Self.legType(for: row.category)))
      }
      guard groupResolvable, !legs.isEmpty else { continue }
      // Earliest occurrence in the group dates the transaction; no
      // `Date()` fallback (the group always has at least one row, so
      // `min()` is non-nil here — `guard` documents the invariant).
      guard let date = rows.map(\.occurredAt).min() else { continue }
      let transaction = Transaction(date: date, legs: legs)
      candidates.append(
        BuiltTransaction(
          originAccountId: account.id, transaction: transaction))
    }

    Self.logger.info(
      """
      Built \(candidates.count, privacy: .public) candidates from \
      \(imported.count, privacy: .public) imported rows
      """)
    return WalletSyncBuildResult(candidates: candidates, headBlockNumber: 0)
  }
}
