import Foundation

/// Returns true if every whitespace-separated word in `query` appears as a
/// case-insensitive substring in `path`. An empty/whitespace-only query matches everything.
func matchesCategorySearch(_ path: String, query: String) -> Bool {
  let words = query.split(whereSeparator: \.isWhitespace)
  guard !words.isEmpty else { return true }
  let lowered = path.lowercased()
  return words.allSatisfy { lowered.contains($0.lowercased()) }
}
