// Backends/GRDB/Records/ImportRuleRow+Mapping.swift

import Foundation
import OSLog

private let importRuleRowLogger = Logger(
  subsystem: "com.moolah.app", category: "ImportRuleRow")

extension ImportRuleRow {
  /// The CloudKit recordType on the wire. Frozen contract; existing
  /// iCloud zones reference this exact string regardless of how the
  /// local Swift type is named.
  static let recordType = "ImportRuleRecord"

  /// Builds the canonical CloudKit `recordName` for a given UUID. Mirrors
  /// `CKRecord.ID(recordType:uuid:zoneID:)` (`"<recordType>|<uuid>"`),
  /// preserved byte-for-byte so cached system-fields blobs continue to
  /// reference the same CKRecord identity after migration.
  static func recordName(for id: UUID) -> String {
    "\(recordType)|\(id.uuidString)"
  }

  /// Builds a row from a domain object. Encoding failures surface as
  /// empty `Data()` blobs and a logged error, matching the behaviour of
  /// the original SwiftData `ImportRuleRecord` initialiser so the
  /// migration is observationally equivalent.
  init(domain rule: ImportRule) {
    self.id = rule.id
    self.recordName = Self.recordName(for: rule.id)
    self.name = rule.name
    self.enabled = rule.enabled
    self.position = rule.position
    self.matchMode = rule.matchMode.rawValue
    self.accountScope = rule.accountScope
    self.encodedSystemFields = nil
    self.conditionsJSON = Self.encodeConditions(rule.conditions, ruleId: rule.id)
    self.actionsJSON = Self.encodeActions(rule.actions, ruleId: rule.id)
  }

  /// Decodes back to the domain shape. Decoding failures surface as the
  /// "empty match / no-op" sentinel and a logged warning — same
  /// behaviour as `ImportRuleRecord.toDomain()` so a corrupted blob
  /// degrades gracefully rather than failing the fetch.
  func toDomain() -> ImportRule {
    let conditions = Self.decodeConditions(conditionsJSON, ruleId: id)
    let actions = Self.decodeActions(actionsJSON, ruleId: id)
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

  // MARK: - JSON helpers
  //
  // The encoders/decoders are built with default settings (no
  // `outputFormatting`, `keyEncodingStrategy`, or `dateEncodingStrategy`
  // overrides). They MUST match the encoder used by
  // `Backends/CloudKit/Models/ImportRuleRecord.init(...)` byte-for-byte;
  // any divergence would change the CKRecord wire bytes and trip a
  // `.serverRecordChanged` cycle on the next sync.

  static func encodeConditions(_ conditions: [RuleCondition], ruleId: UUID) -> Data {
    do {
      return try JSONEncoder().encode(conditions)
    } catch {
      importRuleRowLogger.error(
        """
        Failed to encode ImportRule conditions for rule \(ruleId, privacy: .public): \
        \(error.localizedDescription, privacy: .public). Row will persist with empty conditions.
        """)
      return Data()
    }
  }

  static func encodeActions(_ actions: [RuleAction], ruleId: UUID) -> Data {
    do {
      return try JSONEncoder().encode(actions)
    } catch {
      importRuleRowLogger.error(
        """
        Failed to encode ImportRule actions for rule \(ruleId, privacy: .public): \
        \(error.localizedDescription, privacy: .public). Row will persist with empty actions.
        """)
      return Data()
    }
  }

  static func decodeConditions(_ data: Data, ruleId: UUID) -> [RuleCondition] {
    guard !data.isEmpty else { return [] }
    do {
      return try JSONDecoder().decode([RuleCondition].self, from: data)
    } catch {
      importRuleRowLogger.warning(
        """
        Failed to decode ImportRule conditions for rule \(ruleId, privacy: .public): \
        \(error.localizedDescription, privacy: .public). Rule loaded with no conditions \
        (empty match).
        """)
      return []
    }
  }

  static func decodeActions(_ data: Data, ruleId: UUID) -> [RuleAction] {
    guard !data.isEmpty else { return [] }
    do {
      return try JSONDecoder().decode([RuleAction].self, from: data)
    } catch {
      importRuleRowLogger.warning(
        """
        Failed to decode ImportRule actions for rule \(ruleId, privacy: .public): \
        \(error.localizedDescription, privacy: .public). Rule loaded with no actions \
        (no-op).
        """)
      return []
    }
  }
}
