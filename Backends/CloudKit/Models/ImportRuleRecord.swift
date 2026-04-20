import Foundation
import SwiftData

@Model
final class ImportRuleRecord {

  #Index<ImportRuleRecord>([\.id])

  var id: UUID = UUID()
  var name: String = ""
  var enabled: Bool = true
  var position: Int = 0
  var matchMode: String = MatchMode.all.rawValue
  /// JSON-encoded [RuleCondition]. Kept as a single column because the
  /// associated-value enums don't have a clean per-field CKRecord mapping.
  var conditionsJSON: Data = Data()
  /// JSON-encoded [RuleAction]. Same reasoning as conditionsJSON.
  var actionsJSON: Data = Data()
  var accountScope: UUID?
  var encodedSystemFields: Data?

  init(
    id: UUID = UUID(),
    name: String,
    enabled: Bool,
    position: Int,
    matchMode: MatchMode,
    conditions: [RuleCondition],
    actions: [RuleAction],
    accountScope: UUID?
  ) {
    self.id = id
    self.name = name
    self.enabled = enabled
    self.position = position
    self.matchMode = matchMode.rawValue
    self.accountScope = accountScope
    self.conditionsJSON = (try? JSONEncoder().encode(conditions)) ?? Data()
    self.actionsJSON = (try? JSONEncoder().encode(actions)) ?? Data()
  }

  func toDomain() -> ImportRule {
    let conditions =
      (try? JSONDecoder().decode([RuleCondition].self, from: conditionsJSON)) ?? []
    let actions =
      (try? JSONDecoder().decode([RuleAction].self, from: actionsJSON)) ?? []
    return ImportRule(
      id: id,
      name: name,
      enabled: enabled,
      position: position,
      matchMode: MatchMode(rawValue: matchMode) ?? .all,
      conditions: conditions,
      actions: actions,
      accountScope: accountScope)
  }

  static func from(_ rule: ImportRule) -> ImportRuleRecord {
    ImportRuleRecord(
      id: rule.id,
      name: rule.name,
      enabled: rule.enabled,
      position: rule.position,
      matchMode: rule.matchMode,
      conditions: rule.conditions,
      actions: rule.actions,
      accountScope: rule.accountScope)
  }
}
