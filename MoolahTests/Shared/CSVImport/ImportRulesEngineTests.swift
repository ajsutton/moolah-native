import Foundation
import Testing

@testable import Moolah

@Suite("ImportRulesEngine")
struct ImportRulesEngineTests {

  private let accountId = UUID()

  private func candidate(
    description: String,
    amount: Decimal,
    date: Date = Date(timeIntervalSince1970: 1_700_000_000)
  ) -> ParsedTransaction {
    ParsedTransaction(
      date: date,
      legs: [
        ParsedLeg(
          accountId: accountId,
          instrument: .AUD,
          quantity: amount,
          type: amount >= 0 ? .income : .expense)
      ],
      rawRow: [],
      rawDescription: description,
      rawAmount: amount,
      rawBalance: nil,
      bankReference: nil)
  }

  private func rule(
    name: String = "r",
    position: Int = 0,
    matchMode: MatchMode = .all,
    conditions: [RuleCondition] = [],
    actions: [RuleAction] = [],
    accountScope: UUID? = nil,
    enabled: Bool = true
  ) -> ImportRule {
    ImportRule(
      name: name, enabled: enabled, position: position, matchMode: matchMode,
      conditions: conditions, actions: actions, accountScope: accountScope)
  }

  // MARK: - Match modes

  @Test("matchMode .all requires every condition")
  func matchModeAll() {
    let tx = candidate(description: "COFFEE HUT", amount: -5)
    let r = rule(
      matchMode: .all,
      conditions: [.descriptionContains(["COFFEE"]), .amountIsPositive],
      actions: [.setPayee("Café")])
    let e = ImportRulesEngine.evaluate(tx, routedAccountId: accountId, rules: [r])
    #expect(e.assignedPayee == nil)
    #expect(e.matchedRuleIds.isEmpty)
  }

  @Test("matchMode .any requires at least one condition")
  func matchModeAny() {
    let tx = candidate(description: "COFFEE HUT", amount: -5)
    let r = rule(
      matchMode: .any,
      conditions: [.amountIsPositive, .descriptionContains(["COFFEE"])],
      actions: [.setPayee("Café")])
    let e = ImportRulesEngine.evaluate(tx, routedAccountId: accountId, rules: [r])
    #expect(e.assignedPayee == "Café")
  }

  // MARK: - Condition behaviour

  @Test("descriptionContains ORs across tokens")
  func descriptionContainsORs() {
    let tx = candidate(description: "MORNING CAFE SYDNEY", amount: -5)
    let r = rule(
      conditions: [.descriptionContains(["COFFEE", "CAFE"])],
      actions: [.setPayee("Café")])
    let e = ImportRulesEngine.evaluate(tx, routedAccountId: accountId, rules: [r])
    #expect(e.assignedPayee == "Café")
  }

  @Test("descriptionDoesNotContain requires every token to be absent")
  func descriptionDoesNotContain() {
    let tx = candidate(description: "COFFEE HUT", amount: -5)
    let r = rule(
      conditions: [.descriptionDoesNotContain(["AMAZON", "EBAY"])],
      actions: [.setPayee("Cafe")])
    let e = ImportRulesEngine.evaluate(tx, routedAccountId: accountId, rules: [r])
    #expect(e.assignedPayee == "Cafe")
  }

  @Test("descriptionBeginsWith is case-insensitive")
  func descriptionBeginsWith() {
    let tx = candidate(description: "eftpos something", amount: -5)
    let r = rule(
      conditions: [.descriptionBeginsWith("EFTPOS ")],
      actions: [.setPayee("EFT")])
    let e = ImportRulesEngine.evaluate(tx, routedAccountId: accountId, rules: [r])
    #expect(e.assignedPayee == "EFT")
  }

  @Test("amountIsPositive / Negative / Between each fire as expected")
  func amountConditions() {
    let positive = candidate(description: "SALARY", amount: 3000)
    let negative = candidate(description: "COFFEE", amount: -5)
    let positiveRule = rule(conditions: [.amountIsPositive], actions: [.setPayee("Income")])
    let negativeRule = rule(conditions: [.amountIsNegative], actions: [.setPayee("Expense")])
    let betweenRule = rule(
      conditions: [.amountBetween(min: -10, max: 10)], actions: [.setPayee("Small")])

    #expect(
      ImportRulesEngine.evaluate(
        positive, routedAccountId: accountId, rules: [positiveRule]
      ).assignedPayee == "Income")
    #expect(
      ImportRulesEngine.evaluate(
        negative, routedAccountId: accountId, rules: [negativeRule]
      ).assignedPayee == "Expense")
    #expect(
      ImportRulesEngine.evaluate(
        negative, routedAccountId: accountId, rules: [betweenRule]
      ).assignedPayee == "Small")
    #expect(
      ImportRulesEngine.evaluate(
        positive, routedAccountId: accountId, rules: [betweenRule]
      ).assignedPayee == nil)
  }

  @Test("sourceAccountIs matches the routed account only")
  func sourceAccountIs() {
    let tx = candidate(description: "COFFEE", amount: -5)
    let other = UUID()
    let r = rule(
      conditions: [.sourceAccountIs(accountId)],
      actions: [.setPayee("Me")])
    let wrong = rule(
      conditions: [.sourceAccountIs(other)],
      actions: [.setPayee("You")])
    let e = ImportRulesEngine.evaluate(tx, routedAccountId: accountId, rules: [r, wrong])
    #expect(e.assignedPayee == "Me")
  }

  // MARK: - Action composition

  @Test("setPayee is first-match-wins")
  func firstSetPayeeWins() {
    let tx = candidate(description: "COFFEE", amount: -5)
    let first = rule(
      position: 0, conditions: [.descriptionContains(["COFFEE"])],
      actions: [.setPayee("Café")])
    let second = rule(
      position: 1, conditions: [.descriptionContains(["COFFEE"])],
      actions: [.setPayee("Coffee House")])
    let e = ImportRulesEngine.evaluate(tx, routedAccountId: accountId, rules: [second, first])
    // Rules run in position order regardless of array order.
    #expect(e.assignedPayee == "Café")
    #expect(e.matchedRuleIds == [first.id, second.id])
  }

  @Test("setCategory is first-match-wins")
  func firstSetCategoryWins() {
    let tx = candidate(description: "COFFEE", amount: -5)
    let catA = UUID()
    let catB = UUID()
    let ruleA = rule(
      position: 0, conditions: [.descriptionContains(["COFFEE"])],
      actions: [.setCategory(catA)])
    let ruleB = rule(
      position: 1, conditions: [.descriptionContains(["COFFEE"])],
      actions: [.setCategory(catB)])
    let e = ImportRulesEngine.evaluate(tx, routedAccountId: accountId, rules: [ruleA, ruleB])
    #expect(e.assignedCategoryId == catA)
  }

  @Test("appendNote stacks oldest → newest")
  func appendNoteStacks() {
    let tx = candidate(description: "COFFEE", amount: -5)
    let first = rule(position: 0, conditions: [], actions: [.appendNote("foo")])
    let second = rule(position: 1, conditions: [], actions: [.appendNote("bar")])
    let e = ImportRulesEngine.evaluate(tx, routedAccountId: accountId, rules: [first, second])
    #expect(e.appendedNotes == "foo bar")
  }

  @Test("skip short-circuits further rules")
  func skipShortCircuits() {
    let tx = candidate(description: "SPAM", amount: -5)
    let noteRule = rule(position: 0, conditions: [], actions: [.appendNote("kept")])
    let skipRule = rule(position: 1, conditions: [], actions: [.skip])
    let laterRule = rule(position: 2, conditions: [], actions: [.appendNote("dropped")])
    let e = ImportRulesEngine.evaluate(
      tx, routedAccountId: accountId, rules: [noteRule, skipRule, laterRule])
    #expect(e.isSkipped == true)
    #expect(e.appendedNotes == "kept")
    #expect(e.matchedRuleIds == [noteRule.id, skipRule.id])
  }

  @Test("markAsTransfer short-circuits further rules")
  func markAsTransferShortCircuits() {
    let tx = candidate(description: "TRANSFER", amount: -100)
    let to = UUID()
    let noteRule = rule(position: 0, conditions: [], actions: [.appendNote("kept")])
    let transferRule = rule(
      position: 1, conditions: [], actions: [.markAsTransfer(toAccountId: to)])
    let laterRule = rule(position: 2, conditions: [], actions: [.setPayee("dropped")])
    let e = ImportRulesEngine.evaluate(
      tx, routedAccountId: accountId,
      rules: [noteRule, transferRule, laterRule])
    #expect(e.transferTargetAccountId == to)
    #expect(e.assignedPayee == nil)  // later rule didn't run
  }

  // MARK: - Ordering & scoping

  @Test("disabled rules don't contribute")
  func disabledRuleIgnored() {
    let tx = candidate(description: "COFFEE", amount: -5)
    let disabled = rule(
      position: 0, conditions: [.descriptionContains(["COFFEE"])],
      actions: [.setPayee("Café")], enabled: false)
    let e = ImportRulesEngine.evaluate(tx, routedAccountId: accountId, rules: [disabled])
    #expect(e.assignedPayee == nil)
  }

  @Test("accountScope excludes mismatched routed accounts")
  func accountScopedRuleRespected() {
    let tx = candidate(description: "COFFEE", amount: -5)
    let other = UUID()
    let scoped = rule(
      position: 0, conditions: [.descriptionContains(["COFFEE"])],
      actions: [.setPayee("Café")], accountScope: other)
    let e = ImportRulesEngine.evaluate(tx, routedAccountId: accountId, rules: [scoped])
    #expect(e.assignedPayee == nil)
    let unscoped = rule(
      position: 0, conditions: [.descriptionContains(["COFFEE"])],
      actions: [.setPayee("Café")])
    let e2 = ImportRulesEngine.evaluate(tx, routedAccountId: accountId, rules: [unscoped])
    #expect(e2.assignedPayee == "Café")
  }

  @Test("empty-condition rule matches every candidate (both matchModes)")
  func emptyConditionsMatchEverything() {
    let tx = candidate(description: "ANYTHING", amount: 42)
    let allRule = rule(
      name: "all", position: 0, matchMode: .all, conditions: [],
      actions: [.appendNote("A")])
    let anyRule = rule(
      name: "any", position: 1, matchMode: .any, conditions: [],
      actions: [.appendNote("B")])
    let e = ImportRulesEngine.evaluate(
      tx, routedAccountId: accountId, rules: [allRule, anyRule])
    #expect(e.appendedNotes == "A B")
    #expect(e.matchedRuleIds == [allRule.id, anyRule.id])
  }

  @Test("rules run in position order, not array order")
  func rulesRunInPositionOrder() {
    let tx = candidate(description: "ANY", amount: -5)
    let pos5 = rule(
      name: "pos5", position: 5, conditions: [], actions: [.appendNote("5")])
    let pos1 = rule(
      name: "pos1", position: 1, conditions: [], actions: [.appendNote("1")])
    let pos10 = rule(
      name: "pos10", position: 10, conditions: [], actions: [.appendNote("10")])
    let e = ImportRulesEngine.evaluate(
      tx, routedAccountId: accountId, rules: [pos5, pos1, pos10])
    #expect(e.appendedNotes == "1 5 10")
    #expect(e.matchedRuleIds == [pos1.id, pos5.id, pos10.id])
  }
}
