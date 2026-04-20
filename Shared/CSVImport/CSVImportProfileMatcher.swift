import Foundation

/// Inputs for matching an incoming file to a stored `CSVImportProfile`. The
/// orchestrator (`ImportStore`, Phase E) owns the I/O — here everything is
/// already fetched, so the matcher is a pure function.
struct MatcherInput: Sendable {
  let filename: String?
  let parserIdentifier: String
  let headerSignature: [String]
  let candidates: [ParsedTransaction]
  /// For each candidate profile, the existing transactions on that profile's
  /// account. Only accessed when duplicate-overlap scoring fires.
  let existingByAccountId: [UUID: [Transaction]]
  let profiles: [CSVImportProfile]
}

/// Outcome of profile matching. `.routed` picks the single winning profile;
/// `.needsSetup` surfaces the file to the user for manual attachment. The
/// nested `Reason` explains why the file couldn't auto-route.
enum MatcherResult: Sendable, Equatable {
  case routed(CSVImportProfile)
  case needsSetup(reason: Reason)

  enum Reason: Sendable, Equatable {
    case noMatchingProfile
    case ambiguousMatch(tiedProfileIds: [UUID])
  }
}

/// Maps an incoming file to a single stored `CSVImportProfile`. Three cases:
/// 1. Zero profiles match the `(parserIdentifier, headerSignature)` key → Needs Setup.
/// 2. Exactly one match → `.routed(profile)`.
/// 3. Multiple matches → score each by duplicate overlap against its
///    account's existing transactions, then tiebreak with the filename
///    pattern. Still tied → `.needsSetup(.ambiguousMatch(…))`.
enum CSVImportProfileMatcher {

  static func match(_ input: MatcherInput) -> MatcherResult {
    let normalisedSignature = input.headerSignature.map { CSVImportProfile.normalise($0) }
    let candidates = input.profiles.filter {
      $0.parserIdentifier == input.parserIdentifier
        && $0.headerSignature == normalisedSignature
    }
    switch candidates.count {
    case 0:
      return .needsSetup(reason: .noMatchingProfile)
    case 1:
      return .routed(candidates[0])
    default:
      return disambiguate(candidates: candidates, input: input)
    }
  }

  private static func disambiguate(
    candidates: [CSVImportProfile], input: MatcherInput
  ) -> MatcherResult {
    let scored: [(profile: CSVImportProfile, overlap: Int)] = candidates.map { profile in
      let existing = input.existingByAccountId[profile.accountId] ?? []
      let dedup = CSVDeduplicator.filter(
        input.candidates, against: existing, accountId: profile.accountId)
      return (profile, dedup.skipped.count)
    }
    guard let topScore = scored.map({ $0.overlap }).max() else {
      return .needsSetup(reason: .noMatchingProfile)
    }
    let topEntries = scored.filter { $0.overlap == topScore && $0.overlap > 0 }
    if topEntries.count == 1 {
      return .routed(topEntries[0].profile)
    }

    // Either no overlap at all (topScore == 0) or multi-way tie.
    let tied = topEntries.isEmpty ? scored : topEntries
    if let filename = input.filename {
      let matching = tied.filter { entry in
        filenameMatches(pattern: entry.profile.filenamePattern, filename: filename)
      }
      if matching.count == 1 {
        return .routed(matching[0].profile)
      }
    }
    return .needsSetup(reason: .ambiguousMatch(tiedProfileIds: tied.map(\.profile.id)))
  }

  /// Simple LIKE-style glob (`*` + `?`). `nil` pattern means "no filename
  /// tiebreaker available".
  private static func filenameMatches(pattern: String?, filename: String) -> Bool {
    guard let pattern, !pattern.isEmpty else { return false }
    return NSPredicate(format: "self LIKE[c] %@", pattern).evaluate(with: filename)
  }
}
