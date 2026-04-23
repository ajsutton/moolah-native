import Foundation
import SwiftData

// Upsert helpers split out of `UITestSeedHydrator` so the main enum body stays
// under SwiftLint's `type_body_length` threshold. Every helper is idempotent:
// re-running the same seed (e.g., after a UI-testing re-launch) doesn't
// double-insert records.
extension UITestSeedHydrator {
  // MARK: - Upsert helpers

  static func upsertProfile(
    _ profile: Profile,
    into manager: ProfileContainerManager
  ) throws {
    let context = ModelContext(manager.indexContainer)
    let targetId = profile.id
    let descriptor = FetchDescriptor<ProfileRecord>(
      predicate: #Predicate { $0.id == targetId }
    )
    if try context.fetch(descriptor).first != nil { return }
    context.insert(ProfileRecord.from(profile: profile))
    try context.save()
  }

  static func upsertInstrument(
    _ instrument: Instrument,
    in context: ModelContext
  ) throws {
    let targetId = instrument.id
    let descriptor = FetchDescriptor<InstrumentRecord>(
      predicate: #Predicate { $0.id == targetId }
    )
    if try context.fetch(descriptor).first != nil { return }
    context.insert(InstrumentRecord.from(instrument))
  }

  static func upsertAccount(
    id: UUID,
    name: String,
    type: AccountType,
    instrumentId: String,
    position: Int,
    in context: ModelContext
  ) throws {
    let targetId = id
    let descriptor = FetchDescriptor<AccountRecord>(
      predicate: #Predicate { $0.id == targetId }
    )
    if try context.fetch(descriptor).first != nil { return }
    context.insert(
      AccountRecord(
        id: id,
        name: name,
        type: type.rawValue,
        instrumentId: instrumentId,
        position: position
      )
    )
  }

  static func upsertTrade(
    id: UUID,
    payee: String,
    date: Date,
    amount: InstrumentAmount,
    fromAccountId: UUID,
    toAccountId: UUID,
    in context: ModelContext
  ) throws {
    let targetId = id
    let descriptor = FetchDescriptor<TransactionRecord>(
      predicate: #Predicate { $0.id == targetId }
    )
    if try context.fetch(descriptor).first != nil { return }

    let txn = TransactionRecord(id: id, date: date, payee: payee)
    context.insert(txn)

    let outgoing = InstrumentAmount(quantity: -amount.quantity, instrument: amount.instrument)

    // Both legs are `.transfer` so the transaction satisfies
    // `Transaction.isSimple` (same type, amounts negate, distinct accounts,
    // no category/earmark on the second leg). That triggers the simple-mode
    // path in `TransactionDetailView`, which is what the focus, autocomplete,
    // and cross-currency tests exercise. Mixed `.expense`/`.income` would
    // render the custom multi-leg view, where the `defaultFocus(_:_:)`
    // modifier on the simple section never fires.
    context.insert(
      TransactionLegRecord(
        transactionId: id,
        accountId: fromAccountId,
        instrumentId: amount.instrument.id,
        quantity: outgoing.storageValue,
        type: TransactionType.transfer.rawValue,
        sortOrder: 0
      )
    )
    context.insert(
      TransactionLegRecord(
        transactionId: id,
        accountId: toAccountId,
        instrumentId: amount.instrument.id,
        quantity: amount.storageValue,
        type: TransactionType.transfer.rawValue,
        sortOrder: 1
      )
    )
  }

  static func upsertHistoricalExpense(
    id: UUID,
    payee: String,
    date: Date,
    amount: InstrumentAmount,
    accountId: UUID,
    in context: ModelContext
  ) throws {
    let targetId = id
    let descriptor = FetchDescriptor<TransactionRecord>(
      predicate: #Predicate { $0.id == targetId }
    )
    if try context.fetch(descriptor).first != nil { return }

    let txn = TransactionRecord(id: id, date: date, payee: payee)
    context.insert(txn)

    let outgoing = InstrumentAmount(quantity: -amount.quantity, instrument: amount.instrument)
    context.insert(
      TransactionLegRecord(
        transactionId: id,
        accountId: accountId,
        instrumentId: amount.instrument.id,
        quantity: outgoing.storageValue,
        type: TransactionType.expense.rawValue,
        sortOrder: 0
      )
    )
  }

  static func upsertCategory(
    id: UUID,
    name: String,
    in context: ModelContext
  ) throws {
    let targetId = id
    let descriptor = FetchDescriptor<CategoryRecord>(
      predicate: #Predicate { $0.id == targetId }
    )
    if try context.fetch(descriptor).first != nil { return }
    context.insert(CategoryRecord(id: id, name: name))
  }

  /// Inserts a two-leg expense split on the same account. Both legs share
  /// `accountId`, which makes `Transaction.isSimple` false (it requires
  /// `a.accountId != b.accountId`) and flips `TransactionDraft.isCustom`
  /// to true. Categories are left nil on both legs so the test can type
  /// into an empty category field and observe autocomplete behaviour.
  static func upsertCustomExpenseSplit(
    id: UUID,
    payee: String,
    date: Date,
    legAAmount: InstrumentAmount,
    legBAmount: InstrumentAmount,
    accountId: UUID,
    in context: ModelContext
  ) throws {
    let targetId = id
    let descriptor = FetchDescriptor<TransactionRecord>(
      predicate: #Predicate { $0.id == targetId }
    )
    if try context.fetch(descriptor).first != nil { return }

    let txn = TransactionRecord(id: id, date: date, payee: payee)
    context.insert(txn)

    let outgoingA = InstrumentAmount(
      quantity: -legAAmount.quantity, instrument: legAAmount.instrument)
    let outgoingB = InstrumentAmount(
      quantity: -legBAmount.quantity, instrument: legBAmount.instrument)

    context.insert(
      TransactionLegRecord(
        transactionId: id,
        accountId: accountId,
        instrumentId: legAAmount.instrument.id,
        quantity: outgoingA.storageValue,
        type: TransactionType.expense.rawValue,
        sortOrder: 0
      )
    )
    context.insert(
      TransactionLegRecord(
        transactionId: id,
        accountId: accountId,
        instrumentId: legBAmount.instrument.id,
        quantity: outgoingB.storageValue,
        type: TransactionType.expense.rawValue,
        sortOrder: 1
      )
    )
  }
}
