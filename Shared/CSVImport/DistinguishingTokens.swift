import Foundation

/// Token distinctiveness helper for the "Create a rule from this…"
/// affordance. Given a single `description`, pick the tokens that appear
/// in it but are rare across the user's full corpus of raw descriptions.
/// Rare tokens are high-signal — "AMAZON", "NETFLIX" — whereas common
/// tokens like "EFTPOS" or "PURCHASE" aren't.
enum DistinguishingTokens {

  /// Up to `limit` tokens from `description` ranked by rarity in `corpus`.
  /// Numeric-only and single-character tokens are always filtered out.
  static func extract(
    from description: String, corpus: [String], limit: Int = 3
  ) -> [String] {
    let tokens = normalise(description)
    guard !tokens.isEmpty else { return [] }
    var frequency: [String: Int] = [:]
    for item in corpus {
      for token in Set(normalise(item)) {
        frequency[token, default: 0] += 1
      }
    }
    // Sort rarest first; stable on the original order from `description` so
    // two tokens tied on rarity pick the one that appeared first.
    let distinctTokens = Array(Set(tokens))
    let scored = distinctTokens.map { (token: $0, frequency: frequency[$0, default: 0]) }
    let sorted = scored.sorted { lhs, rhs in
      if lhs.frequency != rhs.frequency { return lhs.frequency < rhs.frequency }
      let lhsIndex = tokens.firstIndex(of: lhs.token) ?? Int.max
      let rhsIndex = tokens.firstIndex(of: rhs.token) ?? Int.max
      return lhsIndex < rhsIndex
    }
    return Array(sorted.prefix(limit).map { $0.token })
  }

  static func normalise(_ value: String) -> [String] {
    value.uppercased()
      .components(separatedBy: CharacterSet.alphanumerics.inverted)
      .filter { $0.count > 1 && !$0.allSatisfy(\.isNumber) }
  }
}
