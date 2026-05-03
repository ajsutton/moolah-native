import Foundation
import Testing

@testable import Moolah

@Suite("SelfWealthMovementsParser")
struct SelfWealthMovementsParserTests {

  private func rows(_ fixture: String) throws -> [[String]] {
    CSVTokenizer.parse(try CSVFixtureLoader.string(fixture))
  }

  private func transactions(_ records: [ParsedRecord]) -> [ParsedTransaction] {
    records.compactMap { rec -> ParsedTransaction? in
      if case .transaction(let transaction) = rec { return transaction } else { return nil }
    }
  }

  @Test("recognises the SelfWealth Movements header layout")
  func recognizesHeaders() throws {
    let parser = SelfWealthMovementsParser()
    let rows = try self.rows("selfwealth-movements")
    #expect(parser.recognizes(headers: rows[0]))
  }

  @Test("Buy → three legs: cash -trade, position +trade, brokerage -expense")
  func buyTradeThreeLegs() throws {
    let parser = SelfWealthMovementsParser()
    let rows = try self.rows("selfwealth-movements")
    let records = try parser.parse(rows: rows)
    let buy = try #require(
      transactions(records).first(where: {
        $0.rawDescription.contains("Buy") && $0.rawDescription.contains("WXYZ")
      }))
    #expect(buy.legs.count == 3)
    let cashLeg = buy.legs.first(where: {
      $0.instrument == .AUD && $0.type == .trade && $0.quantity == Decimal(string: "-5000.00")
    })
    #expect(cashLeg != nil)
    let positionLeg = try #require(buy.legs.first(where: { $0.instrument.id == "ASX:WXYZ.AX" }))
    #expect(positionLeg.instrument.ticker == "WXYZ.AX")
    #expect(positionLeg.quantity == 100)
    #expect(positionLeg.type == .trade)
    #expect(positionLeg.instrument.kind == .stock)
    #expect(positionLeg.isInstrumentPlaceholder == false)
    let brokerageLeg = buy.legs.first(where: {
      $0.instrument == .AUD && $0.quantity == Decimal(string: "-9.50")
    })
    #expect(brokerageLeg != nil)
    #expect(brokerageLeg?.type == .expense)
    #expect(buy.bankReference == "1000001")
  }

  @Test("Sell → three legs: cash +trade, position -trade, brokerage -expense")
  func sellTradeThreeLegs() throws {
    let parser = SelfWealthMovementsParser()
    let rows = try self.rows("selfwealth-movements")
    let records = try parser.parse(rows: rows)
    let sell = try #require(
      transactions(records).first(where: {
        $0.rawDescription.contains("Sell") && $0.rawDescription.contains("ABCD")
      }))
    #expect(sell.legs.count == 3)
    let cashLeg = try #require(
      sell.legs.first(where: {
        $0.instrument == .AUD && $0.type == .trade
      }))
    #expect(cashLeg.quantity == Decimal(string: "4000.00"))
    let positionLeg = try #require(sell.legs.first(where: { $0.instrument.id == "ASX:ABCD.AX" }))
    #expect(positionLeg.quantity == -50)
    #expect(positionLeg.type == .trade)
    let brokerageLeg = try #require(
      sell.legs.first(where: {
        $0.instrument == .AUD && $0.type == .expense
      }))
    #expect(brokerageLeg.quantity == Decimal(string: "-9.50"))
  }

  @Test("In → single position-income leg, no cash counterpart")
  func inTransferSingleLeg() throws {
    let parser = SelfWealthMovementsParser()
    let rows = try self.rows("selfwealth-movements")
    let records = try parser.parse(rows: rows)
    let drp = try #require(
      transactions(records).first(where: {
        $0.rawDescription.contains("In") && $0.rawDescription.contains("WXYZ")
      }))
    #expect(drp.legs.count == 1)
    #expect(drp.legs[0].instrument.id == "ASX:WXYZ.AX")
    #expect(drp.legs[0].quantity == 3)
    #expect(drp.legs[0].type == .income)
    #expect(drp.legs[0].isInstrumentPlaceholder == false)
  }

  @Test("In with long zero-padded reference still produces a single position-income leg")
  func inOffMarketTransferStillSingleLeg() throws {
    let parser = SelfWealthMovementsParser()
    let rows = try self.rows("selfwealth-movements")
    let records = try parser.parse(rows: rows)
    let offMarket = try #require(
      transactions(records).first(where: {
        $0.bankReference == "9000000000000001"
      }))
    #expect(offMarket.legs.count == 1)
    #expect(offMarket.legs[0].instrument.id == "ASX:MNOP.AX")
    #expect(offMarket.legs[0].quantity == 250)
    #expect(offMarket.legs[0].type == .income)
  }

  @Test("Out → single position-expense leg, no cash counterpart")
  func outTransferSingleLeg() throws {
    let parser = SelfWealthMovementsParser()
    let rows = try self.rows("selfwealth-movements")
    let records = try parser.parse(rows: rows)
    let out = try #require(
      transactions(records).first(where: {
        $0.rawDescription.contains("Out") && $0.rawDescription.contains("ABCD")
      }))
    #expect(out.legs.count == 1)
    #expect(out.legs[0].instrument.id == "ASX:ABCD.AX")
    #expect(out.legs[0].quantity == -10)
    #expect(out.legs[0].type == .expense)
  }

  @Test("unknown Action emits .skip rather than throwing")
  func unknownActionSkips() throws {
    let parser = SelfWealthMovementsParser()
    let headers = [
      "Trade Date", "Settlement Date", "Action", "Reference", "Code", "Name",
      "Units", "Average Price", "Consideration", "Brokerage", "Total",
    ]
    let row = [
      "2024-01-15 00:00:00", "2024-01-17 00:00:00", "Adjustment", "1000099",
      "WXYZ", "SAMPLE", "1", "", "", "", "",
    ]
    let records = try parser.parse(rows: [headers, row])
    #expect(records.count == 1)
    if case .skip(let reason) = records[0] {
      #expect(reason.contains("unsupported action"))
    } else {
      Issue.record("expected .skip")
    }
  }

  @Test("missing required headers → recognizes returns false, parse throws")
  func missingHeaderRejection() {
    let parser = SelfWealthMovementsParser()
    let headers = ["Date", "Description", "Amount"]
    #expect(parser.recognizes(headers: headers) == false)
    #expect(throws: CSVParserError.headerMismatch) {
      _ = try parser.parse(rows: [headers, ["2024-01-15", "x", "1.00"]])
    }
  }

  @Test("Buy row with unparseable quantity rejects the whole file")
  func malformedQuantity() throws {
    let parser = SelfWealthMovementsParser()
    let rows = try self.rows("selfwealth-movements-malformed")
    #expect(throws: CSVParserError.self) {
      _ = try parser.parse(rows: rows)
    }
  }

  @Test("empty file (headers only) parses to no records")
  func emptyFile() throws {
    let parser = SelfWealthMovementsParser()
    let rows = try self.rows("selfwealth-movements-empty")
    let records = try parser.parse(rows: rows)
    #expect(records.isEmpty)
  }

  @Test("blank rows skip without error")
  func blankRowsSkip() throws {
    let parser = SelfWealthMovementsParser()
    let headers = [
      "Trade Date", "Settlement Date", "Action", "Reference", "Code", "Name",
      "Units", "Average Price", "Consideration", "Brokerage", "Total",
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
