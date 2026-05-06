// Shared/CryptoImport/CrossDeviceLegDeduper.swift
import Foundation
import OSLog
import os

/// Post-CKSyncEngine reconciliation pass. Runs on `@MainActor` after every
/// CKSyncEngine `fetchedRecordZoneChanges` callback applies cleanly. Scans
/// transactions whose legs share a non-nil `(accountId, externalId)` pair
/// with another transaction and reduces each group to a single canonical
/// leg using deterministic UUID lex-order tiebreak — both devices reach
/// the same end state independently without further coordination.
///
/// **All deletes route through `TransactionRepository.delete(id:)`**, not
/// directly to GRDB, so the change propagates back through CKSyncEngine
/// to other devices via the repository's existing `onRecordDeleted`
/// hook. Bypassing the repository would silently desync the deduper's
/// local cleanup from CloudKit. (See
/// `plans/2026-05-05-crypto-wallet-import-design.md` §"Multi-device race
/// window — honest description".)
///
/// **v1 scope.** A transaction whose every leg duplicates another
/// transaction's legs is removed wholesale. Mixed transactions — one
/// duplicate leg plus one unique leg — are unusual in the wallet-import
/// shape (each on-chain event yields one `externalId`); the deduper logs
/// a warning and skips them. Per-leg dedup within a single transaction
/// is intentionally out of scope and tracked separately if it ever
/// surfaces.
@MainActor
struct CrossDeviceLegDeduper {
  private let transactions: any TransactionRepository
  private let logger = Logger(
    subsystem: "com.moolah.app", category: "CrossDeviceLegDeduper")

  init(transactions: any TransactionRepository) {
    self.transactions = transactions
  }

  /// Runs the dedup sweep over the transactions touched by the most
  /// recent CKSyncEngine fetch. Idempotent — repeated calls on a
  /// converged state are a no-op. Bounded — the leg-side IN predicate
  /// rides the `leg_dedup_by_account_external` partial unique index, so
  /// even thousand-id sweeps stay cheap. Returns the count of
  /// duplicate-transaction deletions actually performed (useful for
  /// logging and metrics).
  ///
  /// - Parameter touchedExternalIds: the set of non-nil `externalId`s
  ///   the just-applied CK batch carried on `TransactionLegRecord`
  ///   saves. Empty input short-circuits — `IN ()` would be a syntax
  ///   error and a full table scan is the wrong default for a
  ///   per-fetch hook.
  @discardableResult
  func dedup(touchedExternalIds: Set<String>) async throws -> Int {
    guard !touchedExternalIds.isEmpty else { return 0 }
    let signpostID = OSSignpostID(log: Signposts.cryptoSync)
    os_signpost(
      .begin,
      log: Signposts.cryptoSync,
      name: "crossDeviceLegDeduper.dedup",
      signpostID: signpostID,
      "%{public}d touched ids",
      touchedExternalIds.count)
    defer {
      os_signpost(
        .end,
        log: Signposts.cryptoSync,
        name: "crossDeviceLegDeduper.dedup",
        signpostID: signpostID)
    }
    let candidates = try await transactions.transactions(
      touchingExternalIds: touchedExternalIds)
    guard candidates.count > 1 else { return 0 }

    let plan = Self.planCollapse(
      candidates: candidates, touchedExternalIds: touchedExternalIds)

    var deletedCount = 0
    for transactionId in plan.transactionsToDelete {
      do {
        try await transactions.delete(id: transactionId)
        deletedCount += 1
      } catch {
        // A transient delete failure leaves the duplicate in place. The
        // next CKSyncEngine fetch will re-run the deduper and try
        // again, and the deterministic tiebreak guarantees the same
        // canonical wins on retry. Don't propagate — the rest of the
        // sweep should still make progress on independent groups.
        logger.error(
          "Failed to delete duplicate transaction \(transactionId, privacy: .public): \(error, privacy: .public)"
        )
      }
    }
    if !plan.skippedMixed.isEmpty {
      logger.warning(
        """
        Skipped \(plan.skippedMixed.count, privacy: .public) transaction(s) \
        with mixed duplicate + unique legs — per-leg dedup within a single \
        transaction is out of scope for v1
        """)
    }
    return deletedCount
  }

  // MARK: - Planning

  /// Group key used to detect cross-device duplicate legs. Both fields
  /// must be non-nil for a leg to participate — manual transactions
  /// (no `externalId`) and orphaned legs (no `accountId`) are immune.
  struct GroupKey: Hashable {
    let accountId: UUID
    let externalId: String
  }

  /// The output of `planCollapse`: which transactions to route through
  /// `delete(id:)` and which were skipped because they have a mix of
  /// duplicate and unique legs (out of scope for v1).
  struct CollapsePlan: Equatable {
    var transactionsToDelete: [UUID]
    var skippedMixed: [UUID]
  }

  /// Decides which transactions are duplicates ready for deletion vs.
  /// which are mixed (one duplicate leg + a non-duplicate leg).
  ///
  /// **Algorithm:**
  /// 1. Build groups keyed by `(accountId, externalId)` over candidate
  ///    legs whose `externalId` is in `touchedExternalIds`. Each group
  ///    holds the set of transaction ids whose legs land there.
  /// 2. For groups with more than one transaction, the canonical
  ///    winner is the lowest `Transaction.id` by lex-order of the
  ///    lowercase UUID string. Every device runs the same tiebreak
  ///    over the same set of UUIDs and therefore picks the same
  ///    survivor.
  /// 3. A transaction is *wholly* duplicate (safe to delete) when every
  ///    one of its legs is a participant of some multi-transaction
  ///    group that it lost. A transaction with even one leg outside
  ///    any duplicate group — for example, a unique-`externalId` leg
  ///    or a leg without an `externalId` at all — is *mixed* and
  ///    skipped: deleting it would lose the unique leg.
  ///
  /// Output is sorted by `uuidString.lowercased()` so the operation
  /// order is stable across runs (deterministic-across-run-order test
  /// invariant). Sorting is locale-independent because the lowercase
  /// hex-only alphabet is unaffected by locale rules.
  static func planCollapse(
    candidates: [Transaction],
    touchedExternalIds: Set<String>
  ) -> CollapsePlan {
    let groups = Self.buildGroups(
      candidates: candidates, touchedExternalIds: touchedExternalIds)

    // For each multi-transaction group, find the canonical winner and
    // mark the rest as "lost this group".
    var lossesByTxn: [UUID: Int] = [:]
    for (_, txnIds) in groups where txnIds.count > 1 {
      let canonical = canonicalWinner(among: txnIds)
      for txnId in txnIds where txnId != canonical {
        lossesByTxn[txnId, default: 0] += 1
      }
    }

    // A losing transaction is wholly-duplicate iff every one of its
    // legs is a duplicate (lost-group participant) — i.e. no unique
    // legs would be lost by deleting it. Walking the candidates'
    // legs gives us the per-transaction leg count; comparing it to
    // the lost-group count classifies the transaction.
    var toDelete: [UUID] = []
    var skipped: [UUID] = []
    for transaction in candidates {
      let losses = lossesByTxn[transaction.id, default: 0]
      guard losses > 0 else { continue }
      let duplicateLegCount = duplicateLegCount(
        transaction: transaction,
        groups: groups,
        touchedExternalIds: touchedExternalIds)
      if duplicateLegCount == transaction.legs.count {
        toDelete.append(transaction.id)
      } else {
        skipped.append(transaction.id)
      }
    }
    toDelete.sort { $0.uuidString.lowercased() < $1.uuidString.lowercased() }
    skipped.sort { $0.uuidString.lowercased() < $1.uuidString.lowercased() }
    return CollapsePlan(transactionsToDelete: toDelete, skippedMixed: skipped)
  }

  /// Builds the `(accountId, externalId) → {transactionIds}` map
  /// scoped to legs whose `externalId` is in `touchedExternalIds`.
  static func buildGroups(
    candidates: [Transaction],
    touchedExternalIds: Set<String>
  ) -> [GroupKey: Set<UUID>] {
    var groups: [GroupKey: Set<UUID>] = [:]
    for transaction in candidates {
      for leg in transaction.legs {
        guard let accountId = leg.accountId,
          let externalId = leg.externalId,
          touchedExternalIds.contains(externalId)
        else { continue }
        let key = GroupKey(accountId: accountId, externalId: externalId)
        groups[key, default: []].insert(transaction.id)
      }
    }
    return groups
  }

  /// Counts a transaction's legs that participate in a multi-
  /// transaction group keyed by `(accountId, externalId)`. Used to
  /// distinguish wholly-duplicate transactions from mixed ones.
  private static func duplicateLegCount(
    transaction: Transaction,
    groups: [GroupKey: Set<UUID>],
    touchedExternalIds: Set<String>
  ) -> Int {
    var count = 0
    for leg in transaction.legs {
      guard let accountId = leg.accountId,
        let externalId = leg.externalId,
        touchedExternalIds.contains(externalId)
      else { continue }
      let key = GroupKey(accountId: accountId, externalId: externalId)
      if let groupTxns = groups[key], groupTxns.count > 1 {
        count += 1
      }
    }
    return count
  }

  /// Lex-min `transaction.id.uuidString.lowercased()`. UUIDv4 ids on
  /// every device share the same alphabet, and `lowercased()` is
  /// locale-independent for the hex-only character set, so every
  /// device's deduper picks the same survivor.
  static func canonicalWinner(among ids: Set<UUID>) -> UUID {
    // `Set` is unordered; pick the lex-min explicitly so the result is
    // deterministic. Force-unwrap: callers gate on `txnIds.count > 1`.
    guard let winner = ids.min(by: { $0.uuidString.lowercased() < $1.uuidString.lowercased() })
    else {
      preconditionFailure("canonicalWinner called with empty id set")
    }
    return winner
  }
}
