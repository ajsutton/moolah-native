import Foundation

/// Column-inferred CSV parser for bank exports. Scope (per spec): single-leg,
/// single-currency rows. Header-name heuristics resolve Date / Amount /
/// Debit / Credit / Description / Balance / Reference. Date format is
/// auto-detected from the value shape.
///
/// Whole-file-or-nothing: any malformed row throws; there is no partial-import
/// path. Recognised summary rows (`Total`, `Summary`, …) emit `.skip` rather
/// than throwing so bank exports that include a footer still parse cleanly.
///
/// Cash-leg instrument is populated with the placeholder `AUD` value; the
/// orchestration step (ImportStore, Phase E) rewrites it to match the target
/// account's instrument after profile routing.
struct GenericBankCSVParser: CSVParser, Sendable {

  let identifier = "generic-bank"

  /// Column mapping derived from the header row.
  struct ColumnMapping: Sendable, Equatable {
    var date: Int
    var description: Int
    var amount: Int?
    var debit: Int?
    var credit: Int?
    var balance: Int?
    var reference: Int?
    var dateFormat: DateFormat
    /// True when multiple date formats could plausibly fit the sampled rows.
    /// The setup form surfaces this so the user can override.
    var dateFormatAmbiguous: Bool
  }

  enum DateFormat: Sendable, Equatable {
    case ddMMyyyy(separator: Character)
    case mmDDyyyy(separator: Character)
    case iso

    var formatString: String {
      switch self {
      case .ddMMyyyy(let sep): return "dd\(sep)MM\(sep)yyyy"
      case .mmDDyyyy(let sep): return "MM\(sep)dd\(sep)yyyy"
      case .iso: return "yyyy-MM-dd"
      }
    }

    /// Stable string form used to persist the user's override on
    /// `CSVImportProfile.dateFormatRawValue`. The shape is the
    /// `DateFormatter` pattern so round-tripping is lossless.
    var rawValue: String { formatString }

    /// Parse a persisted `dateFormatRawValue` back into a concrete case.
    /// Returns nil for unknown patterns — callers fall back to auto-detect.
    static func fromRawValue(_ value: String) -> DateFormat? {
      switch value {
      case "dd/MM/yyyy": return .ddMMyyyy(separator: "/")
      case "dd-MM-yyyy": return .ddMMyyyy(separator: "-")
      case "MM/dd/yyyy": return .mmDDyyyy(separator: "/")
      case "MM-dd-yyyy": return .mmDDyyyy(separator: "-")
      case "yyyy-MM-dd": return .iso
      default: return nil
      }
    }
  }

  func recognizes(headers: [String]) -> Bool {
    inferMapping(from: headers, sampleRows: []) != nil
  }

  func parse(rows: [[String]]) throws -> [ParsedRecord] {
    try parse(rows: rows, overrideDateFormat: nil)
  }

  /// Parse variant that lets the caller force the date format (Needs Setup
  /// form on an ambiguous file). `nil` = auto-detect as normal.
  func parse(
    rows: [[String]], overrideDateFormat: DateFormat?
  ) throws -> [ParsedRecord] {
    guard !rows.isEmpty, let headers = rows.first else { throw CSVParserError.emptyFile }
    let sample = Array(rows.dropFirst().prefix(5))
    guard var mapping = inferMapping(from: headers, sampleRows: sample) else {
      throw CSVParserError.headerMismatch
    }
    if let override = overrideDateFormat {
      mapping.dateFormat = override
      mapping.dateFormatAmbiguous = false
    }
    return try parseRows(rows, with: mapping)
  }

  /// Parse variant that takes a fully-formed `ColumnMapping` from the Needs
  /// Setup form — bypasses the detector so the user's role overrides are
  /// authoritative.
  func parse(
    rows: [[String]], overrideMapping: ColumnMapping
  ) throws -> [ParsedRecord] {
    guard !rows.isEmpty else { throw CSVParserError.emptyFile }
    return try parseRows(rows, with: overrideMapping)
  }

  /// Shared row-loop implementation used by all `parse` variants.
  private func parseRows(
    _ rows: [[String]], with mapping: ColumnMapping
  ) throws -> [ParsedRecord] {
    var results: [ParsedRecord] = []
    for (offset, row) in rows.dropFirst().enumerated() {
      let rowIndex = offset + 1  // 1-based for user-facing error messages
      if row.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) {
        results.append(.skip(reason: "blank row"))
        continue
      }
      let record = try parseDataRow(row, mapping: mapping, rowIndex: rowIndex)
      results.append(record)
    }
    return results
  }

  private func parseDataRow(
    _ row: [String], mapping: ColumnMapping, rowIndex: Int
  ) throws -> ParsedRecord {
    let dateString = safe(row, mapping.date)
    guard let date = parseDate(dateString, format: mapping.dateFormat) else {
      let descField = safe(row, mapping.description).lowercased()
      if descField.contains("total") || descField.contains("summary") {
        return .skip(reason: "summary row")
      }
      throw CSVParserError.malformedRow(
        index: rowIndex, reason: "invalid date: \(dateString)", row: row)
    }
    guard let amount = try parseRowAmount(row, mapping: mapping, rowIndex: rowIndex) else {
      // Row has neither debit nor credit — the opening-balance pattern
      // (CBA includes an empty amount row with only a balance). Emit a
      // skip so the file still parses.
      return .skip(reason: "row has no debit or credit value")
    }
    let desc = safe(row, mapping.description)
    let balance = mapping.balance.flatMap { parseAmount(safe(row, $0)) }
    let bankRef: String? = {
      guard let idx = mapping.reference else { return nil }
      let value = safe(row, idx).trimmingCharacters(in: .whitespaces)
      return value.isEmpty ? nil : value
    }()

    let leg = ParsedLeg(
      accountId: nil,
      instrument: .AUD,
      quantity: amount,
      type: amount >= 0 ? .income : .expense,
      isInstrumentPlaceholder: true)
    let transaction = ParsedTransaction(
      date: date,
      legs: [leg],
      rawRow: row,
      rawDescription: desc,
      rawAmount: amount,
      rawBalance: balance,
      bankReference: bankRef)
    return .transaction(transaction)
  }

  private func parseRowAmount(
    _ row: [String], mapping: ColumnMapping, rowIndex: Int
  ) throws -> Decimal? {
    if let amountIdx = mapping.amount {
      let amountField = safe(row, amountIdx)
      guard let parsed = parseAmount(amountField) else {
        throw CSVParserError.malformedRow(
          index: rowIndex, reason: "invalid amount: \(amountField)", row: row)
      }
      return parsed
    }
    let debitValue = mapping.debit.flatMap { parseAmount(safe(row, $0)) } ?? 0
    let creditValue = mapping.credit.flatMap { parseAmount(safe(row, $0)) } ?? 0
    if debitValue == 0 && creditValue == 0 {
      return nil
    }
    return creditValue != 0 ? creditValue : -abs(debitValue)
  }

  // MARK: - Inference

  /// Infer the column mapping + date format from the headers and up to 5
  /// sample rows. Returns nil when required columns (date + description +
  /// amount-ish) are missing.
  func inferMapping(from headers: [String], sampleRows: [[String]]) -> ColumnMapping? {
    let normalised = headers.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }

    func find(_ candidates: [String]) -> Int? {
      for (index, header) in normalised.enumerated()
      where candidates.contains(where: { header.contains($0) }) {
        return index
      }
      return nil
    }

    guard let dateIdx = find(["transaction date", "txn date", "date"]),
      let descIdx = find(["description", "narrative", "memo", "details"])
    else { return nil }

    // Headers have already been trimmed, so space-padded candidates never
    // match. `findExact` catches the bare `Dr`/`Cr` column case.
    let debitIdx = find(["debit amount", "debit"]) ?? findExact(normalised, "dr")
    let creditIdx = find(["credit amount", "credit"]) ?? findExact(normalised, "cr")
    // Prefer a D/C split when both columns are explicitly named (banks like
    // Macquarie use "Debit Amount" / "Credit Amount"). Otherwise look for a
    // single signed "Amount" column. "Running Bal." stays with balance.
    let hasDrCr = debitIdx != nil && creditIdx != nil
    let amountIdx: Int? = hasDrCr ? nil : find(["amount", "value"])
    let balanceIdx = find(["running bal", "balance", "bal"])
    let referenceIdx = find(["reference", "ref"])

    let hasAmount = amountIdx != nil
    guard hasAmount || hasDrCr else { return nil }

    let (detected, ambiguous) = detectDateFormat(
      columnIndex: dateIdx, sampleRows: sampleRows)

    return ColumnMapping(
      date: dateIdx,
      description: descIdx,
      amount: amountIdx,
      debit: debitIdx,
      credit: creditIdx,
      balance: balanceIdx,
      reference: referenceIdx,
      dateFormat: detected,
      dateFormatAmbiguous: ambiguous)
  }

  private func findExact(_ headers: [String], _ target: String) -> Int? {
    headers.firstIndex(of: target)
  }

  /// Returns (detectedFormat, isAmbiguous). Rules:
  /// - ISO (`YYYY-MM-DD`) wins if any sampled date starts with a 4-digit year.
  /// - Otherwise the separator is `/` or `-` (first separator seen wins).
  /// - First component > 12 anywhere → must be DD/MM.
  /// - Second component > 12 anywhere → must be MM/DD.
  /// - If neither signal fires, default to DD/MM and flag ambiguous.
  private func detectDateFormat(
    columnIndex: Int, sampleRows: [[String]]
  ) -> (DateFormat, Bool) {
    let signals = scanDateSignals(columnIndex: columnIndex, sampleRows: sampleRows)
    return decideDateFormat(signals: signals)
  }

  /// Signals gathered from a single pass over sample date cells.
  private struct DateFormatSignals {
    var separator: Character = "/"
    var sawSeparator = false
    var firstGreaterThan12 = false
    var secondGreaterThan12 = false
    var anyIsoShaped = false
  }

  private func scanDateSignals(
    columnIndex: Int, sampleRows: [[String]]
  ) -> DateFormatSignals {
    var signals = DateFormatSignals()
    for row in sampleRows {
      guard columnIndex >= 0, columnIndex < row.count else { continue }
      let value = row[columnIndex].trimmingCharacters(in: .whitespaces)
      if value.isEmpty { continue }
      if isISOShaped(value) {
        signals.anyIsoShaped = true
        continue
      }
      let chosen: Character? = value.contains("/") ? "/" : (value.contains("-") ? "-" : nil)
      guard let sep = chosen else { continue }
      if !signals.sawSeparator {
        signals.separator = sep
        signals.sawSeparator = true
      }
      let components = value.split(separator: sep)
      guard components.count == 3,
        let first = Int(components[0]),
        let second = Int(components[1])
      else { continue }
      if first > 12 { signals.firstGreaterThan12 = true }
      if second > 12 { signals.secondGreaterThan12 = true }
    }
    return signals
  }

  private func decideDateFormat(signals: DateFormatSignals) -> (DateFormat, Bool) {
    if signals.anyIsoShaped { return (.iso, false) }
    let sep = signals.separator
    switch (signals.firstGreaterThan12, signals.secondGreaterThan12) {
    case (true, false):
      return (.ddMMyyyy(separator: sep), false)
    case (false, true):
      return (.mmDDyyyy(separator: sep), false)
    case (true, true):
      // Both invalid — caller's parse step will throw on the first row.
      return (.ddMMyyyy(separator: sep), false)
    case (false, false):
      return (.ddMMyyyy(separator: sep), true)
    }
  }

  private func isISOShaped(_ value: String) -> Bool {
    value.count == 10
      && value[value.index(value.startIndex, offsetBy: 4)] == "-"
      && value[value.index(value.startIndex, offsetBy: 7)] == "-"
  }

}

// Field-level parsing helpers extracted into an extension so the main struct
// body stays under SwiftLint's `type_body_length` threshold.
extension GenericBankCSVParser {
  // MARK: - Parsing helpers

  func safe(_ row: [String], _ index: Int) -> String {
    index >= 0 && index < row.count ? row[index] : ""
  }

  func parseAmount(_ field: String) -> Decimal? {
    var value = field.trimmingCharacters(in: .whitespaces)
    if value.isEmpty { return nil }
    value = value.replacingOccurrences(of: "$", with: "")
    value = value.replacingOccurrences(of: "£", with: "")
    value = value.replacingOccurrences(of: "€", with: "")
    value = value.replacingOccurrences(of: ",", with: "")
    // Parenthesised negatives: (12.34) → -12.34
    if value.hasPrefix("(") && value.hasSuffix(")") {
      value = "-" + value.dropFirst().dropLast()
    }
    return Decimal(string: value)
  }

  func parseDate(_ field: String, format: DateFormat) -> Date? {
    let trimmed = field.trimmingCharacters(in: .whitespaces)
    if trimmed.isEmpty { return nil }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.dateFormat = format.formatString
    return formatter.date(from: trimmed)
  }
}
