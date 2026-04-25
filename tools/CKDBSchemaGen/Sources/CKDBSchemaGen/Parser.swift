import Foundation

/// Parses a `.ckdb` file into a `Schema`. Handles only the subset of the
/// CloudKit schema language used by this project: `DEFINE SCHEMA`,
/// `RECORD TYPE Name (...)` blocks with fields, `GRANT` lines (ignored),
/// system fields starting with `___` (ignored except `___recordID`'s
/// indexes, which the parser drops because they are part of the standard
/// system-field block), `// DEPRECATED` markers on the line immediately
/// above a field or record-type declaration, and `LIST<INT64>`.
enum Parser {

  enum Error: Swift.Error, CustomStringConvertible {
    case malformed(String)
    case unknownFieldType(String, line: Int)

    var description: String {
      switch self {
      case .malformed(let message):
        return "malformed schema: \(message)"
      case .unknownFieldType(let raw, let line):
        return "unknown field type '\(raw)' at line \(line)"
      }
    }
  }

  /// Parses `.ckdb` source into a `Schema`. Throws `Error` on syntactic
  /// problems or unknown constructs.
  static func parse(_ source: String) throws -> Schema {
    let blockPattern = /RECORD\s+TYPE\s+(\w+)\s*\(([\s\S]*?)\)\s*;/.dotMatchesNewlines()
    var recordTypes: [RecordType] = []
    var any = false
    for match in source.matches(of: blockPattern) {
      any = true
      let name = String(match.output.1)
      let body = String(match.output.2)
      let typeIsDeprecated = isPrecededByDeprecated(
        index: match.range.lowerBound, in: source)
      let fields = try parseFields(body: body, source: source)
      recordTypes.append(RecordType(name: name, fields: fields, isDeprecated: typeIsDeprecated))
    }
    guard any else {
      throw Error.malformed("no RECORD TYPE blocks found")
    }
    return Schema(recordTypes: recordTypes)
  }

  // MARK: - Internals

  private static func parseFields(body: String, source: String) throws -> [Field] {
    var fields: [Field] = []
    var pendingDeprecated = false
    for rawLine in body.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
      let line = rawLine.trimmingCharacters(in: .whitespaces)
      if line.isEmpty { continue }
      if line.hasPrefix("//") {
        if line.contains("DEPRECATED") { pendingDeprecated = true }
        continue
      }
      if line.hasPrefix("GRANT") { continue }
      if line.hasPrefix("\"___") { continue }
      let trimmed = line.trimmingCharacters(in: CharacterSet(charactersIn: ","))
      guard let field = try parseFieldLine(trimmed, isDeprecated: pendingDeprecated) else {
        pendingDeprecated = false
        continue
      }
      fields.append(field)
      pendingDeprecated = false
    }
    return fields
  }

  /// A field line looks like `name TYPE [INDEX [INDEX ...]]`. `LIST<INT64>`
  /// counts as a single token even though it contains angle brackets.
  private static func parseFieldLine(_ line: String, isDeprecated: Bool) throws -> Field? {
    var tokens = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    guard tokens.count >= 2 else { return nil }
    let name = tokens.removeFirst()
    let rawType = tokens.removeFirst()
    let normalisedType = rawType.uppercased()
    guard let type = FieldType(rawValue: normalisedType) else {
      throw Error.unknownFieldType(rawType, line: 0)
    }
    var indexes: Set<FieldIndex> = []
    for token in tokens {
      let upper = token.uppercased()
      if let index = FieldIndex(rawValue: upper) {
        indexes.insert(index)
      } else {
        throw Error.malformed("unknown index attribute '\(token)' on field '\(name)'")
      }
    }
    return Field(name: name, type: type, indexes: indexes, isDeprecated: isDeprecated)
  }

  /// Returns true if the source has a `// DEPRECATED` line immediately
  /// before the given index (skipping blank lines).
  private static func isPrecededByDeprecated(
    index: String.Index, in source: String
  ) -> Bool {
    let prefix = source[..<index]
    let lines = prefix.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
    var i = lines.count - 1
    while i >= 0 {
      let line = lines[i].trimmingCharacters(in: .whitespaces)
      if line.isEmpty {
        i -= 1
        continue
      }
      return line.hasPrefix("//") && line.contains("DEPRECATED")
    }
    return false
  }
}
