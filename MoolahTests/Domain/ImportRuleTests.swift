import Foundation
import Testing

@testable import Moolah

@Suite("ImportRule")
struct ImportRuleTests {

  @Test("ImportRule round-trips through Codable for every condition and action case")
  func exhaustiveCodableRoundTrip() throws {
    let rule = ImportRule(
      id: UUID(),
      name: "Coffee is Dining",
      enabled: true,
      position: 0,
      matchMode: .all,
      conditions: [
        .descriptionContains(["COFFEE", "CAFE"]),
        .descriptionDoesNotContain(["AMAZON"]),
        .descriptionBeginsWith("EFTPOS "),
        .amountIsPositive,
        .amountIsNegative,
        .amountBetween(min: dec("-100"), max: dec("-1")),
        .sourceAccountIs(UUID()),
      ],
      actions: [
        .setPayee("Café"),
        .setCategory(UUID()),
        .appendNote("imported"),
        .markAsTransfer(toAccountId: UUID()),
        .skip,
      ],
      accountScope: UUID())
    let data = try JSONEncoder().encode(rule)
    let decoded = try JSONDecoder().decode(ImportRule.self, from: data)
    #expect(decoded == rule)
  }

  @Test("MatchMode encodes as its raw string value")
  func matchModeRawValue() throws {
    let mode = MatchMode.any
    let data = try JSONEncoder().encode(mode)
    let text = String(data: data, encoding: .utf8)
    #expect(text == "\"any\"")
  }

  @Test("defaults — enabled true, matchMode .all, accountScope nil")
  func defaults() {
    let rule = ImportRule(name: "r", position: 0, conditions: [], actions: [])
    #expect(rule.enabled == true)
    #expect(rule.matchMode == .all)
    #expect(rule.accountScope == nil)
  }
}
