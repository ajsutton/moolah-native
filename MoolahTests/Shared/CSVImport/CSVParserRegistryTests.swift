import Foundation
import Testing

@testable import Moolah

@Suite("CSVParserRegistry")
struct CSVParserRegistryTests {

  @Test("SelfWealth headers pick the SelfWealth parser")
  func selectsSelfWealth() {
    let registry = CSVParserRegistry.default
    let headers = ["Date", "Type", "Description", "Debit", "Credit", "Balance"]
    #expect(registry.select(for: headers).identifier == "selfwealth")
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

  @Test("Source-specific parsers precede the generic one in selection order")
  func sourceSpecificFirst() {
    // Ambiguous headers that both could claim — the SelfWealth-shaped set is
    // recognised by SelfWealthParser (strict subset) but also by GenericBankCSVParser
    // (it finds date/description/debit/credit). SelfWealth should win.
    let headers = ["Date", "Type", "Description", "Debit", "Credit", "Balance"]
    // Precondition: both parsers must claim the headers, else the test proves
    // nothing about ordering.
    #expect(SelfWealthParser().recognizes(headers: headers))
    #expect(GenericBankCSVParser().recognizes(headers: headers))

    let registry = CSVParserRegistry.default
    #expect(registry.select(for: headers).identifier == "selfwealth")
  }

  @Test("Macquarie headers are claimed by the generic parser")
  func selectsGenericForMacquarie() {
    let headers = [
      "Transaction Date", "Narrative", "Debit Amount", "Credit Amount", "Balance",
    ]
    let registry = CSVParserRegistry.default
    #expect(registry.select(for: headers).identifier == "generic-bank")
  }
}
