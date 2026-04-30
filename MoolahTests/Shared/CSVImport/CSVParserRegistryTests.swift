import Foundation
import Testing

@testable import Moolah

@Suite("CSVParserRegistry")
struct CSVParserRegistryTests {

  @Test("Movements headers pick the SelfWealthMovementsParser")
  func selectsMovementsParser() {
    let registry = CSVParserRegistry.default
    let headers = [
      "Trade Date", "Settlement Date", "Action", "Reference", "Code", "Name",
      "Units", "Average Price", "Consideration", "Brokerage", "Total",
    ]
    #expect(registry.select(for: headers).identifier == "selfwealth-movements")
  }

  @Test("Cash Report headers pick the SelfWealthCashReportParser")
  func selectsCashReportParser() {
    let registry = CSVParserRegistry.default
    let headers = [
      "TransactionDate", "Comment", "Credit", "Debit",
      "Balance * Please note, this is not a bank statement.",
    ]
    #expect(registry.select(for: headers).identifier == "selfwealth-cash-report")
  }

  @Test("Bank headers pick the generic parser")
  func selectsGenericForBank() {
    let registry = CSVParserRegistry.default
    let headers = ["Date", "Description", "Debit", "Credit", "Balance"]
    #expect(registry.select(for: headers).identifier == "generic-bank")
  }

  @Test("Unknown headers fall back to the generic parser")
  func fallsBackToGeneric() {
    let registry = CSVParserRegistry.default
    let headers = ["Foo", "Bar", "Baz"]
    #expect(registry.select(for: headers).identifier == "generic-bank")
  }

  @Test("Macquarie headers are claimed by the generic parser")
  func selectsGenericForMacquarie() {
    let headers = [
      "Transaction Date", "Narrative", "Debit Amount", "Credit Amount", "Balance",
    ]
    let registry = CSVParserRegistry.default
    #expect(registry.select(for: headers).identifier == "generic-bank")
  }

  @Test("Movements headers don't accidentally claim the Cash Report parser")
  func movementsHeadersNotClaimedByCashReport() {
    let cashReport = SelfWealthCashReportParser()
    let movementsHeaders = [
      "Trade Date", "Settlement Date", "Action", "Reference", "Code", "Name",
      "Units", "Average Price", "Consideration", "Brokerage", "Total",
    ]
    #expect(cashReport.recognizes(headers: movementsHeaders) == false)
  }

  @Test("Cash Report headers don't accidentally claim the Movements parser")
  func cashReportHeadersNotClaimedByMovements() {
    let movements = SelfWealthMovementsParser()
    let cashReportHeaders = [
      "TransactionDate", "Comment", "Credit", "Debit",
      "Balance * Please note, this is not a bank statement.",
    ]
    #expect(movements.recognizes(headers: cashReportHeaders) == false)
  }
}
