// swiftlint:disable multiline_arguments

import Foundation

/// Parser for SelfWealth trade-history CSV exports.
///
/// Trade rows become two-leg transactions: one cash leg (AUD, expense for BUY
/// / income for SELL) plus one position leg on the stock instrument
/// (`ASX:TICKER`, quantity with BUY → income / SELL → expense). Dividends,
/// brokerage, GST, cash in/out, and interest each become single-leg AUD
/// transactions. Unknown `Type` values emit `.skip(reason:)` rather than
/// throwing — SelfWealth occasionally emits informational rows and the file
/// should still parse.
///
/// Task 15 (`ImportStore`) re-routes the placeholder instruments to the
/// account's own `Instrument` where relevant.
struct SelfWealthParser: CSVParser, Sendable {

  let identifier = "selfwealth"

  private static let requiredHeaders: Set<String> = [
    "date", "type", "description", "debit", "credit", "balance",
  ]

  func recognizes(headers: [String]) -> Bool {
    let normalised = Set(headers.map { $0.trimmingCharacters(in: .whitespaces).lowercased() })
    return Self.requiredHeaders.isSubset(of: normalised)
  }

  func parse(rows: [[String]]) throws -> [ParsedRecord] {
    guard let headers = rows.first else { throw CSVParserError.emptyFile }
    guard recognizes(headers: headers) else { throw CSVParserError.headerMismatch }
    let columns = try columnIndex(headers)

    var results: [ParsedRecord] = []
    for (offset, row) in rows.dropFirst().enumerated() {
      let rowIndex = offset + 1
      if row.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) {
        results.append(.skip(reason: "blank row"))
        continue
      }
      let record = try parseDataRow(row, columns: columns, rowIndex: rowIndex)
      results.append(record)
    }
    return results
  }

  private struct ParsedFields {
    let type: String
    let description: String
    let date: Date
    let cashAmount: Decimal
    let balance: Decimal?
  }

  private func parseDataRow(
    _ row: [String], columns: Columns, rowIndex: Int
  ) throws -> ParsedRecord {
    let type = safe(row, columns.type)
    let description = safe(row, columns.description)
    guard let date = parseDate(safe(row, columns.date)) else {
      throw CSVParserError.malformedRow(index: rowIndex, reason: "invalid date", row: row)
    }
    let debitValue = parseAmount(safe(row, columns.debit)) ?? 0
    let creditValue = parseAmount(safe(row, columns.credit)) ?? 0
    let balance = parseAmount(safe(row, columns.balance))
    let cashAmount: Decimal = creditValue != 0 ? creditValue : -abs(debitValue)

    let fields = ParsedFields(
      type: type, description: description, date: date,
      cashAmount: cashAmount, balance: balance)

    switch type.lowercased() {
    case "trade":
      return try parseTrade(fields: fields, row: row, index: rowIndex)
    case "dividend":
      return makeSimpleLegRecord(
        fields: fields, row: row, legType: .income, reference: dividendReference(for: description))
    case "brokerage", "gst on brokerage", "fee":
      return makeSimpleLegRecord(fields: fields, row: row, legType: .expense, reference: nil)
    case "cash in", "cash out", "interest":
      return makeSimpleLegRecord(
        fields: fields, row: row,
        legType: cashAmount >= 0 ? .income : .expense, reference: nil)
    default:
      return .skip(reason: "unknown type: \(type)")
    }
  }

  private func makeSimpleLegRecord(
    fields: ParsedFields,
    row: [String],
    legType: TransactionType,
    reference: String?
  ) -> ParsedRecord {
    let leg = ParsedLeg(
      accountId: nil,
      instrument: .AUD,
      quantity: fields.cashAmount,
      type: legType,
      isInstrumentPlaceholder: true)
    return .transaction(
      ParsedTransaction(
        date: fields.date,
        legs: [leg],
        rawRow: row,
        rawDescription: fields.description,
        rawAmount: fields.cashAmount,
        rawBalance: fields.balance,
        bankReference: reference))
  }

  // MARK: - Private

  private struct Columns {
    let date: Int
    let type: Int
    let description: Int
    let debit: Int
    let credit: Int
    let balance: Int
  }

  /// Precondition: `recognizes(headers:)` has already returned true for these
  /// headers. Every required column is present, so `firstIndex(of:)` cannot
  /// return nil here.
  private func columnIndex(_ headers: [String]) throws -> Columns {
    let normalised = headers.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
    guard let date = normalised.firstIndex(of: "date"),
      let type = normalised.firstIndex(of: "type"),
      let description = normalised.firstIndex(of: "description"),
      let debit = normalised.firstIndex(of: "debit"),
      let credit = normalised.firstIndex(of: "credit"),
      let balance = normalised.firstIndex(of: "balance")
    else {
      throw CSVParserError.headerMismatch
    }
    return Columns(
      date: date, type: type, description: description,
      debit: debit, credit: credit, balance: balance)
  }

  private func safe(_ row: [String], _ index: Int) -> String {
    index >= 0 && index < row.count ? row[index] : ""
  }

  private func parseAmount(_ field: String) -> Decimal? {
    var value = field.trimmingCharacters(in: .whitespaces)
    if value.isEmpty { return nil }
    value = value.replacingOccurrences(of: "$", with: "")
    value = value.replacingOccurrences(of: ",", with: "")
    return Decimal(string: value)
  }

  private func parseDate(_ field: String) -> Date? {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.dateFormat = "dd/MM/yyyy"
    return formatter.date(from: field.trimmingCharacters(in: .whitespaces))
  }

  /// NSRegularExpression is documented thread-safe for matching operations but
  /// is not formally `Sendable` in Swift's type system. Wrap it in an
  /// `@unchecked Sendable` box so a strict-concurrency build (or a future
  /// Swift upgrade) doesn't flag the static shared instance.
  private struct SendableRegex: @unchecked Sendable {
    let regex: NSRegularExpression
  }

  private static let tradeRegex: SendableRegex = {
    // Regex is a compile-time constant; force-try here cannot fail at runtime.
    // swiftlint:disable:next force_try
    let compiled = try! NSRegularExpression(
      pattern: #"(BUY|SELL)\s+(\d+)\s+([A-Z0-9.]+)\s+@\s+\$?([\d.]+)"#,
      options: [])
    return SendableRegex(regex: compiled)
  }()

  private func parseTrade(
    fields: ParsedFields,
    row: [String],
    index: Int
  ) throws -> ParsedRecord {
    let description = fields.description
    let cashAmount = fields.cashAmount
    let range = NSRange(description.startIndex..., in: description)
    guard
      let match = Self.tradeRegex.regex.firstMatch(in: description, options: [], range: range)
    else {
      throw CSVParserError.malformedRow(
        index: index, reason: "unrecognised trade description: \(description)", row: row)
    }
    let descriptionNS = description as NSString
    let kind = descriptionNS.substring(with: match.range(at: 1))
    let quantityText = descriptionNS.substring(with: match.range(at: 2))
    let ticker = descriptionNS.substring(with: match.range(at: 3))
    guard let quantity = Decimal(string: quantityText) else {
      throw CSVParserError.malformedRow(
        index: index, reason: "invalid trade quantity: \(quantityText)", row: row)
    }
    let stockInstrument = Instrument(
      id: "ASX:\(ticker)",
      kind: .stock,
      name: ticker,
      decimals: 0,
      ticker: ticker,
      exchange: "ASX",
      chainId: nil,
      contractAddress: nil)
    let cashLeg = ParsedLeg(
      accountId: nil,
      instrument: .AUD,
      quantity: cashAmount,
      type: kind == "BUY" ? .expense : .income,
      isInstrumentPlaceholder: true)
    let positionLeg = ParsedLeg(
      accountId: nil,
      instrument: stockInstrument,
      quantity: kind == "BUY" ? quantity : -quantity,
      type: kind == "BUY" ? .income : .expense,
      isInstrumentPlaceholder: false)
    return .transaction(
      ParsedTransaction(
        date: fields.date,
        legs: [cashLeg, positionLeg],
        rawRow: row,
        rawDescription: description,
        rawAmount: cashAmount,
        rawBalance: fields.balance,
        bankReference: nil))
  }

  /// "DIVIDEND - BHP GROUP LIMITED" → "SW-DIV-BHP". Used as a bankReference so
  /// identical dividend payments on the same day/amount still dedupe cleanly.
  private func dividendReference(for description: String) -> String? {
    guard let dashRange = description.range(of: "-") else { return nil }
    let remainder = description[dashRange.upperBound...]
      .trimmingCharacters(in: .whitespaces)
    guard let firstToken = remainder.split(separator: " ").first else { return nil }
    return "SW-DIV-\(firstToken)"
  }
}
