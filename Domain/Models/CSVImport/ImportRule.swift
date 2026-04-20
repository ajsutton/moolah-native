import Foundation

/// Whether a rule's conditions combine with AND (`all`) or OR (`any`).
enum MatchMode: String, Codable, Sendable { case any, all }

/// The predicates a rule can match on. Every condition operates on the
/// untouched CSV fields (`ImportOrigin.rawDescription`, `rawAmount`, etc.)
/// so rules stay stable even after payee cleanup.
enum RuleCondition: Codable, Sendable, Hashable {
  case descriptionContains([String])
  case descriptionDoesNotContain([String])
  case descriptionBeginsWith(String)
  case amountIsPositive
  case amountIsNegative
  case amountBetween(min: Decimal, max: Decimal)
  case sourceAccountIs(UUID)
}

/// The mutations a rule can apply to a `ParsedTransaction`. First-rule-wins
/// for payee and category fields; `appendNote` stacks (oldest first);
/// `markAsTransfer` and `skip` short-circuit further evaluation.
enum RuleAction: Codable, Sendable, Hashable {
  case setPayee(String)
  case setCategory(UUID)
  case appendNote(String)
  case markAsTransfer(toAccountId: UUID)
  case skip
}

/// A user-defined rule applied during CSV import. Rules run in `position`
/// order, skipping disabled ones and those whose `accountScope` does not
/// match the routed account (nil = global).
///
/// Synced via CloudKit so the rule library follows the user across devices.
struct ImportRule: Codable, Sendable, Identifiable, Hashable {
  let id: UUID
  var name: String
  var enabled: Bool
  var position: Int
  var matchMode: MatchMode
  var conditions: [RuleCondition]
  var actions: [RuleAction]
  var accountScope: UUID?

  init(
    id: UUID = UUID(),
    name: String,
    enabled: Bool = true,
    position: Int,
    matchMode: MatchMode = .all,
    conditions: [RuleCondition],
    actions: [RuleAction],
    accountScope: UUID? = nil
  ) {
    self.id = id
    self.name = name
    self.enabled = enabled
    self.position = position
    self.matchMode = matchMode
    self.conditions = conditions
    self.actions = actions
    self.accountScope = accountScope
  }
}
