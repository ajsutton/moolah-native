import Foundation
import Testing

@testable import Moolah

struct CustomTradeCSVParserTests {

  @Test("Recognizes custom trade CSV headers")
  func testRecognizes() {
    let parser = CustomTradeCSVParser()
    let headers = [
      "Date", "Sell", "Sell Unit", "Buy", "Buy Unit", "Fee (AUD)", "Avg. Cost", "Broker", "Type",
    ]
    #expect(parser.recognizes(headers: headers))
  }

  @Test("Parses sample rows correctly")
  func testParseSample() throws {
    let csv = """
      Date,Sell,Sell Unit,Buy,Buy Unit,Fee (AUD),Avg. Cost,Broker,Type
      2021-01-19,,,1,AUD,$\t0.00,$\t1,InvestSMART,Deposit
      2021-01-19,1,AUD,,,$\t0.00,$\t1,InvestSMART,PMA Participation 
      2021-01-20,,,"64,999",AUD,$\t0.00,$\t1,InvestSMART,Deposit
      2021-01-21,"1,387.8",AUD,12,IAF,$\t5.50,$\t115.65,InvestSMART,Trade
      """
    let rows = CSVTokenizer.parse(csv)
    let parser = CustomTradeCSVParser()
    let results = try parser.parse(rows: rows)

    #expect(results.count == 4)

    // Row 1: Deposit (Buy AUD only) — single buy leg is income.
    if case .transaction(let transaction) = results[0] {
      #expect(transaction.legs.count == 1)
      #expect(transaction.legs[0].instrument == .AUD)
      #expect(transaction.legs[0].quantity == 1)
      #expect(transaction.legs[0].type == .income)
      #expect(transaction.rawDescription == "Deposit")
    } else {
      Issue.record("Expected transaction for row 1")
    }

    // Row 2: PMA Participation (Sell AUD only) — single sell leg is expense.
    if case .transaction(let transaction) = results[1] {
      #expect(transaction.legs.count == 1)
      #expect(transaction.legs[0].instrument == .AUD)
      #expect(transaction.legs[0].quantity == -1)
      #expect(transaction.legs[0].type == .expense)
      #expect(transaction.rawDescription == "PMA Participation")
    } else {
      Issue.record("Expected transaction for row 2")
    }

    // Row 3: Large Deposit — single buy leg is income.
    if case .transaction(let transaction) = results[2] {
      #expect(transaction.legs[0].quantity == 64999)
      #expect(transaction.legs[0].type == .income)
    } else {
      Issue.record("Expected transaction for row 3")
    }

    // Row 4: Trade (Sell AUD, Buy IAF, Fee AUD) — both sides present, so trade.
    if case .transaction(let transaction) = results[3] {
      #expect(transaction.legs.count == 3)

      let audSell = transaction.legs.first {
        $0.instrument == .AUD && $0.quantity < 0 && $0.type == .trade
      }
      let iafBuy = transaction.legs.first { $0.instrument.ticker == "IAF.AX" }
      let fee = transaction.legs.first { $0.type == .expense }

      #expect(audSell?.quantity == -1387.8)
      #expect(iafBuy?.quantity == 12)
      #expect(iafBuy?.type == .trade)
      #expect(fee?.quantity == -5.50)
      #expect(transaction.rawAmount == -1387.8)
    } else {
      Issue.record("Expected transaction for row 4")
    }
  }
}
