import Foundation
import Testing

@testable import Moolah

@Suite("ImportRuleRepository Contract")
struct ImportRuleRepositoryContractTests {

  @Test("rule fields + conditions + actions survive create/update/fetch")
  func lifecycle() async throws {
    let (backend, _) = try TestBackend.create()
    let rule = ImportRule(
      name: "Coffee",
      position: 0,
      matchMode: .all,
      conditions: [.descriptionContains(["COFFEE"])],
      actions: [.setPayee("Café"), .appendNote("imported")])
    _ = try await backend.importRules.create(rule)
    var all = try await backend.importRules.fetchAll()
    #expect(all.count == 1)
    #expect(all[0].conditions == [.descriptionContains(["COFFEE"])])
    #expect(all[0].actions == [.setPayee("Café"), .appendNote("imported")])
    #expect(all[0].matchMode == .all)

    var updated = rule
    updated.enabled = false
    updated.actions = [.skip]
    _ = try await backend.importRules.update(updated)
    all = try await backend.importRules.fetchAll()
    #expect(all[0].enabled == false)
    #expect(all[0].actions == [.skip])

    try await backend.importRules.delete(id: rule.id)
    all = try await backend.importRules.fetchAll()
    #expect(all.isEmpty)
  }

  @Test("reorder atomically repositions every rule")
  func reorder() async throws {
    let (backend, _) = try TestBackend.create()
    let a = ImportRule(name: "A", position: 0, conditions: [], actions: [])
    let b = ImportRule(name: "B", position: 1, conditions: [], actions: [])
    let c = ImportRule(name: "C", position: 2, conditions: [], actions: [])
    for r in [a, b, c] { _ = try await backend.importRules.create(r) }

    try await backend.importRules.reorder([c.id, a.id, b.id])
    let ordered = try await backend.importRules.fetchAll()
    #expect(ordered.map(\.id) == [c.id, a.id, b.id])
    #expect(ordered.map(\.position) == [0, 1, 2])
  }

  @Test("reorder rejects mismatched id set")
  func reorderMismatch() async throws {
    let (backend, _) = try TestBackend.create()
    let a = ImportRule(name: "A", position: 0, conditions: [], actions: [])
    let b = ImportRule(name: "B", position: 1, conditions: [], actions: [])
    for r in [a, b] { _ = try await backend.importRules.create(r) }

    await #expect(throws: BackendError.self) {
      try await backend.importRules.reorder([a.id])
    }
    await #expect(throws: BackendError.self) {
      try await backend.importRules.reorder([a.id, b.id, UUID()])
    }

    // State is unchanged after failed reorders — ids, positions, everything.
    let all = try await backend.importRules.fetchAll()
    #expect(Set(all.map(\.id)) == Set([a.id, b.id]))
    #expect(all.map(\.position) == [0, 1])
  }

  @Test("exhaustive round-trip preserves every condition and action case")
  func exhaustiveRoundTrip() async throws {
    let (backend, _) = try TestBackend.create()
    let accountId = UUID()
    let transferAccountId = UUID()
    let categoryId = UUID()
    let rule = ImportRule(
      name: "Big Rule",
      position: 0,
      matchMode: .any,
      conditions: [
        .descriptionContains(["COFFEE", "CAFE"]),
        .descriptionDoesNotContain(["AMAZON"]),
        .descriptionBeginsWith("EFTPOS "),
        .amountIsPositive,
        .amountIsNegative,
        .amountBetween(min: Decimal(string: "-100")!, max: Decimal(string: "-1")!),
        .sourceAccountIs(accountId),
      ],
      actions: [
        .setPayee("Café"),
        .setCategory(categoryId),
        .appendNote("imported"),
        .markAsTransfer(toAccountId: transferAccountId),
        .skip,
      ],
      accountScope: accountId)
    _ = try await backend.importRules.create(rule)
    let all = try await backend.importRules.fetchAll()
    #expect(all.count == 1)
    #expect(all[0] == rule)
  }
}
