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
  /// AccountStore and EarmarkStore are reactive — they subscribe to their
  /// repositories' `observeAll()` streams in `init`, so account /
  /// transaction / transaction-leg / earmark / earmark-budget-item
  /// changes propagate without an explicit reload entry here.
  static func storesToReload(for changedTypes: Set<String>) -> StoreReloadPlan {
    var plan: StoreReloadPlan = []
    // .accounts and .earmarks no longer needed — both stores are reactive.
    // Account / Transaction / TransactionLeg / Earmark / EarmarkBudgetItem
    // changes propagate via AccountRepository.observeAll() and
    // EarmarkRepository.observeAll(), with rate-cache changes folded in
    // via InstrumentConversionService.observeRates().
    if changedTypes.contains(CategoryRow.recordType) {
      plan.insert(.categories)
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
