import Foundation
import GRDB

// Upsert helpers split out of `UITestSeedHydrator` so the main enum body stays
// under SwiftLint's `type_body_length` threshold. Every helper is idempotent:
// re-running the same seed (e.g. after a UI-testing re-launch) doesn't
// double-insert records.
//
// Per-profile data (accounts, transactions, categories, instruments) and
// the profile index itself both live in GRDB. The legacy SwiftData
// `ProfileRecord` class survives in the build only as the one-shot
// migrator's source — nothing in the test hydration path touches it.
extension UITestSeedHydrator {
  // MARK: - Specs
  //
  // Struct wrappers bundle the per-record fields callers provide. They keep
  // the upsert call sites self-documenting while holding each helper's
  // parameter count under SwiftLint's threshold.

  struct AccountSpec {
    let id: UUID
    let name: String
    let type: AccountType
    let instrumentId: String
    let position: Int
  }

  struct TradeSpec {
    let id: UUID
    let payee: String
    let date: Date
    let amount: InstrumentAmount
    let fromAccountId: UUID
    let toAccountId: UUID
  }

  struct HistoricalExpenseSpec {
    let id: UUID
    let payee: String
    let date: Date
    let amount: InstrumentAmount
    let accountId: UUID
    let categoryId: UUID?
  }

  struct CustomExpenseSplitSpec {
    let id: UUID
    let payee: String
    let date: Date
    let legAAmount: InstrumentAmount
    let legBAmount: InstrumentAmount
    let accountId: UUID
  }

  // MARK: - Profile (GRDB profile-index DB)

  /// Writes a `ProfileRow` into `profile-index.sqlite`. Idempotent —
  /// `upsert` matches on the primary key, so a re-hydrated seed simply
  /// overwrites with the same values.
  ///
  /// Synchronous because `MoolahApp.init` (the only caller chain) is
  /// not `async`. Goes directly through the manager's
  /// `profileIndexDatabase` queue with the GRDB sync write API rather
  /// than the repository's `async upsert` so the call site stays
  /// synchronous.
  ///
  /// SAFETY: this is a synchronous GRDB write invoked from `@MainActor`
  /// (via `MoolahApp.init`). It is test-only and the profile-index DB
  /// is small (a single row per profile, single-digit row count in
  /// practice), so the main-thread block is sub-millisecond and the
  /// calling-thread block is acceptable here. Production code must not
  /// adopt this pattern.
  static func upsertProfile(
    _ profile: Profile,
    into manager: ProfileContainerManager
  ) throws {
    try manager.profileIndexDatabase.write { database in
      try ProfileRow(domain: profile).upsert(database)
    }
  }

  // MARK: - Per-profile graph (GRDB)

  static func upsertInstrument(_ instrument: Instrument, in database: Database) throws {
    try InstrumentRow(domain: instrument).upsert(database)
  }

  static func upsertAccount(_ spec: AccountSpec, in database: Database) throws {
    let row = AccountRow(
      id: spec.id,
      recordName: AccountRow.recordName(for: spec.id),
      name: spec.name,
      type: spec.type.rawValue,
      instrumentId: spec.instrumentId,
      position: spec.position,
      isHidden: false,
      encodedSystemFields: nil,
      valuationMode: ValuationMode.recordedValue.rawValue)
    try row.upsert(database)
  }

  static func upsertCategory(id: UUID, name: String, in database: Database) throws {
    try CategoryRow(domain: Moolah.Category(id: id, name: name)).upsert(database)
  }

  /// Inserts a two-leg `.transfer` transaction. Both legs are `.transfer`
  /// so the transaction satisfies `Transaction.isSimple` (same type,
  /// amounts negate, distinct accounts, no category/earmark on the second
  /// leg). That triggers the simple-mode path in `TransactionDetailView`,
  /// which is what the focus, autocomplete, and cross-currency tests
  /// exercise. Mixed `.expense`/`.income` would render the custom
  /// multi-leg view, where the `defaultFocus(_:_:)` modifier on the simple
  /// section never fires.
  ///
  /// Idempotency comes from the parent-existence guard: if the transaction
  /// already exists in this database (e.g. a re-hydration call), the
  /// helper returns and leg inserts are skipped. The whole seed runs in a
  /// single `database.write { ... }` transaction at the call site, so
  /// partial commits aren't possible.
  static func upsertTrade(_ spec: TradeSpec, in database: Database) throws {
    if try TransactionRow.fetchOne(database, key: spec.id) != nil { return }

    try TransactionRow(domain: emptyTransaction(from: spec)).insert(database)

    let outgoing = TransactionLeg(
      accountId: spec.fromAccountId,
      instrument: spec.amount.instrument,
      quantity: -spec.amount.quantity,
      type: .transfer)
    let incoming = TransactionLeg(
      accountId: spec.toAccountId,
      instrument: spec.amount.instrument,
      quantity: spec.amount.quantity,
      type: .transfer)
    try TransactionLegRow(domain: outgoing, transactionId: spec.id, sortOrder: 0)
      .insert(database)
    try TransactionLegRow(domain: incoming, transactionId: spec.id, sortOrder: 1)
      .insert(database)
  }

  static func upsertHistoricalExpense(
    _ spec: HistoricalExpenseSpec,
    in database: Database
  ) throws {
    if try TransactionRow.fetchOne(database, key: spec.id) != nil { return }

    let txn = Transaction(id: spec.id, date: spec.date, payee: spec.payee, legs: [])
    try TransactionRow(domain: txn).insert(database)

    let leg = TransactionLeg(
      accountId: spec.accountId,
      instrument: spec.amount.instrument,
      quantity: -spec.amount.quantity,
      type: .expense,
      categoryId: spec.categoryId)
    try TransactionLegRow(domain: leg, transactionId: spec.id, sortOrder: 0)
      .insert(database)
  }

  /// Inserts a two-leg expense split on the same account. Both legs share
  /// `accountId`, which makes `Transaction.isSimple` false (it requires
  /// `a.accountId != b.accountId`) and flips `TransactionDraft.isCustom`
  /// to true. Categories are left nil on both legs so the test can type
  /// into an empty category field and observe autocomplete behaviour.
  static func upsertCustomExpenseSplit(
    _ spec: CustomExpenseSplitSpec,
    in database: Database
  ) throws {
    if try TransactionRow.fetchOne(database, key: spec.id) != nil { return }

    let txn = Transaction(id: spec.id, date: spec.date, payee: spec.payee, legs: [])
    try TransactionRow(domain: txn).insert(database)

    let legA = TransactionLeg(
      accountId: spec.accountId,
      instrument: spec.legAAmount.instrument,
      quantity: -spec.legAAmount.quantity,
      type: .expense)
    let legB = TransactionLeg(
      accountId: spec.accountId,
      instrument: spec.legBAmount.instrument,
      quantity: -spec.legBAmount.quantity,
      type: .expense)
    try TransactionLegRow(domain: legA, transactionId: spec.id, sortOrder: 0)
      .insert(database)
    try TransactionLegRow(domain: legB, transactionId: spec.id, sortOrder: 1)
      .insert(database)
  }

  /// Builds a legless `Transaction` whose only role is to seed
  /// `TransactionRow(domain:)`. The legs are inserted separately into
  /// `transaction_leg` and aren't part of the row mapping.
  private static func emptyTransaction(from spec: TradeSpec) -> Transaction {
    Transaction(id: spec.id, date: spec.date, payee: spec.payee, legs: [])
  }
}
