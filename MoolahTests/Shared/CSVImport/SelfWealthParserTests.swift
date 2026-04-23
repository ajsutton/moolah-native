import Foundation
import Testing

@testable import Moolah

@Suite("SelfWealthParser")
struct SelfWealthParserTests {

  private func rows(_ fixture: String) throws -> [[String]] {
    CSVTokenizer.parse(try CSVFixtureLoader.string(fixture))
  }

  private func transactions(_ records: [ParsedRecord]) -> [ParsedTransaction] {
    records.compactMap { rec -> ParsedTransaction? in
      if case .transaction(let transaction) = rec { return transaction } else { return nil }
    }
  }

  @Test("recognises the SelfWealth header layout")
  func recognizesHeaders() throws {
    let parser = SelfWealthParser()
    let rows = try self.rows("selfwealth-trades")
    #expect(parser.recognizes(headers: rows[0]))
  }

  @Test("BUY trade → two legs: cash -expense, position +income")
  func buyTradeTwoLeg() throws {
    let parser = SelfWealthParser()
    let rows = try self.rows("selfwealth-trades")
    let records = try parser.parse(rows: rows)
    let trades = transactions(records).filter { $0.legs.count == 2 }
    let bhp = trades.first(where: { $0.rawDescription.contains("BHP") })!
    let cashLeg = bhp.legs.first(where: { $0.instrument == .AUD })!
    #expect(cashLeg.quantity == Decimal(string: "-4550.00"))
    #expect(cashLeg.type == .expense)
    let positionLeg = bhp.legs.first(where: { $0.instrument.id == "ASX:BHP" })!
    #expect(positionLeg.quantity == 100)
    #expect(positionLeg.type == .income)
    #expect(positionLeg.instrument.kind == .stock)
  }

  @Test("SELL trade → two legs: cash +income, position -expense")
  func sellTradeTwoLeg() throws {
    let parser = SelfWealthParser()
    let rows = try self.rows("selfwealth-trades")
    let records = try parser.parse(rows: rows)
    let trades = transactions(records).filter { $0.legs.count == 2 }
    let cba = trades.first(where: { $0.rawDescription.contains("CBA") })!
    let cashLeg = cba.legs.first(where: { $0.instrument == .AUD })!
    #expect(cashLeg.quantity == Decimal(string: "5512.50"))
    #expect(cashLeg.type == .income)
    let positionLeg = cba.legs.first(where: { $0.instrument.id == "ASX:CBA" })!
    #expect(positionLeg.quantity == -50)
    #expect(positionLeg.type == .expense)
  }

  @Test("dividend → single-leg AUD income with SW-DIV-<ticker> bankReference")
  func dividendSingleLegIncome() throws {
    let parser = SelfWealthParser()
    let rows = try self.rows("selfwealth-trades")
    let records = try parser.parse(rows: rows)
    let dividend = transactions(records).first(where: {
      $0.rawDescription.contains("DIVIDEND")
    })!
    #expect(dividend.legs.count == 1)
    #expect(dividend.legs[0].instrument == .AUD)
    #expect(dividend.legs[0].type == .income)
    #expect(dividend.legs[0].quantity == Decimal(string: "120.00"))
    #expect(dividend.bankReference == "SW-DIV-BHP")
  }

  @Test("brokerage + GST → single-leg AUD expense")
  func brokerageSingleLegExpense() throws {
    let parser = SelfWealthParser()
    let rows = try self.rows("selfwealth-trades")
    let records = try parser.parse(rows: rows)
    let brokerage = transactions(records).first(where: {
      $0.rawDescription == "Brokerage fee"
    })!
    #expect(brokerage.legs.count == 1)
    #expect(brokerage.legs[0].type == .expense)
    #expect(brokerage.legs[0].quantity == Decimal(string: "-9.50"))
    let gst = transactions(records).first(where: { $0.rawDescription == "GST" })!
    #expect(gst.legs[0].quantity == Decimal(string: "-0.95"))
  }

  @Test("cash in / cash out → single-leg AUD")
  func cashInSingleLegAUD() throws {
    let parser = SelfWealthParser()
    let rows = try self.rows("selfwealth-trades")
    let records = try parser.parse(rows: rows)
    let cashIn = transactions(records).first(where: {
      $0.rawDescription == "Cash deposit"
    })!
    #expect(cashIn.legs.count == 1)
    #expect(cashIn.legs[0].instrument == .AUD)
    #expect(cashIn.legs[0].type == .income)
    #expect(cashIn.legs[0].quantity == Decimal(string: "10000.00"))
  }

  @Test("unknown Type emits .skip rather than throwing")
  func unknownTypeSkips() throws {
    let parser = SelfWealthParser()
    let rows: [[String]] = [
      ["Date", "Type", "Description", "Debit", "Credit", "Balance"],
      ["02/03/2024", "OpeningBalance", "Start", "", "100.00", "100.00"],
    ]
    let records = try parser.parse(rows: rows)
    #expect(records.count == 1)
    if case .skip(let reason) = records[0] {
      #expect(reason.contains("unknown type"))
    } else {
      Issue.record("expected .skip")
    }
  }

  @Test("missing required headers → recognizes returns false, parse throws")
  func missingHeaderRejection() {
    let parser = SelfWealthParser()
    let headers = ["Date", "Description", "Amount"]
    #expect(parser.recognizes(headers: headers) == false)
    #expect(throws: CSVParserError.headerMismatch) {
      _ = try parser.parse(rows: [headers, ["02/03/2024", "COFFEE", "-5.50"]])
    }
  }

  @Test("Trade row whose description can't be regex-matched rejects the whole file")
  func malformedTradeDescription() throws {
    let parser = SelfWealthParser()
    let rows = try self.rows("selfwealth-trades-malformed")
    #expect(throws: CSVParserError.self) {
      _ = try parser.parse(rows: rows)
    }
  }

  @Test("empty file (headers only) parses to no records")
  func emptyFile() throws {
    let parser = SelfWealthParser()
    let rows = try self.rows("selfwealth-trades-empty")
    let records = try parser.parse(rows: rows)
    #expect(records.isEmpty)
  }
}
