import Foundation

/// Outcome of a dedup pass: which candidates should be imported, which were
/// matched to an existing transaction (and the id of that transaction, for
/// audit / diagnostic use).
struct CSVDedupResult: Sendable {
  var kept: [ParsedTransaction]
  var skipped: [SkipEntry]

  struct SkipEntry: Sendable {
    var candidate: ParsedTransaction
    /// id of the existing transaction that matched. For balance-alignment
    /// matches this is the id of the first sibling with the same `(date,
    /// rawAmount, rawBalance)`; layer 1 and layer 2 return their exact match.
    var matchedExistingId: UUID
    var layer: Layer
  }

  enum Layer: Sendable, Equatable {
    case bankReference
    case sameDateExactMatch
    case balanceAlignment
  }
}

/// Three-layer dedup pass (spec order — first match wins). Pure function; the
/// orchestrator (`ImportStore`) does the I/O of fetching `existing`.
///
/// - Layer 1 **Bank reference** — account-wide, no date constraint.
/// - Layer 2 **Same-date exact** — same account, same calendar day, same
///   `(normalisedRawDescription, rawAmount)`.
/// - Layer 3 **Balance alignment** — applies only when every candidate row is
///   single-leg single-currency AND every candidate has a non-nil
///   `rawBalance`. Any candidate whose `(date, rawAmount, rawBalance)` triple
///   matches an existing transaction is considered a duplicate. Fancier
///   running-balance continuity is deferred until fixtures demand it.
enum CSVDeduplicator {

  static func filter(
    _ candidates: [ParsedTransaction],
    against existing: [Transaction],
    accountId: UUID
  ) -> CSVDedupResult {
    let existingOnAccount = existing.filter { $0.accountIds.contains(accountId) }

    // Layer 1: bank reference lookup.
    let byRef: [String: Transaction] = existingOnAccount.reduce(into: [:]) { acc, tx in
      if let ref = tx.importOrigin?.bankReference, !ref.isEmpty, acc[ref] == nil {
        acc[ref] = tx
      }
    }

    // Layer 2: same-day bucketing.
    let calendar: Calendar = {
      var cal = Calendar(identifier: .gregorian)
      cal.timeZone = TimeZone(identifier: "UTC") ?? .current
      return cal
    }()
    func dayKey(_ date: Date) -> DateComponents {
      calendar.dateComponents([.year, .month, .day], from: date)
    }
    let byDate = Dictionary(grouping: existingOnAccount, by: { dayKey($0.date) })

    // Layer 3: applicability. All candidates single-leg AND every candidate
    // has a balance. Instrument uniformity is satisfied by single-leg per
    // spec — the pipeline rewrites the placeholder instrument before dedup.
    let allSingleLeg = candidates.allSatisfy { $0.legs.count == 1 }
    let allHaveBalance = candidates.allSatisfy { $0.rawBalance != nil }
    let runBalanceAlignment = allSingleLeg && allHaveBalance
    var balanceMatchedIndexes: [Int: UUID] = [:]
    if runBalanceAlignment {
      balanceMatchedIndexes = balanceAlignmentMatches(
        candidates: candidates,
        existing: existingOnAccount,
        dayKey: dayKey)
    }

    var kept: [ParsedTransaction] = []
    var skipped: [CSVDedupResult.SkipEntry] = []

    for (index, candidate) in candidates.enumerated() {
      if let reference = candidate.bankReference,
        !reference.isEmpty,
        let match = byRef[reference]
      {
        skipped.append(
          .init(
            candidate: candidate, matchedExistingId: match.id, layer: .bankReference))
        continue
      }
      if let sameDay = byDate[dayKey(candidate.date)],
        let match = sameDay.first(where: { tx in
          let origin = tx.importOrigin
          return normalise(origin?.rawDescription ?? "")
            == normalise(candidate.rawDescription)
            && (origin?.rawAmount ?? 0) == candidate.rawAmount
        })
      {
        skipped.append(
          .init(
            candidate: candidate, matchedExistingId: match.id, layer: .sameDateExactMatch))
        continue
      }
      if let matchedId = balanceMatchedIndexes[index] {
        skipped.append(
          .init(
            candidate: candidate, matchedExistingId: matchedId, layer: .balanceAlignment))
        continue
      }
      kept.append(candidate)
    }
    return CSVDedupResult(kept: kept, skipped: skipped)
  }

  /// Uppercase, trim, collapse all whitespace runs to a single space, and
  /// strip everything that isn't alphanumeric or whitespace. Bank descriptions
  /// that differ only in capitalisation or spacing collapse to the same key.
  static func normalise(_ value: String) -> String {
    let upper = value.uppercased()
    // Map non-alphanumeric, non-whitespace scalars to nothing; leave
    // whitespace so the split step below can collapse it.
    let whitespace = CharacterSet.whitespacesAndNewlines
    let filteredScalars = upper.unicodeScalars.filter { scalar in
      CharacterSet.alphanumerics.contains(scalar) || whitespace.contains(scalar)
    }
    let filtered = String(String.UnicodeScalarView(filteredScalars))
    let collapsed = filtered.split(whereSeparator: { $0.isWhitespace })
      .joined(separator: " ")
    return collapsed
  }

  private static func balanceAlignmentMatches(
    candidates: [ParsedTransaction],
    existing: [Transaction],
    dayKey: (Date) -> DateComponents
  ) -> [Int: UUID] {
    var matches: [Int: UUID] = [:]
    for (index, candidate) in candidates.enumerated() {
      guard let rawBalance = candidate.rawBalance else { continue }
      let sameDay = existing.filter { dayKey($0.date) == dayKey(candidate.date) }
      if let match = sameDay.first(where: { tx in
        let origin = tx.importOrigin
        return origin?.rawBalance == rawBalance && origin?.rawAmount == candidate.rawAmount
      }) {
        matches[index] = match.id
      }
    }
    return matches
  }
}
