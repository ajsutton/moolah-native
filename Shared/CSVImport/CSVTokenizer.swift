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
    var rows: [[String]] = []
    var field = ""
    var row: [String] = []
    var inQuotes = false
    var scalars = Substring(text).unicodeScalars[...]
    if scalars.first == "\u{FEFF}" { scalars = scalars.dropFirst() }
    var i = scalars.startIndex
    while i < scalars.endIndex {
      let c = scalars[i]
      if inQuotes {
        if c == "\"" {
          let next = scalars.index(after: i)
          if next < scalars.endIndex && scalars[next] == "\"" {
            field.append("\"")
            i = scalars.index(after: next)
            continue
          } else {
            inQuotes = false
            i = scalars.index(after: i)
            continue
          }
        }
        field.unicodeScalars.append(c)
        i = scalars.index(after: i)
        continue
      }
      switch c {
      case "\"":
        inQuotes = true
      case ",":
        row.append(field)
        field = ""
      case "\r":
        row.append(field)
        field = ""
        rows.append(row)
        row = []
        let next = scalars.index(after: i)
        if next < scalars.endIndex && scalars[next] == "\n" {
          i = next
        }
      case "\n":
        row.append(field)
        field = ""
        rows.append(row)
        row = []
      default:
        field.unicodeScalars.append(c)
      }
      i = scalars.index(after: i)
    }
    if !field.isEmpty || !row.isEmpty {
      row.append(field)
      rows.append(row)
    }
    return rows.filter { !($0.count == 1 && $0[0].isEmpty) }
  }

  /// Parse raw bytes: detect encoding via `CSVIngestionText.decode(_:)`, then tokenize.
  /// Throws if the bytes cannot be decoded to any known encoding.
  static func parse(_ data: Data) throws -> [[String]] {
    let text = try CSVIngestionText.decode(data)
    return parse(text)
  }
}
