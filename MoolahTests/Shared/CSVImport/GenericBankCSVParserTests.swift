import Foundation
import Testing

@testable import Moolah

@Suite("GenericBankCSVParser")
struct GenericBankCSVParserTests {

  // MARK: - Helpers

  private func rows(_ fixture: String) throws -> [[String]] {
    CSVTokenizer.parse(try CSVFixtureLoader.string(fixture))
  }

  private func rowsFromData(_ fixture: String) throws -> [[String]] {
    try CSVTokenizer.parse(try CSVFixtureLoader.data(fixture))
  }

  private func dateAt(_ year: Int, _ month: Int, _ day: Int) -> Date {
    var components = DateComponents()
    components.year = year
    components.month = month
    components.day = day
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar.date(from: components)!
  }

  private func transactions(_ records: [ParsedRecord]) -> [ParsedTransaction] {
    records.compactMap { rec -> ParsedTransaction? in
      if case .transaction(let tx) = rec { return tx } else { return nil }
    }
  }

  // MARK: - Tests

  @Test("recognises CBA headers and parses one expense row")
  func recognizesCBA() throws {
    let parser = GenericBankCSVParser()
    let rows = try self.rows("cba-everyday-standard")
    #expect(parser.recognizes(headers: rows[0]))
    let records = try parser.parse(rows: rows)
    let txs = transactions(records)
    #expect(records.count == 5)
    // Opening-balance row has no debit or credit — we explicitly emit .skip
    // instead of rejecting, so a CBA export with a leading OPENING BALANCE row
    // still parses. Pin the contract.
    if case .skip(let reason) = records[0] {
      #expect(reason.contains("debit or credit"))
    } else {
      Issue.record("expected opening-balance row to be .skip, got \(records[0])")
    }
    let coffee = txs.first(where: { $0.rawDescription == "COFFEE HUT SYDNEY" })!
    #expect(coffee.rawAmount == Decimal(string: "-5.50"))
    #expect(coffee.rawBalance == Decimal(string: "994.50"))
    #expect(coffee.legs.count == 1)
    #expect(coffee.legs[0].type == .expense)
    #expect(coffee.legs[0].quantity == Decimal(string: "-5.50"))
    #expect(coffee.bankReference == nil)
    #expect(coffee.date == dateAt(2024, 4, 2))
  }

  @Test("recognises ANZ signed amount column")
  func recognizesANZSignedAmount() throws {
    let parser = GenericBankCSVParser()
    let rows = try self.rows("anz-everyday-debit-credit-split")
    let records = try parser.parse(rows: rows)
    let txs = transactions(records)
    #expect(txs.count == 3)
    #expect(txs[0].rawAmount == Decimal(string: "-5.50"))
    #expect(txs[0].legs[0].type == .expense)
    #expect(txs[1].rawAmount == Decimal(string: "3000.00"))
    #expect(txs[1].legs[0].type == .income)
  }

  @Test("recognises NAB credit card quoted-field layout")
  func recognizesNABCreditCard() throws {
    let parser = GenericBankCSVParser()
    let rows = try self.rows("nab-creditcard-debit-credit-split")
    let records = try parser.parse(rows: rows)
    let txs = transactions(records)
    #expect(txs.count == 3)
    // Embedded comma preserved in description
    #expect(txs[1].rawDescription == "Uber BV, Amsterdam")
  }

  @Test("parses Westpac dash-separator dates")
  func recognizesWestpacDashDate() throws {
    let parser = GenericBankCSVParser()
    let rows = try self.rows("westpac-everyday")
    let mapping = parser.inferMapping(
      from: rows[0], sampleRows: Array(rows.dropFirst()))!
    #expect(mapping.dateFormat == .ddMMyyyy(separator: "-"))
    let records = try parser.parse(rows: rows)
    let txs = transactions(records)
    // First data row is an "OPENING" with no debit/credit → emits .skip.
    // Second row is the coffee expense.
    let coffee = txs.first(where: { $0.rawDescription == "COFFEE" })!
    #expect(coffee.date == dateAt(2024, 4, 2))
    #expect(coffee.rawAmount == Decimal(string: "-5.50"))
  }

  @Test("populates bankReference from ING reference column")
  func recognizesINGWithReference() throws {
    let parser = GenericBankCSVParser()
    let rows = try self.rows("ing-savings")
    let records = try parser.parse(rows: rows)
    let txs = transactions(records)
    #expect(txs[0].bankReference == "TXN12345")
    #expect(txs[1].bankReference == "TXN12346")
  }

  @Test("detects DD/MM format when first component exceeds 12")
  func recognizesBendigoDDMM() throws {
    let parser = GenericBankCSVParser()
    let rows = try self.rows("bendigo-standard")
    let mapping = parser.inferMapping(
      from: rows[0], sampleRows: Array(rows.dropFirst()))!
    // 15/04/2024 has day > 12 → must be DD/MM
    #expect(mapping.dateFormat == .ddMMyyyy(separator: "/"))
    #expect(mapping.dateFormatAmbiguous == false)
  }

  @Test("Macquarie debit/credit amount columns parse")
  func recognizesMacquarieDebitCreditSplit() throws {
    let parser = GenericBankCSVParser()
    let rows = try self.rows("macquarie-everyday")
    let records = try parser.parse(rows: rows)
    let txs = transactions(records)
    #expect(txs.count == 3)
    #expect(txs[0].rawAmount == Decimal(string: "-5.50"))
    #expect(txs[1].rawAmount == Decimal(string: "3000.00"))
  }

  @Test("detects MM/DD format from US BofA export when second component exceeds 12")
  func recognizesBofAMMDD() throws {
    let parser = GenericBankCSVParser()
    let rows = try self.rows("us-bofa-standard")
    let mapping = parser.inferMapping(
      from: rows[0], sampleRows: Array(rows.dropFirst()))!
    // 04/15/2024 — second component 15 > 12, first 04 ≤ 12 → MM/DD
    #expect(mapping.dateFormat == .mmDDyyyy(separator: "/"))
  }

  @Test("detects ISO format from Barclays export")
  func recognizesBarclaysISO() throws {
    let parser = GenericBankCSVParser()
    let rows = try self.rows("uk-barclays-standard")
    let mapping = parser.inferMapping(
      from: rows[0], sampleRows: Array(rows.dropFirst()))!
    #expect(mapping.dateFormat == .iso)
    let records = try parser.parse(rows: rows)
    let txs = transactions(records)
    #expect(txs[0].date == dateAt(2024, 4, 2))
  }

  @Test("infers generic Txn Date / Memo / Dr / Cr / Bal headers")
  func recognizesGenericInferredHeaders() throws {
    let parser = GenericBankCSVParser()
    let rows = try self.rows("generic-unknown-headers")
    #expect(parser.recognizes(headers: rows[0]))
    let records = try parser.parse(rows: rows)
    let txs = transactions(records)
    #expect(txs.count == 3)
    #expect(txs[0].rawAmount == Decimal(string: "-10.00"))  // Dr only
    #expect(txs[1].rawAmount == Decimal(string: "100.00"))  // Cr only
  }

  @Test("rejects unknown headers via headerMismatch")
  func rejectsUnknownHeaders() {
    let parser = GenericBankCSVParser()
    let rows: [[String]] = [["Foo", "Bar", "Baz"], ["1", "2", "3"]]
    #expect(parser.recognizes(headers: rows[0]) == false)
    #expect(throws: CSVParserError.headerMismatch) {
      _ = try parser.parse(rows: rows)
    }
  }

  @Test("rejects malformed amount via malformedRow")
  func rejectsMalformedAmount() {
    let parser = GenericBankCSVParser()
    let rows: [[String]] = [
      ["Date", "Description", "Amount", "Balance"],
      ["02/04/2024", "COFFEE", "not-a-number", "100.00"],
    ]
    #expect(throws: CSVParserError.self) {
      _ = try parser.parse(rows: rows)
    }
  }

  @Test("summary rows (Total/Summary) emit .skip rather than throwing")
  func skipsSummaryRows() throws {
    let parser = GenericBankCSVParser()
    let rows: [[String]] = [
      ["Date", "Description", "Amount", "Balance"],
      ["02/04/2024", "COFFEE", "-5.50", "994.50"],
      ["", "Total", "-5.50", ""],
    ]
    let records = try parser.parse(rows: rows)
    #expect(records.count == 2)
    if case .skip(let reason) = records[1] {
      #expect(reason == "summary row")
    } else {
      Issue.record("expected .skip for the Total row")
    }
  }

  @Test("preserves sign from debit/credit split — never abs()")
  func preservesSignFromDebitCreditSplit() throws {
    let parser = GenericBankCSVParser()
    // Unsigned positive debits (Macquarie-style "Debit Amount" = 5.50) must
    // flip to negative in the output — that's the core of "debit means
    // money out, so output sign is negative" regardless of how the export
    // encodes it.
    let unsignedDebitRows: [[String]] = [
      ["Date", "Description", "Debit Amount", "Credit Amount", "Balance"],
      ["02/04/2024", "COFFEE", "5.50", "", "994.50"],
      ["03/04/2024", "SALARY", "", "3000.00", "3994.50"],
    ]
    let unsignedRecords = try parser.parse(rows: unsignedDebitRows)
    let unsignedTxs = transactions(unsignedRecords)
    #expect(unsignedTxs[0].rawAmount == Decimal(string: "-5.50"))
    #expect(unsignedTxs[0].legs[0].type == .expense)
    #expect(unsignedTxs[1].rawAmount == Decimal(string: "3000.00"))
    #expect(unsignedTxs[1].legs[0].type == .income)

    // Already-signed negative debits (some banks emit "-5.50" in the Debit
    // column) must stay negative — `-abs()` is idempotent on negatives.
    let signedDebitRows: [[String]] = [
      ["Date", "Description", "Debit Amount", "Credit Amount", "Balance"],
      ["02/04/2024", "COFFEE", "-5.50", "", "994.50"],
    ]
    let signedRecords = try parser.parse(rows: signedDebitRows)
    let signedTxs = transactions(signedRecords)
    #expect(signedTxs[0].rawAmount == Decimal(string: "-5.50"))
    #expect(signedTxs[0].legs[0].type == .expense)
  }

  @Test("rejects file with an unterminated-quote-induced malformed row")
  func rejectsMalformedUnterminatedQuote() throws {
    let parser = GenericBankCSVParser()
    let rows = try self.rows("malformed-unterminated-quote")
    // The tokenizer greedily absorbs the unterminated-quote field; the
    // resulting row has fewer columns than the header, so the date column
    // is either empty or collapses into the description — either way, the
    // parser cannot extract a valid date and must throw.
    #expect(throws: CSVParserError.self) {
      _ = try parser.parse(rows: rows)
    }
  }

  @Test("flags ambiguous date format when both components are always ≤ 12")
  func dateFormatAmbiguousFlag() throws {
    let parser = GenericBankCSVParser()
    let headers = ["Date", "Description", "Amount", "Balance"]
    let sample = [
      ["01/02/2024", "A", "-5.50", "100"],
      ["03/04/2024", "B", "-5.50", "100"],
      ["05/06/2024", "C", "-5.50", "100"],
    ]
    let mapping = parser.inferMapping(from: headers, sampleRows: sample)!
    #expect(mapping.dateFormatAmbiguous == true)
    #expect(mapping.dateFormat == .ddMMyyyy(separator: "/"))  // sensible default
  }

  @Test("parses UTF-16 BOM fixture via the Data entry point")
  func parsesUTF16BOMFixture() throws {
    let parser = GenericBankCSVParser()
    let rows = try rowsFromData("utf16-bom")
    #expect(parser.recognizes(headers: rows[0]))
    let records = try parser.parse(rows: rows)
    let txs = transactions(records)
    #expect(txs[0].rawDescription.contains("éclair"))
  }

  @Test("parses Windows-1252 fixture via the Data entry point")
  func parsesWindows1252Fixture() throws {
    let parser = GenericBankCSVParser()
    let rows = try rowsFromData("windows-1252")
    #expect(parser.recognizes(headers: rows[0]))
    let records = try parser.parse(rows: rows)
    let txs = transactions(records)
    #expect(txs[0].rawDescription.contains("CAFÉ"))
    #expect(txs[0].rawDescription.contains("£"))
  }
}
