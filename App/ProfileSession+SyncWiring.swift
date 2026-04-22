import CloudKit
import Foundation

extension ProfileSession {
  /// Wires each `CloudKit*Repository`'s change/delete callbacks to the
  /// given sync coordinator so local mutations queue the corresponding
  /// CloudKit send. Called from `init` for iCloud profiles.
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
      repo.onRecordChanged = { [weak coordinator] id in
        coordinator?.queueSave(id: id, zoneID: zoneID)
      }
      repo.onRecordDeleted = { [weak coordinator] id in
        coordinator?.queueDeletion(id: id, zoneID: zoneID)
      }
      repo.onInstrumentChanged = { [weak coordinator] id in
        coordinator?.queueSave(recordName: id, zoneID: zoneID)
      }
    }
    if let repo = backend.transactions as? CloudKitTransactionRepository {
      repo.onRecordChanged = { [weak coordinator] id in
        coordinator?.queueSave(id: id, zoneID: zoneID)
      }
      repo.onRecordDeleted = { [weak coordinator] id in
        coordinator?.queueDeletion(id: id, zoneID: zoneID)
      }
      repo.onInstrumentChanged = { [weak coordinator] id in
        coordinator?.queueSave(recordName: id, zoneID: zoneID)
      }
    }
  }

  /// Wires repositories that only need the `onRecordChanged` /
  /// `onRecordDeleted` pair — categories, earmarks, investments,
  /// csvImportProfiles, importRules — to the sync coordinator.
  private func wireSimpleRepositorySync(
    coordinator: SyncCoordinator, zoneID: CKRecordZone.ID
  ) {
    if let repo = backend.categories as? CloudKitCategoryRepository {
      repo.onRecordChanged = { [weak coordinator] id in
        coordinator?.queueSave(id: id, zoneID: zoneID)
      }
      repo.onRecordDeleted = { [weak coordinator] id in
        coordinator?.queueDeletion(id: id, zoneID: zoneID)
      }
    }
    if let repo = backend.earmarks as? CloudKitEarmarkRepository {
      repo.onRecordChanged = { [weak coordinator] id in
        coordinator?.queueSave(id: id, zoneID: zoneID)
      }
      repo.onRecordDeleted = { [weak coordinator] id in
        coordinator?.queueDeletion(id: id, zoneID: zoneID)
      }
    }
    if let repo = backend.investments as? CloudKitInvestmentRepository {
      repo.onRecordChanged = { [weak coordinator] id in
        coordinator?.queueSave(id: id, zoneID: zoneID)
      }
      repo.onRecordDeleted = { [weak coordinator] id in
        coordinator?.queueDeletion(id: id, zoneID: zoneID)
      }
    }
    if let repo = backend.csvImportProfiles as? CloudKitCSVImportProfileRepository {
      repo.onRecordChanged = { [weak coordinator] id in
        coordinator?.queueSave(id: id, zoneID: zoneID)
      }
      repo.onRecordDeleted = { [weak coordinator] id in
        coordinator?.queueDeletion(id: id, zoneID: zoneID)
      }
    }
    if let repo = backend.importRules as? CloudKitImportRuleRepository {
      repo.onRecordChanged = { [weak coordinator] id in
        coordinator?.queueSave(id: id, zoneID: zoneID)
      }
      repo.onRecordDeleted = { [weak coordinator] id in
        coordinator?.queueDeletion(id: id, zoneID: zoneID)
      }
    }
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
    if changedTypes.contains(ImportRuleRecord.recordType) {
      plan.insert(.importRules)
    }
    // NOTE: CSVImportProfileRecord has no dedicated store — the setup form
    // fetches profiles directly via `backend.csvImportProfiles`. Remote
    // changes land in SwiftData; the setup form reads through to the fresh
    // values on its own `task`.
    return plan
  }
}
