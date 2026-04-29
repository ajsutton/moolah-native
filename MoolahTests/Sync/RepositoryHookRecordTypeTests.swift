import Foundation
import GRDB
import Testing

@testable import Moolah

/// Pins the contract that every GRDB repository's `onRecordChanged` /
/// `onRecordDeleted` hook fires with the right `recordType` for every
/// row it mutates. Repositories that mutate more than one record type
/// (legs, budget items, child categories, the txn+leg pair built from
/// an opening balance) must tag each emit with its own type — the
/// `nextRecordZoneChangeBatch` lookup keys off these strings, so a
/// regression silently converts uploads into phantom deletes.
@Suite("Repository hooks emit (recordType, id) pairs")
@MainActor
struct RepositoryHookRecordTypeTests {

  // MARK: - Capture Helper

  /// Confined to `@MainActor` so the (non-Sendable) closures wired to the
  /// repository can append into the buffers without crossing actors.
  @MainActor
  final class HookCapture {
    var changed: [(recordType: String, id: UUID)] = []
    var deleted: [(recordType: String, id: UUID)] = []
  }

  // MARK: - Hook bridges

  /// Wraps a `HookCapture` in `@Sendable` closures by hopping back to the
  /// main actor before mutating the (non-Sendable) capture.
  private func makeChangedHook(
    _ capture: HookCapture
  ) -> @Sendable (String, UUID) -> Void {
    { recordType, id in
      Task { @MainActor in
        capture.changed.append((recordType, id))
      }
    }
  }

  private func makeDeletedHook(
    _ capture: HookCapture
  ) -> @Sendable (String, UUID) -> Void {
    { recordType, id in
      Task { @MainActor in
        capture.deleted.append((recordType, id))
      }
    }
  }

  /// Drains queued main-actor hops so callers can read the capture state
  /// after a repository write completes. The hooks dispatch onto
  /// `@MainActor` to avoid Sendable smuggling, so the capture buffers
  /// aren't populated synchronously with the write returning.
  private func drainHookHops() async throws {
    try await Task.sleep(for: .milliseconds(50))
  }

  // MARK: - TransactionRepository

  @Test("create(_:) emits one TransactionRecord and one TransactionLegRecord per leg")
  func transactionCreateEmitsLegRecordType() async throws {
    let database = try ProfileDatabase.openInMemory()
    let capture = HookCapture()
    let txnRepo = GRDBTransactionRepository(
      database: database,
      defaultInstrument: .defaultTestInstrument,
      conversionService: FixedConversionService(),
      onRecordChanged: makeChangedHook(capture),
      onRecordDeleted: makeDeletedHook(capture))
    // Leg-level hooks are emitted via the txn repo's bundled write path;
    // the legs hook closures we install here are observers only — they're
    // exercised by the leg-rows the txn repo writes alongside the header.
    let legHooksRepo = GRDBTransactionLegRepository(
      database: database,
      onRecordChanged: makeChangedHook(capture),
      onRecordDeleted: makeDeletedHook(capture))
    _ = legHooksRepo  // silence unused — installed for hook coverage

    let accountId = UUID()
    let txn = Transaction(
      date: Date(), payee: "Trade",
      legs: [
        makeContractTestLeg(accountId: accountId, quantity: -100, type: .transfer),
        makeContractTestLeg(accountId: accountId, quantity: 100, type: .transfer),
      ]
    )

    _ = try await txnRepo.create(txn)
    try await drainHookHops()

    let txnEmits = capture.changed.filter { $0.recordType == TransactionRow.recordType }
    #expect(txnEmits.map(\.id) == [txn.id])
    let legEmits = capture.changed.filter { $0.recordType == TransactionLegRow.recordType }
    // One leg-record emit per leg the txn write inserted (two legs in
    // this transfer). A regression that drops the per-leg emit would
    // surface as `legEmits.count == 0`.
    #expect(legEmits.count == 2)
    #expect(capture.deleted.isEmpty)
  }

  // MARK: - AccountRepository

  @Test("create with opening balance tags account, txn, and leg with their own record types")
  func accountCreateOpeningBalanceTagsRecordTypes() async throws {
    let database = try ProfileDatabase.openInMemory()
    let capture = HookCapture()
    let repo = GRDBAccountRepository(
      database: database,
      onRecordChanged: makeChangedHook(capture),
      onRecordDeleted: makeDeletedHook(capture))

    let account = Account(name: "Cash", type: .bank, instrument: .defaultTestInstrument)
    _ = try await repo.create(
      account,
      openingBalance: InstrumentAmount(quantity: 100, instrument: .defaultTestInstrument))
    try await drainHookHops()

    let accountEmits = capture.changed.filter { $0.recordType == AccountRow.recordType }
    #expect(accountEmits.map(\.id) == [account.id])
    // Opening-balance create writes a one-leg synthetic transaction
    // alongside the account row; one txn-record + one leg-record emit
    // each. A regression that mis-tags the txn or leg emit with the
    // account record type would drop these to zero.
    let txnEmits = capture.changed.filter { $0.recordType == TransactionRow.recordType }
    let legEmits = capture.changed.filter { $0.recordType == TransactionLegRow.recordType }
    #expect(txnEmits.count == 1)
    #expect(legEmits.count == 1)
  }

  // MARK: - EarmarkRepository

  @Test("setBudget emits with EarmarkBudgetItemRecord, not EarmarkRecord")
  func earmarkSetBudgetTagsBudgetItemRecord() async throws {
    let database = try ProfileDatabase.openInMemory()
    let capture = HookCapture()
    let earmarkRepo = GRDBEarmarkRepository(
      database: database,
      defaultInstrument: .defaultTestInstrument,
      onRecordChanged: makeChangedHook(capture),
      onRecordDeleted: makeDeletedHook(capture))
    let earmark = try await earmarkRepo.create(
      Earmark(name: "Holiday", instrument: .defaultTestInstrument))
    try await drainHookHops()
    capture.changed.removeAll()
    capture.deleted.removeAll()

    try await earmarkRepo.setBudget(
      earmarkId: earmark.id,
      categoryId: UUID(),
      amount: InstrumentAmount(quantity: 50, instrument: .defaultTestInstrument))
    try await drainHookHops()

    let earmarkEmits = capture.changed.filter { $0.recordType == EarmarkRow.recordType }
    #expect(earmarkEmits.isEmpty)
    // The setBudget write emits exactly one budget-item record so the
    // sync engine queues an EarmarkBudgetItemRecord upload (not an
    // EarmarkRecord one). A regression that mis-tags the emit would
    // surface as a zero count here.
    let budgetEmits = capture.changed.filter {
      $0.recordType == EarmarkBudgetItemRow.recordType
    }
    #expect(budgetEmits.count == 1)
  }
}
