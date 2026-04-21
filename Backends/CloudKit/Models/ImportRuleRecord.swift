import Foundation
import OSLog
import SwiftData

private let importRuleRecordLogger = Logger(
  subsystem: "com.moolah.app", category: "ImportRuleRecord")

@Model
final class ImportRuleRecord {

  #Index<ImportRuleRecord>([\.id])

  var id = UUID()
  var name: String = ""
  var enabled: Bool = true
  var position: Int = 0
  var matchMode: String = MatchMode.all.rawValue
  /// JSON-encoded [RuleCondition]. Kept as a single column because the
  /// associated-value enums don't have a clean per-field CKRecord mapping.
  var conditionsJSON = Data()
  /// JSON-encoded [RuleAction]. Same reasoning as conditionsJSON.
  var actionsJSON = Data()
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
    do {
      self.conditionsJSON = try JSONEncoder().encode(conditions)
    } catch {
      importRuleRecordLogger.error(
        """
        Failed to encode ImportRule conditions for rule \(id, privacy: .public): \
        \(error.localizedDescription, privacy: .public). Record will persist with \
        empty conditions.
        """)
      self.conditionsJSON = Data()
    }
    do {
      self.actionsJSON = try JSONEncoder().encode(actions)
    } catch {
      importRuleRecordLogger.error(
        """
        Failed to encode ImportRule actions for rule \(id, privacy: .public): \
        \(error.localizedDescription, privacy: .public). Record will persist with \
        empty actions.
        """)
      self.actionsJSON = Data()
    }
  }

  func toDomain() -> ImportRule {
    let conditions: [RuleCondition]
    do {
      conditions = try JSONDecoder().decode([RuleCondition].self, from: conditionsJSON)
    } catch {
      importRuleRecordLogger.warning(
        """
        Failed to decode ImportRule conditions for rule \(self.id, privacy: .public): \
        \(error.localizedDescription, privacy: .public). Rule will be loaded with no \
        conditions (empty match).
        """)
      conditions = []
    }
    let actions: [RuleAction]
    do {
      actions = try JSONDecoder().decode([RuleAction].self, from: actionsJSON)
    } catch {
      importRuleRecordLogger.warning(
        """
        Failed to decode ImportRule actions for rule \(self.id, privacy: .public): \
        \(error.localizedDescription, privacy: .public). Rule will be loaded with no \
        actions (no-op).
        """)
      actions = []
    }
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
