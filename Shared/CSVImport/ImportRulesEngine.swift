import Foundation

/// Outcome of evaluating a set of `ImportRule`s against one candidate. The
/// orchestrator (`ImportStore`, Phase E) applies these back onto a
/// `ParsedTransaction` → `Transaction` mapping at persist time.
///
/// - `assignedPayee` / `assignedCategoryId`: nil if no rule hit those fields.
///   First-matching rule wins per field.
/// - `appendedNotes`: concatenation (oldest first) of every matching rule's
///   `.appendNote` actions. Space-separated.
/// - `transferTargetAccountId`: when set, the pipeline rewrites the
///   transaction's legs into a two-leg transfer. Evaluation short-circuits.
/// - `isSkipped`: rule said "skip this row". Evaluation short-circuits.
/// - `matchedRuleIds`: audit — which rules fired, in evaluation order.
struct RuleEvaluation: Sendable, Equatable {
  var transaction: ParsedTransaction
  var assignedPayee: String?
  var assignedCategoryId: UUID?
  var appendedNotes: String?
  var isSkipped: Bool
  var transferTargetAccountId: UUID?
  var matchedRuleIds: [UUID]
}

/// Stateless rule evaluator. Rules run in `position` order; disabled rules
/// and rules whose `accountScope` doesn't match the routed account are
/// skipped. Conditions run against the raw CSV fields (`rawDescription`,
/// `rawAmount`) so rule stability survives payee cleanup.
enum ImportRulesEngine {

  static func evaluate(
    _ transaction: ParsedTransaction,
    routedAccountId: UUID,
    rules: [ImportRule]
  ) -> RuleEvaluation {
    var evaluation = RuleEvaluation(
      transaction: transaction,
      assignedPayee: nil,
      assignedCategoryId: nil,
      appendedNotes: nil,
      isSkipped: false,
      transferTargetAccountId: nil,
      matchedRuleIds: [])

    let orderedRules =
      rules
      .filter { $0.enabled }
      .filter { $0.accountScope == nil || $0.accountScope == routedAccountId }
      .sorted { $0.position < $1.position }

    for rule in orderedRules {
      guard matches(rule: rule, transaction: transaction, accountId: routedAccountId) else {
        continue
      }
      evaluation.matchedRuleIds.append(rule.id)
      for action in rule.actions {
        switch action {
        case .setPayee(let payee):
          if evaluation.assignedPayee == nil {
            evaluation.assignedPayee = payee
          }
        case .setCategory(let categoryId):
          if evaluation.assignedCategoryId == nil {
            evaluation.assignedCategoryId = categoryId
          }
        case .appendNote(let note):
          evaluation.appendedNotes =
            evaluation.appendedNotes.map { "\($0) \(note)" } ?? note
        case .markAsTransfer(let toAccountId):
          evaluation.transferTargetAccountId = toAccountId
          return evaluation
        case .skip:
          evaluation.isSkipped = true
          return evaluation
        }
      }
    }
    return evaluation
  }

  // MARK: - Condition matching

  private static func matches(
    rule: ImportRule,
    transaction: ParsedTransaction,
    accountId: UUID
  ) -> Bool {
    if rule.conditions.isEmpty { return true }
    let results = rule.conditions.map { condition in
      evaluate(condition: condition, transaction: transaction, accountId: accountId)
    }
    switch rule.matchMode {
    case .all: return results.allSatisfy { $0 }
    case .any: return results.contains(true)
    }
  }

  private static func evaluate(
    condition: RuleCondition,
    transaction: ParsedTransaction,
    accountId: UUID
  ) -> Bool {
    let upperDescription = transaction.rawDescription.uppercased()
    switch condition {
    case .descriptionContains(let tokens):
      return tokens.contains { upperDescription.contains($0.uppercased()) }
    case .descriptionDoesNotContain(let tokens):
      return tokens.allSatisfy { !upperDescription.contains($0.uppercased()) }
    case .descriptionBeginsWith(let prefix):
      return upperDescription.hasPrefix(prefix.uppercased())
    case .amountIsPositive:
      return transaction.rawAmount > 0
    case .amountIsNegative:
      return transaction.rawAmount < 0
    case .amountBetween(let min, let max):
      return transaction.rawAmount >= min && transaction.rawAmount <= max
    case .sourceAccountIs(let id):
      return id == accountId
    }
  }
}
