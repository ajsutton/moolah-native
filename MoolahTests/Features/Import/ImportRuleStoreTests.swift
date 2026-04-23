import Foundation
import Testing

@testable import Moolah

@Suite("ImportRuleStore")
@MainActor
struct ImportRuleStoreTests {

  private func rule(
    name: String = "r",
    position: Int = 0,
    conditions: [RuleCondition] = [],
    actions: [RuleAction] = []
  ) -> ImportRule {
    ImportRule(
      name: name, position: position,
      conditions: conditions, actions: actions)
  }

  @Test("load sorts rules by position")
  func loadSortsByPosition() async throws {
    let (backend, _) = try TestBackend.create()
    _ = try await backend.importRules.create(rule(name: "ruleC", position: 5))
    _ = try await backend.importRules.create(rule(name: "ruleA", position: 1))
    _ = try await backend.importRules.create(rule(name: "ruleB", position: 3))
    let store = ImportRuleStore(repository: backend.importRules)
    await store.load()
    #expect(store.rules.map(\.name) == ["ruleA", "ruleB", "ruleC"])
  }

  @Test("create appends the new rule and keeps sorted")
  func createAppends() async throws {
    let (backend, _) = try TestBackend.create()
    let store = ImportRuleStore(repository: backend.importRules)
    await store.load()
    await store.create(rule(name: "alpha", position: 0))
    await store.create(rule(name: "beta", position: 1))
    #expect(store.rules.map(\.name) == ["alpha", "beta"])
  }

  @Test("update replaces the existing rule")
  func updateReplaces() async throws {
    let (backend, _) = try TestBackend.create()
    let store = ImportRuleStore(repository: backend.importRules)
    guard let created = await store.create(rule(name: "original", position: 0)) else {
      Issue.record("create returned nil")
      return
    }
    var edited = created
    edited.name = "renamed"
    edited.conditions = [.descriptionContains(["FOO"])]
    await store.update(edited)
    #expect(store.rules.first?.name == "renamed")
    #expect(store.rules.first?.conditions == [.descriptionContains(["FOO"])])
  }

  @Test("delete removes from the list")
  func deleteRemoves() async throws {
    let (backend, _) = try TestBackend.create()
    let store = ImportRuleStore(repository: backend.importRules)
    guard let created = await store.create(rule(name: "x", position: 0)) else {
      Issue.record("create failed")
      return
    }
    await store.delete(id: created.id)
    #expect(store.rules.isEmpty)
  }

  @Test("reorder atomically updates positions and re-sorts")
  func reorderUpdatesPositions() async throws {
    let (backend, _) = try TestBackend.create()
    let store = ImportRuleStore(repository: backend.importRules)
    let ruleA = await store.create(rule(name: "ruleA", position: 0))!
    let ruleB = await store.create(rule(name: "ruleB", position: 1))!
    let ruleC = await store.create(rule(name: "ruleC", position: 2))!
    await store.reorder([ruleC.id, ruleA.id, ruleB.id])
    #expect(store.rules.map(\.name) == ["ruleC", "ruleA", "ruleB"])
    #expect(store.rules.map(\.position) == [0, 1, 2])
  }

  @Test("countAffected counts matching imported transactions")
  func countAffectedMatchesRules() async throws {
    let (backend, container) = try TestBackend.create()
    let accountId = UUID()
    _ = try await backend.accounts.create(
      Account(
        id: accountId, name: "Cash", type: .bank, instrument: .AUD,
        positions: [], position: 0, isHidden: false),
      openingBalance: nil)
    let origin = ImportOrigin(
      rawDescription: "COFFEE HUT",
      bankReference: nil,
      rawAmount: -5,
      rawBalance: nil,
      importedAt: Date(),
      importSessionId: UUID(),
      sourceFilename: "cba.csv",
      parserIdentifier: "generic-bank")
    let seededTxs = (0..<3).map { _ in
      Transaction(
        date: Date(),
        legs: [
          TransactionLeg(
            accountId: accountId, instrument: .AUD, quantity: -5, type: .expense,
            categoryId: nil, earmarkId: nil)
        ],
        importOrigin: origin)
    }
    let unrelated = Transaction(
      date: Date(),
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: .AUD, quantity: -10, type: .expense,
          categoryId: nil, earmarkId: nil)
      ],
      importOrigin: ImportOrigin(
        rawDescription: "AMAZON", bankReference: nil,
        rawAmount: -10, rawBalance: nil, importedAt: Date(),
        importSessionId: UUID(), sourceFilename: nil,
        parserIdentifier: "generic-bank"))
    TestBackend.seed(transactions: seededTxs + [unrelated], in: container)
    let store = ImportRuleStore(repository: backend.importRules)
    let count = await store.countAffected(
      conditions: [.descriptionContains(["COFFEE"])],
      matchMode: .all,
      accountScope: nil,
      backend: backend)
    #expect(count == 3)
  }
}

@Suite("DistinguishingTokens")
struct DistinguishingTokensTests {

  @Test("extract picks rare tokens first")
  func picksRareTokens() {
    let description = "EFTPOS AMAZON PURCHASE AUD"
    let corpus = [
      "EFTPOS WOOLWORTHS AUD",
      "EFTPOS COLES AUD",
      "EFTPOS COFFEE AUD",
      "EFTPOS AMAZON AUD",  // contains AMAZON once — still rarer than EFTPOS
      "EFTPOS PURCHASE AUD",
    ]
    let tokens = DistinguishingTokens.extract(from: description, corpus: corpus, limit: 2)
    // EFTPOS and AUD and PURCHASE are common; AMAZON appears only once → rarer.
    #expect(tokens.contains("AMAZON"))
  }

  @Test("extract filters out numeric-only and one-char tokens")
  func filtersNoiseTokens() {
    let tokens = DistinguishingTokens.extract(
      from: "A 12345 COFFEE", corpus: ["B 67890 COFFEE"])
    #expect(tokens.contains("A") == false)
    #expect(tokens.contains("12345") == false)
    #expect(tokens.contains("COFFEE"))
  }

  @Test("empty description returns empty list")
  func emptyDescription() {
    let tokens = DistinguishingTokens.extract(from: "", corpus: ["foo"])
    #expect(tokens.isEmpty)
  }

  @Test("extract returns tokens in frequency-then-first-appearance order")
  func stableOrdering() {
    let tokens = DistinguishingTokens.extract(
      from: "RARE COMMON RARE MIDDLE",
      corpus: ["COMMON COMMON COMMON", "MIDDLE MIDDLE"],
      limit: 3)
    // RARE appears 0 times in corpus; MIDDLE 1; COMMON 1 (set-deduped per item).
    // Order rarest-first, ties broken by first appearance in description.
    #expect(tokens.first == "RARE")
  }
}
