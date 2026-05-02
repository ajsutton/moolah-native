import Foundation

extension ProfileSession {
  /// OptionSet for coalesced store reloads after a sync batch.
  struct StoreReloadPlan: OptionSet, Sendable, Equatable {
    let rawValue: Int
    static let accounts = StoreReloadPlan(rawValue: 1 << 0)
    static let categories = StoreReloadPlan(rawValue: 1 << 1)
    static let earmarks = StoreReloadPlan(rawValue: 1 << 2)
    static let importRules = StoreReloadPlan(rawValue: 1 << 3)
  }

  /// Which stores should be reloaded for a given set of changed record types.
  /// Exposed as a pure static function so the reload-mapping policy can be
  /// unit-tested without driving the debounced async task.
  ///
  /// `TransactionLegRow` drives both account balances and earmark positions,
  /// so a remote leg-only change (e.g. category/earmark reassignment performed
  /// on another device) must reload both stores even if the parent
  /// `TransactionRow` did not change in this batch.
  static func storesToReload(for changedTypes: Set<String>) -> StoreReloadPlan {
    var plan: StoreReloadPlan = []
    if changedTypes.contains(AccountRow.recordType)
      || changedTypes.contains(TransactionRow.recordType)
      || changedTypes.contains(TransactionLegRow.recordType)
    {
      plan.insert(.accounts)
    }
    if changedTypes.contains(CategoryRow.recordType) {
      plan.insert(.categories)
    }
    if changedTypes.contains(EarmarkRow.recordType)
      || changedTypes.contains(EarmarkBudgetItemRow.recordType)
      || changedTypes.contains(TransactionLegRow.recordType)
    {
      plan.insert(.earmarks)
    }
    if changedTypes.contains(ImportRuleRow.recordType) {
      plan.insert(.importRules)
    }
    // CSVImportProfileRow has no dedicated store — the setup form fetches
    // profiles directly via `backend.csvImportProfiles`. Remote changes
    // land in GRDB; the setup form reads through to the fresh values on
    // its own `task`.
    return plan
  }
}
