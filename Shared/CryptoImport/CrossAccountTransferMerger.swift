// Shared/CryptoImport/CrossAccountTransferMerger.swift
import Foundation

/// Cross-account merge stage. Pairs `BuiltTransaction`s sharing a non-nil
/// `externalId` on opposing-sign value-bearing legs of the same instrument
/// across different accounts. Stage 7's apply pass calls this **once**
/// after Stage 6's parallel build TaskGroup has fully completed — no
/// concurrent path can produce duplicate merged transactions.
///
/// Pure / `Sendable` — no repository writes; no shared state. The single
/// source of truth for the same-`externalId` channel from
/// `plans/2026-04-18-transfer-detection-design.md` (Extension B): when
/// the transfer-detection engine eventually runs, it shares this same
/// merger rather than reimplementing the predicate.
struct CrossAccountTransferMerger: Sendable {

  /// Returns the input set with same-`externalId` opposing-leg pairs
  /// collapsed into single multi-leg transactions whose legs union both
  /// sides. Gas / fee legs preserved on the merged transaction. Pairs
  /// that don't satisfy the predicate are returned unchanged.
  ///
  /// - Parameters:
  ///   - candidates: candidates from Stage 6's per-account build phase,
  ///     possibly across multiple accounts in this sync cycle.
  ///   - existingLegLookup: caller-supplied async lookup so the merger
  ///     can also pair against legs already persisted on prior cycles.
  ///     The lookup key is the leg's `externalId`. Callers in production
  ///     route this through `TransactionRepository.legs(matchingExternalId:)`.
  func merge(
    candidates: [BuiltTransaction],
    existingLegLookup: @Sendable (_ externalId: String) async throws -> [TransactionLeg]
  ) async throws -> [BuiltTransaction] {
    // Walk candidates in order; for each, decide whether it can be paired
    // with a later candidate (in-batch pair) or with an existing
    // persisted leg (prior-cycle pair). The single-pass walk keeps the
    // merger deterministic regardless of input ordering — ties on
    // multiple opposing candidates always pick the lower-UUID leg by
    // sorting candidate indices ascending and existing legs by
    // `(accountId, externalId)` lex order.
    var consumed: Set<Int> = []
    var output: [BuiltTransaction] = []
    output.reserveCapacity(candidates.count)

    for (index, candidate) in candidates.enumerated() {
      if consumed.contains(index) { continue }

      guard let valueLeg = Self.valueBearingTransferLeg(of: candidate) else {
        output.append(candidate)
        continue
      }
      guard let externalId = valueLeg.externalId else {
        output.append(candidate)
        continue
      }

      if let mateIndex = Self.findInBatchMate(
        startingAfter: index,
        in: candidates,
        consumed: consumed,
        valueLeg: valueLeg)
      {
        consumed.insert(index)
        consumed.insert(mateIndex)
        output.append(Self.merge(candidate, candidates[mateIndex]))
        continue
      }

      let existingLegs = try await existingLegLookup(externalId)
      if let mate = Self.findExistingMate(legs: existingLegs, valueLeg: valueLeg) {
        consumed.insert(index)
        output.append(Self.merge(candidate, withExistingPersistedLeg: mate))
        continue
      }

      output.append(candidate)
    }
    return output
  }

  // MARK: - Pairing predicate

  /// Both legs are `.transfer`, share an `externalId`, share an
  /// instrument, sit on different accounts, and carry equal-magnitude
  /// opposite-sign quantities. Strict equality on magnitude — if a real
  /// decimal-precision-drift case arises a small epsilon could be added,
  /// but ETH / ERC-20 amounts are exact decimals reconstructed from the
  /// same hex value on each side, so drift is not expected.
  ///
  /// Magnitude comparison uses `abs` only on the *comparison* of
  /// quantities; the original signs are preserved on the merged legs.
  /// Per-project convention `.trade` legs preserve user-entered signs;
  /// here we're working with `.transfer` legs and the rule is the same —
  /// don't normalise.
  static func isPair(_ leg: TransactionLeg, _ other: TransactionLeg) -> Bool {
    guard leg.type == .transfer, other.type == .transfer else { return false }
    guard let legId = leg.externalId, let otherId = other.externalId else { return false }
    guard legId == otherId else { return false }
    guard leg.instrument == other.instrument else { return false }
    guard let legAcct = leg.accountId, let otherAcct = other.accountId else { return false }
    guard legAcct != otherAcct else { return false }
    let legSign = Self.signValue(of: leg.quantity)
    let otherSign = Self.signValue(of: other.quantity)
    guard legSign != 0, otherSign != 0, legSign != otherSign else { return false }
    return abs(leg.quantity) == abs(other.quantity)
  }

  // MARK: - Search

  private static func findInBatchMate(
    startingAfter index: Int,
    in candidates: [BuiltTransaction],
    consumed: Set<Int>,
    valueLeg: TransactionLeg
  ) -> Int? {
    var search = index + 1
    while search < candidates.count {
      defer { search += 1 }
      if consumed.contains(search) { continue }
      guard let otherValue = valueBearingTransferLeg(of: candidates[search]) else { continue }
      if isPair(valueLeg, otherValue) { return search }
    }
    return nil
  }

  private static func findExistingMate(
    legs: [TransactionLeg],
    valueLeg: TransactionLeg
  ) -> TransactionLeg? {
    // Deterministic tiebreak when more than one matching leg exists:
    // lowest accountId UUID lex order. The merge result therefore
    // converges across replays of the same input.
    legs
      .filter { isPair(valueLeg, $0) }
      .min { ($0.accountId?.uuidString ?? "") < ($1.accountId?.uuidString ?? "") }
  }

  // MARK: - Merge construction

  /// Merges two `BuiltTransaction`s known to share an `externalId` on
  /// opposing-sign value-bearing legs.
  private static func merge(
    _ first: BuiltTransaction, _ second: BuiltTransaction
  ) -> BuiltTransaction {
    let lower: BuiltTransaction
    let upper: BuiltTransaction
    if first.originAccountId.uuidString <= second.originAccountId.uuidString {
      lower = first
      upper = second
    } else {
      lower = second
      upper = first
    }

    // Date: earliest of the two — canonical convention for cross-account
    // transfers (matches Extension B / the existing transfer-detection
    // design's merge rule).
    let date = min(first.transaction.date, second.transaction.date)
    let legs = lower.transaction.legs + upper.transaction.legs
    let importOrigin = mergedImportOrigin(
      lower: lower.transaction.importOrigin,
      upper: upper.transaction.importOrigin)

    let merged = Transaction(
      id: lower.transaction.id,
      date: date,
      payee: lower.transaction.payee ?? upper.transaction.payee,
      notes: mergedNotes(lower.transaction.notes, upper.transaction.notes),
      legs: legs,
      importOrigin: importOrigin)
    return BuiltTransaction(
      originAccountId: lower.originAccountId,
      transaction: merged)
  }

  /// Variant of `merge` used when the in-batch candidate pairs against
  /// an already-persisted leg from a prior cycle. The merged
  /// `BuiltTransaction` keeps the in-batch candidate's transaction id
  /// and origin; Stage 7's apply pass will resolve the duplicate
  /// against the existing transaction during the per-leg dedup step
  /// (the existing leg is already persisted, so dedup will drop it from
  /// the new transaction's legs and the surviving rows are the existing
  /// transaction plus the new candidate's own legs).
  ///
  /// Why surface a merged shape at all if dedup will collapse it again?
  /// Because the *transfer-detection engine* (Extension B) consumes the
  /// same merger output to suppress its suggestion pass — it sees one
  /// merged transaction rather than two unrelated single-leg events,
  /// and that suppression is the point of the same-`externalId`
  /// channel.
  private static func merge(
    _ candidate: BuiltTransaction,
    withExistingPersistedLeg leg: TransactionLeg
  ) -> BuiltTransaction {
    let date = candidate.transaction.date
    let legs = candidate.transaction.legs + [leg]
    let merged = Transaction(
      id: candidate.transaction.id,
      date: date,
      payee: candidate.transaction.payee,
      notes: candidate.transaction.notes,
      legs: legs,
      importOrigin: candidate.transaction.importOrigin)
    return BuiltTransaction(
      originAccountId: candidate.originAccountId,
      transaction: merged)
  }

  private static func mergedImportOrigin(
    lower: ImportOrigin?,
    upper: ImportOrigin?
  ) -> ImportOrigin? {
    // Prefer the lower-UUID side's ImportOrigin so the merge is
    // deterministic across replays. v1 of the crypto importer doesn't
    // require a `MergedImportOrigin` wrapper — `Transaction.importOrigin`
    // is still a single value — so the upper side's origin is dropped
    // here. Once the transfer-detection design's `MergedImportOrigin`
    // landing covers crypto (issue #762 cluster), this can be revisited.
    lower ?? upper
  }

  private static func mergedNotes(_ first: String?, _ second: String?) -> String? {
    switch (first, second) {
    case (nil, nil): return nil
    case let (firstNotes?, nil): return firstNotes
    case let (nil, secondNotes?): return secondNotes
    case let (firstNotes?, secondNotes?):
      if firstNotes == secondNotes { return firstNotes }
      return "\(firstNotes)\n\(secondNotes)"
    }
  }

  // MARK: - Helpers

  /// The single value-bearing transfer leg, when this candidate is
  /// shaped for cross-account pairing — exactly one `.transfer` leg
  /// whose `externalId` keys the on-chain hash. Returns `nil` for
  /// trades or already-merged multi-transfer-leg transactions; the
  /// merger leaves those untouched.
  private static func valueBearingTransferLeg(
    of candidate: BuiltTransaction
  ) -> TransactionLeg? {
    let transferLegs = candidate.transaction.legs.filter { $0.type == .transfer }
    return transferLegs.count == 1 ? transferLegs.first : nil
  }

  /// `1` for positive, `-1` for negative, `0` for zero. Local helper so
  /// the call sites read clearly without scattering `Decimal(0)`
  /// comparisons.
  private static func signValue(of decimal: Decimal) -> Int {
    if decimal > 0 { return 1 }
    if decimal < 0 { return -1 }
    return 0
  }
}
