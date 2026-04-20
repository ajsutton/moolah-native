import Foundation

/// Result of parsing a single CSV row. `.skip` is used when the row is
/// recognised but deliberately ignored (e.g. header sub-rows or summary
/// totals). Rows that fail to parse throw; they do not emit a `.skip`.
enum ParsedRecord: Sendable, Hashable {
  case transaction(ParsedTransaction)
  case skip(reason: String)
}
