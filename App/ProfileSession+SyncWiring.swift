import Foundation

extension ProfileSession {
  /// Wires the per-profile GRDB repository bundle with the sync
  /// coordinator so local mutations queue the corresponding CloudKit
  /// send. The GRDB repos receive their hooks injected at backend
  /// construction time (see `makeCloudKitBackend`); this method
  /// publishes the concrete-class instances to `SyncCoordinator` so
  /// `handlerForProfileZone` can build a `ProfileDataSyncHandler` that
  /// reaches them.
  func wireRepositorySync(coordinator: SyncCoordinator) {
    registerGRDBRepositoriesForSync(coordinator: coordinator)
  }

  /// Registers the per-profile GRDB repository bundle with the sync
  /// coordinator so `handlerForProfileZone` can build a
  /// `ProfileDataSyncHandler` that reaches them. Only registers when the
  /// backend is a `CloudKitBackend` — preview / test code paths skip
  /// registration silently.
  ///
  /// **Pre-condition.** Must be called before `SyncCoordinator`
  /// processes any events for this profile. Guaranteed by
  /// `ProfileSession.init` call order: `wireRepositorySync` (which
  /// invokes this method) runs in `registerWithSyncCoordinator`, which
  /// is the last statement of `init`. The first sync event for the
  /// profile cannot arrive until `init` returns and the session is
  /// retained by the caller, so registration always wins the race.
  private func registerGRDBRepositoriesForSync(coordinator: SyncCoordinator) {
    guard let cloudBackend = backend as? CloudKitBackend else { return }
    coordinator.setProfileGRDBRepositories(
      profileId: profile.id,
      bundle: ProfileGRDBRepositories(
        csvImportProfiles: cloudBackend.grdbCSVImportProfiles,
        importRules: cloudBackend.grdbImportRules,
        instruments: cloudBackend.grdbInstruments,
        categories: cloudBackend.grdbCategories,
        accounts: cloudBackend.grdbAccounts,
        earmarks: cloudBackend.grdbEarmarks,
        earmarkBudgetItems: cloudBackend.grdbEarmarkBudgetItems,
        investmentValues: cloudBackend.grdbInvestments,
        transactions: cloudBackend.grdbTransactions,
        transactionLegs: cloudBackend.grdbTransactionLegs))
  }

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
