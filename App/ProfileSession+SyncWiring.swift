import CloudKit
import Foundation

extension ProfileSession {
  /// Wires each `CloudKit*Repository`'s change/delete callbacks to the
  /// given sync coordinator so local mutations queue the corresponding
  /// CloudKit send. Called from `init` for iCloud profiles.
  ///
  /// Each repository hands the wiring `(recordType, id)` so the coordinator
  /// can build the prefixed `<recordType>|<UUID>` recordName (issue #416).
  /// The repos that emit ids of more than one record type per call —
  /// transactions (txn + leg), accounts (account + opening-balance txn +
  /// leg), categories (category + reassigned legs + budget items), and
  /// earmarks (earmark + budget items) — all rely on the type travelling
  /// with the id; otherwise the wiring would mis-tag downstream records and
  /// `nextRecordZoneChangeBatch` would convert their save into a phantom
  /// delete (regression covered by `RepositoryHookRecordTypeTests`).
  func wireRepositorySync(coordinator: SyncCoordinator, zoneID: CKRecordZone.ID) {
    wireAccountsAndTransactionsSync(coordinator: coordinator, zoneID: zoneID)
    wireSimpleRepositorySync(coordinator: coordinator, zoneID: zoneID)
  }

  /// Wires repositories that additionally expose `onInstrumentChanged` —
  /// accounts and transactions — to the sync coordinator.
  private func wireAccountsAndTransactionsSync(
    coordinator: SyncCoordinator, zoneID: CKRecordZone.ID
  ) {
    if let repo = backend.accounts as? CloudKitAccountRepository {
      repo.onRecordChanged = { [weak coordinator] recordType, id in
        coordinator?.queueSave(recordType: recordType, id: id, zoneID: zoneID)
      }
      repo.onRecordDeleted = { [weak coordinator] recordType, id in
        coordinator?.queueDeletion(recordType: recordType, id: id, zoneID: zoneID)
      }
      repo.onInstrumentChanged = { [weak coordinator] id in
        coordinator?.queueSave(recordName: id, zoneID: zoneID)
      }
    }
    if let repo = backend.transactions as? CloudKitTransactionRepository {
      repo.onRecordChanged = { [weak coordinator] recordType, id in
        coordinator?.queueSave(recordType: recordType, id: id, zoneID: zoneID)
      }
      repo.onRecordDeleted = { [weak coordinator] recordType, id in
        coordinator?.queueDeletion(recordType: recordType, id: id, zoneID: zoneID)
      }
      repo.onInstrumentChanged = { [weak coordinator] id in
        coordinator?.queueSave(recordName: id, zoneID: zoneID)
      }
    }
  }

  /// Wires repositories that only need the `onRecordChanged` /
  /// `onRecordDeleted` pair — categories, earmarks, investments — to the
  /// sync coordinator.
  ///
  /// The GRDB-backed repos (`csvImportProfiles`, `importRules`) get
  /// their hook closures injected at backend construction time (see
  /// `makeCloudKitBackend`); they show up here only via
  /// `registerGRDBRepositoriesForSync(...)`, which makes them visible
  /// to `ProfileDataSyncHandler`'s dispatch tables.
  private func wireSimpleRepositorySync(
    coordinator: SyncCoordinator, zoneID: CKRecordZone.ID
  ) {
    if let repo = backend.categories as? CloudKitCategoryRepository {
      repo.onRecordChanged = { [weak coordinator] recordType, id in
        coordinator?.queueSave(recordType: recordType, id: id, zoneID: zoneID)
      }
      repo.onRecordDeleted = { [weak coordinator] recordType, id in
        coordinator?.queueDeletion(recordType: recordType, id: id, zoneID: zoneID)
      }
    }
    if let repo = backend.earmarks as? CloudKitEarmarkRepository {
      repo.onRecordChanged = { [weak coordinator] recordType, id in
        coordinator?.queueSave(recordType: recordType, id: id, zoneID: zoneID)
      }
      repo.onRecordDeleted = { [weak coordinator] recordType, id in
        coordinator?.queueDeletion(recordType: recordType, id: id, zoneID: zoneID)
      }
    }
    if let repo = backend.investments as? CloudKitInvestmentRepository {
      repo.onRecordChanged = { [weak coordinator] recordType, id in
        coordinator?.queueSave(recordType: recordType, id: id, zoneID: zoneID)
      }
      repo.onRecordDeleted = { [weak coordinator] recordType, id in
        coordinator?.queueDeletion(recordType: recordType, id: id, zoneID: zoneID)
      }
    }
    registerGRDBRepositoriesForSync(coordinator: coordinator)
  }

  /// Registers the per-profile GRDB repository bundle with the sync
  /// coordinator so `handlerForProfileZone` can build a
  /// `ProfileDataSyncHandler` that reaches them. Only registers when the
  /// backend is a `CloudKitBackend` — preview / test code paths skip
  /// registration silently.
  private func registerGRDBRepositoriesForSync(coordinator: SyncCoordinator) {
    guard let cloudBackend = backend as? CloudKitBackend else { return }
    coordinator.setProfileGRDBRepositories(
      profileId: profile.id,
      bundle: ProfileGRDBRepositories(
        csvImportProfiles: cloudBackend.grdbCSVImportProfiles,
        importRules: cloudBackend.grdbImportRules))
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
  /// `TransactionLegRecord` drives both account balances and earmark positions,
  /// so a remote leg-only change (e.g. category/earmark reassignment performed
  /// on another device) must reload both stores even if the parent
  /// `TransactionRecord` did not change in this batch.
  static func storesToReload(for changedTypes: Set<String>) -> StoreReloadPlan {
    var plan: StoreReloadPlan = []
    if changedTypes.contains(AccountRecord.recordType)
      || changedTypes.contains(TransactionRecord.recordType)
      || changedTypes.contains(TransactionLegRecord.recordType)
    {
      plan.insert(.accounts)
    }
    if changedTypes.contains(CategoryRecord.recordType) {
      plan.insert(.categories)
    }
    if changedTypes.contains(EarmarkRecord.recordType)
      || changedTypes.contains(EarmarkBudgetItemRecord.recordType)
      || changedTypes.contains(TransactionLegRecord.recordType)
    {
      plan.insert(.earmarks)
    }
    if changedTypes.contains(ImportRuleRow.recordType) {
      plan.insert(.importRules)
    }
    // NOTE: CSVImportProfileRow has no dedicated store — the setup form
    // fetches profiles directly via `backend.csvImportProfiles`. Remote
    // changes land in GRDB; the setup form reads through to the fresh
    // values on its own `task`.
    return plan
  }
}
