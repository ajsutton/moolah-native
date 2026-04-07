import Foundation

actor InMemoryEarmarkRepository: EarmarkRepository {
  private var earmarks: [UUID: Earmark]
  private var budgets: [UUID: [EarmarkBudgetItem]]

  init(initialEarmarks: [Earmark] = []) {
    self.earmarks = Dictionary(uniqueKeysWithValues: initialEarmarks.map { ($0.id, $0) })
    self.budgets = [:]
  }

  func fetchAll() async throws -> [Earmark] {
    return Array(earmarks.values).sorted()
  }

  func create(_ earmark: Earmark) async throws -> Earmark {
    earmarks[earmark.id] = earmark
    return earmark
  }

  func update(_ earmark: Earmark) async throws -> Earmark {
    guard earmarks[earmark.id] != nil else {
      throw BackendError.serverError(404)
    }
    earmarks[earmark.id] = earmark
    return earmark
  }

  func fetchBudget(earmarkId: UUID) async throws -> [EarmarkBudgetItem] {
    return budgets[earmarkId] ?? []
  }

  func updateBudget(earmarkId: UUID, items: [EarmarkBudgetItem]) async throws {
    guard earmarks[earmarkId] != nil else {
      throw BackendError.serverError(404)
    }
    budgets[earmarkId] = items
  }

  // For test setup
  func setEarmarks(_ earmarks: [Earmark]) {
    self.earmarks = Dictionary(uniqueKeysWithValues: earmarks.map { ($0.id, $0) })
  }
}
