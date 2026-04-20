import Foundation
import OSLog
import Observation

/// Thin wrapper around `ImportRuleRepository`. Exposes an ordered `rules`
/// list for the rules settings view and a helper that counts how many
/// already-imported transactions would match a candidate rule (live preview).
@Observable
@MainActor
final class ImportRuleStore {

  private(set) var rules: [ImportRule] = []
  private(set) var isLoading = false
  private(set) var error: String?

  private let repository: any ImportRuleRepository
  private let logger = Logger(subsystem: "com.moolah.app", category: "ImportRuleStore")

  init(repository: any ImportRuleRepository) {
    self.repository = repository
  }

  func load() async {
    guard !isLoading else { return }
    isLoading = true
    defer { isLoading = false }
    error = nil
    do {
      let all = try await repository.fetchAll()
      rules = all.sorted { $0.position < $1.position }
    } catch {
      self.error = error.localizedDescription
      logger.error("Load rules failed: \(error.localizedDescription, privacy: .public)")
    }
  }

  /// Re-fetch rules without flipping `isLoading` or clearing `error`. Called
  /// when CloudKit delivers a remote change to an `ImportRuleRecord`. Replaces
  /// `rules` only when the fetched list differs so observers don't churn on
  /// no-op syncs.
  func reloadFromSync() async {
    do {
      let fresh = try await repository.fetchAll().sorted { $0.position < $1.position }
      if fresh != rules { rules = fresh }
    } catch {
      logger.error(
        "Sync reload of rules failed: \(error.localizedDescription, privacy: .public)")
    }
  }

  @discardableResult
  func create(_ rule: ImportRule) async -> ImportRule? {
    do {
      let saved = try await repository.create(rule)
      rules.append(saved)
      rules.sort { $0.position < $1.position }
      return saved
    } catch {
      self.error = error.localizedDescription
      logger.error("Create rule failed: \(error.localizedDescription, privacy: .public)")
      return nil
    }
  }

  @discardableResult
  func update(_ rule: ImportRule) async -> ImportRule? {
    do {
      let saved = try await repository.update(rule)
      if let index = rules.firstIndex(where: { $0.id == saved.id }) {
        rules[index] = saved
      }
      rules.sort { $0.position < $1.position }
      return saved
    } catch {
      self.error = error.localizedDescription
      logger.error("Update rule failed: \(error.localizedDescription, privacy: .public)")
      return nil
    }
  }

  func delete(id: UUID) async {
    do {
      try await repository.delete(id: id)
      rules.removeAll { $0.id == id }
    } catch {
      self.error = error.localizedDescription
      logger.error("Delete rule failed: \(error.localizedDescription, privacy: .public)")
    }
  }

  func reorder(_ orderedIds: [UUID]) async {
    do {
      try await repository.reorder(orderedIds)
      let indexById = Dictionary(
        uniqueKeysWithValues: orderedIds.enumerated().map { ($1, $0) })
      for index in rules.indices {
        rules[index].position = indexById[rules[index].id] ?? rules[index].position
      }
      rules.sort { $0.position < $1.position }
    } catch {
      self.error = error.localizedDescription
      logger.error("Reorder rules failed: \(error.localizedDescription, privacy: .public)")
    }
  }

  /// Live preview: given a candidate set of conditions + match mode, count
  /// how many already-imported transactions would match. The rule-editor
  /// view debounces before calling so we don't hammer the backend on every
  /// keystroke.
  func countAffected(
    conditions: [RuleCondition],
    matchMode: MatchMode,
    accountScope: UUID?,
    backend: any BackendProvider
  ) async -> Int {
    do {
      let page = try await backend.transactions.fetch(
        filter: TransactionFilter(), page: 0, pageSize: 2000)
      let candidate = ImportRule(
        name: "preview",
        position: 0,
        matchMode: matchMode,
        conditions: conditions,
        actions: [],
        accountScope: accountScope)
      return page.transactions.reduce(0) { count, tx in
        guard let origin = tx.importOrigin,
          let routingAccount = tx.legs.first?.accountId
        else {
          return count
        }
        let parsed = ParsedTransaction(
          date: tx.date,
          legs: tx.legs.map {
            ParsedLeg(
              accountId: $0.accountId, instrument: $0.instrument,
              quantity: $0.quantity, type: $0.type)
          },
          rawRow: [],
          rawDescription: origin.rawDescription,
          rawAmount: origin.rawAmount,
          rawBalance: origin.rawBalance,
          bankReference: origin.bankReference)
        let eval = ImportRulesEngine.evaluate(
          parsed, routedAccountId: routingAccount, rules: [candidate])
        return count + (eval.matchedRuleIds.isEmpty ? 0 : 1)
      }
    } catch {
      logger.error(
        "countAffected failed: \(error.localizedDescription, privacy: .public)")
      return 0
    }
  }
}
