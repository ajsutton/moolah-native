import Foundation

/// Contract every CSV source-specific (or generic) parser implements. The
/// registry picks the first parser whose `recognizes(headers:)` returns true;
/// `GenericBankCSVParser` is the fallback.
///
/// Parsers are pure value types that run off the main actor — they must not
/// touch any repository or UI state.
protocol CSVParser: Sendable {
  /// Stable identifier, e.g. `"generic-bank"`, `"selfwealth"`. Stored on
  /// `ImportOrigin.parserIdentifier` for audit and on `CSVImportProfile` so a
  /// file downloaded later routes through the same parser.
  var identifier: String { get }

  /// Called with the file's normalised headers (lowercased + trimmed, per
  /// `CSVImportProfile.normalise`). Return true only if this parser can parse
  /// every row of a file with these headers.
  func recognizes(headers: [String]) -> Bool

  /// Parse the rows (header row already consumed). Whole-file-or-nothing: if
  /// any row fails, throw. Rows that should be silently dropped return
  /// `ParsedRecord.skip(reason:)`.
  func parse(rows: [[String]]) throws -> [ParsedRecord]
}

/// Common error shape for parser failures. Concrete parsers may throw their
/// own errors too; these three are the expected whole-file rejection paths.
enum CSVParserError: Error, Equatable, Sendable {
  case headerMismatch
  case malformedRow(index: Int, reason: String)
  case emptyFile
}
