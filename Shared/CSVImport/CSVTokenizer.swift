import Foundation

/// RFC-4180 CSV tokenizer. Handles BOM, CRLF/LF/CR line endings, quoted fields
/// with embedded commas, escaped double-quotes, and blank lines between rows.
///
/// Iteration is done over Unicode scalars rather than Swift `Character`s so
/// that `\r\n` (which Swift collapses into a single grapheme cluster) is
/// handled correctly.
enum CSVTokenizer: Sendable {

  /// Parse CSV text into rows. See type docs for handled edge cases.
  static func parse(_ text: String) -> [[String]] {
    var state = ParseState()
    var scalars = Substring(text).unicodeScalars[...]
    if scalars.first == "\u{FEFF}" { scalars = scalars.dropFirst() }
    var i = scalars.startIndex
    while i < scalars.endIndex {
      let c = scalars[i]
      if state.inQuotes {
        i = handleQuoted(c, at: i, in: scalars, state: &state)
      } else {
        i = handleUnquoted(c, at: i, in: scalars, state: &state)
      }
    }
    if !state.field.isEmpty || !state.row.isEmpty {
      state.row.append(state.field)
      state.rows.append(state.row)
    }
    return state.rows.filter { !($0.count == 1 && $0[0].isEmpty) }
  }

  /// Mutable parser state — kept together so the per-scalar helpers can thread
  /// it via a single `inout` parameter.
  private struct ParseState {
    var rows: [[String]] = []
    var field = ""
    var row: [String] = []
    var inQuotes = false
  }

  /// Handle one scalar inside a quoted field; returns the next scanner index.
  private static func handleQuoted(
    _ scalar: Unicode.Scalar,
    at i: String.UnicodeScalarView.SubSequence.Index,
    in scalars: Substring.UnicodeScalarView.SubSequence,
    state: inout ParseState
  ) -> String.UnicodeScalarView.SubSequence.Index {
    if scalar == "\"" {
      let next = scalars.index(after: i)
      if next < scalars.endIndex && scalars[next] == "\"" {
        state.field.append("\"")
        return scalars.index(after: next)
      }
      state.inQuotes = false
      return scalars.index(after: i)
    }
    state.field.unicodeScalars.append(scalar)
    return scalars.index(after: i)
  }

  /// Handle one scalar outside a quoted field; returns the next scanner index.
  private static func handleUnquoted(
    _ scalar: Unicode.Scalar,
    at i: String.UnicodeScalarView.SubSequence.Index,
    in scalars: Substring.UnicodeScalarView.SubSequence,
    state: inout ParseState
  ) -> String.UnicodeScalarView.SubSequence.Index {
    var i = i
    switch scalar {
    case "\"":
      state.inQuotes = true
    case ",":
      state.row.append(state.field)
      state.field = ""
    case "\r":
      finishRow(state: &state)
      let next = scalars.index(after: i)
      if next < scalars.endIndex && scalars[next] == "\n" {
        i = next
      }
    case "\n":
      finishRow(state: &state)
    default:
      state.field.unicodeScalars.append(scalar)
    }
    return scalars.index(after: i)
  }

  private static func finishRow(state: inout ParseState) {
    state.row.append(state.field)
    state.field = ""
    state.rows.append(state.row)
    state.row = []
  }

  /// Parse raw bytes: detect encoding via `CSVIngestionText.decode(_:)`, then tokenize.
  /// Throws if the bytes cannot be decoded to any known encoding.
  static func parse(_ data: Data) throws -> [[String]] {
    let text = try CSVIngestionText.decode(data)
    return parse(text)
  }
}
