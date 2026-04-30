import Foundation
import Testing

@testable import Moolah

@Suite("SelfWealthCashReportParser")
struct SelfWealthCashReportParserTests {

  private func rows(_ fixture: String) throws -> [[String]] {
    CSVTokenizer.parse(try CSVFixtureLoader.string(fixture))
  }

  private func transactions(_ records: [ParsedRecord]) -> [ParsedTransaction] {
    records.compactMap { rec -> ParsedTransaction? in
      if case .transaction(let transaction) = rec { return transaction } else { return nil }
    }
  }

  @Test("recognises the Cash Report header layout (Balance has trailing comment)")
  func recognizesHeaders() throws {
    let parser = SelfWealthCashReportParser()
    let rows = try self.rows("selfwealth-cash-report")
    #expect(parser.recognizes(headers: rows[0]))
  }

  @Test("Order N: trade fill rows are skipped (covered by Movements report)")
  func tradeFillsSkipped() throws {
    let parser = SelfWealthCashReportParser()
    let rows = try self.rows("selfwealth-cash-report")
    let records = try parser.parse(rows: rows)
    let txns = transactions(records)
    #expect(!txns.contains(where: { $0.rawDescription.lowercased().hasPrefix("order ") }))
  }

  @Test("Opening / Closing Balance sentinels are skipped without error")
  func balanceSentinelsSkipped() throws {
    let parser = SelfWealthCashReportParser()
    let rows = try self.rows("selfwealth-cash-report")
    let records = try parser.parse(rows: rows)
    let txns = transactions(records)
    #expect(!txns.contains(where: { $0.rawDescription.lowercased().contains("opening balance") }))
    #expect(!txns.contains(where: { $0.rawDescription.lowercased().contains("closing balance") }))
  }

  @Test("dividend row → single-leg AUD income, raw comment as bankReference")
  func dividendSingleLegIncome() throws {
    let parser = SelfWealthCashReportParser()
    let rows = try self.rows("selfwealth-cash-report")
    let records = try parser.parse(rows: rows)
    let dividend = try #require(
      transactions(records).first(where: {
        $0.rawDescription.contains("PAYMENT") && $0.rawDescription.contains("WXYZ")
      }))
    #expect(dividend.legs.count == 1)
    #expect(dividend.legs[0].instrument == .AUD)
    #expect(dividend.legs[0].type == .income)
    #expect(dividend.legs[0].quantity == Decimal(string: "120.00"))
    #expect(dividend.bankReference == "WXYZ PAYMENT JAN24/0000001")
  }

  @Test("generic credit row → single-leg AUD income with raw comment, nil bankReference")
  func cashInSingleLegIncome() throws {
    let parser = SelfWealthCashReportParser()
    let rows = try self.rows("selfwealth-cash-report")
    let records = try parser.parse(rows: rows)
    let cashIn = try #require(
      transactions(records).first(where: {
        $0.rawDescription == "PAYMENT FROM EXAMPLE PERSON"
      }))
    #expect(cashIn.legs.count == 1)
    #expect(cashIn.legs[0].instrument == .AUD)
    #expect(cashIn.legs[0].type == .income)
    #expect(cashIn.legs[0].quantity == Decimal(string: "1000.00"))
    #expect(cashIn.bankReference == nil)
  }

  @Test("generic debit row → single-leg AUD expense with raw comment, nil bankReference")
  func cashOutSingleLegExpense() throws {
    let parser = SelfWealthCashReportParser()
    let rows = try self.rows("selfwealth-cash-report")
    let records = try parser.parse(rows: rows)
    let cashOut = try #require(
      transactions(records).first(where: {
        $0.rawDescription == "Test withdrawal"
      }))
    #expect(cashOut.legs.count == 1)
    #expect(cashOut.legs[0].instrument == .AUD)
    #expect(cashOut.legs[0].type == .expense)
    #expect(cashOut.legs[0].quantity == Decimal(string: "-50.00"))
  }

  @Test("missing required headers → recognizes returns false, parse throws")
  func missingHeaderRejection() {
    let parser = SelfWealthCashReportParser()
    let headers = ["Date", "Description", "Amount"]
    #expect(parser.recognizes(headers: headers) == false)
    #expect(throws: CSVParserError.headerMismatch) {
      _ = try parser.parse(rows: [headers, ["2024-01-15", "x", "1.00"]])
    }
  }

  @Test("rows with neither credit nor debit (and a real date) are skipped")
  func zeroAmountRowSkipped() throws {
    let parser = SelfWealthCashReportParser()
    let headers = [
      "TransactionDate", "Comment", "Credit", "Debit",
      "Balance * Please note, this is not a bank statement.",
    ]
    let row = ["2024-01-15 00:00:00", "Some informational note", "", "", "0.00"]
    let records = try parser.parse(rows: [headers, row])
    #expect(records.count == 1)
    if case .skip = records[0] { /* ok */
    } else {
      Issue.record("expected .skip for zero-amount row")
    }
  }

  @Test("malformed date → whole-file failure")
  func malformedDate() throws {
    let parser = SelfWealthCashReportParser()
    let rows = try self.rows("selfwealth-cash-report-malformed")
    #expect(throws: CSVParserError.self) {
      _ = try parser.parse(rows: rows)
    }
  }

  @Test("empty file (headers only) parses to no records")
  func emptyFile() throws {
    let parser = SelfWealthCashReportParser()
    let rows = try self.rows("selfwealth-cash-report-empty")
    let records = try parser.parse(rows: rows)
    #expect(records.isEmpty)
  }

  @Test("blank rows skip without error")
  func blankRowsSkip() throws {
    let parser = SelfWealthCashReportParser()
    let headers = [
      "TransactionDate", "Comment", "Credit", "Debit",
      "Balance * Please note, this is not a bank statement.",
    ]
    let blank = [String](repeating: "", count: headers.count)
    let records = try parser.parse(rows: [headers, blank])
    #expect(records.count == 1)
    if case .skip = records[0] { /* ok */
    } else {
      Issue.record("expected .skip for blank row")
    }
  }
}
