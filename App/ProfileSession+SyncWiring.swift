import Foundation

extension ProfileSession {
  /// OptionSet for coalesced store reloads after a sync batch.
  ///
  /// Every legacy slot is intentionally retained even though the
  /// reactive migration has emptied the dispatch table — the
  /// `OptionSet` shape stays in place so a future imperative store can
  /// be re-added to `storesToReload` without resurrecting the type and
  /// every test that asserts against it.
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
  /// AccountStore, EarmarkStore, CategoryStore, and ImportRuleStore
  /// are all reactive — they subscribe to their repositories'
  /// `observeAll()` streams in `init`, so account / transaction /
  /// transaction-leg / earmark / earmark-budget-item / category /
  /// import-rule changes propagate without an explicit reload entry
  /// here. The function currently always returns an empty plan; it
  /// stays in place so a future imperative store can be added back
  /// without re-introducing the dispatch site.
  static func storesToReload(for changedTypes: Set<String>) -> StoreReloadPlan {
    // Every previously-imperative store is now reactive. CSVImportProfileRow
    // has no dedicated store — the setup form fetches profiles directly
    // via `backend.csvImportProfiles`. Remote changes land in GRDB; the
    // setup form reads through to the fresh values on its own `task`.
    _ = changedTypes
    return []
  }
}
