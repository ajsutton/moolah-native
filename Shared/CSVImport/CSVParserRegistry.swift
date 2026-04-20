import Foundation

/// Ordered list of CSV parsers. Source-specific parsers come first so a
/// SelfWealth export doesn't accidentally get picked up by `GenericBankCSVParser`;
/// the generic parser runs last as a catch-all.
///
/// If nothing recognises the headers, `select(for:)` still returns
/// `GenericBankCSVParser` — the unrecognised path feeds the file into the
/// Needs Setup pile where the user confirms the mapping.
struct CSVParserRegistry: Sendable {

  // `any CSVParser & Sendable` keeps the Sendable guarantee visible through
  // the existential. `CSVParser: Sendable` alone does not propagate to `any
  // CSVParser` under strict concurrency.
  let parsers: [any CSVParser & Sendable]

  static let `default` = CSVParserRegistry(parsers: [
    SelfWealthParser(),
    GenericBankCSVParser(),
  ])

  /// Returns the first registered parser that recognises the headers; falls
  /// back to `GenericBankCSVParser` so unrecognised files still reach the
  /// setup form.
  func select(for headers: [String]) -> any CSVParser & Sendable {
    for parser in parsers where parser.recognizes(headers: headers) {
      return parser
    }
    return GenericBankCSVParser()
  }
}
