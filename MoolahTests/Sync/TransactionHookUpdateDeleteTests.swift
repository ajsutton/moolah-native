import Foundation
import GRDB
import Testing

@testable import Moolah

/// Pins the per-leg multi-type hook contract for `GRDBTransactionRepository`
/// `update(_:)` and `delete(id:)`. The header tests for `create(_:)` live
/// in `RepositoryHookRecordTypeTests`; these are split out so neither
/// file exceeds SwiftLint's 250-line `type_body_length` budget.
///
/// A regression that hard-coded `TransactionRow.recordType` on the leg
/// emits in `update` / `delete` would upload leg records under the wrong
/// recordName and phantom-delete on every other device.
@Suite("Transaction hooks emit per-leg record types on update/delete")
@MainActor
struct TransactionHookUpdateDeleteTests {

  /// Confined to `@MainActor` so the (non-Sendable) closures wired to the
  /// repository can append into the buffers without crossing actors.
  @MainActor
  final class HookCapture {
    var changed: [(recordType: String, id: UUID)] = []
    var deleted: [(recordType: String, id: UUID)] = []
  }

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

  private func drainHookHops() async throws {
    try await Task.sleep(for: .milliseconds(50))
  }

  @Test("update(_:) emits TransactionRecord change plus per-leg LegRecord changes/deletes")
  func transactionUpdateEmitsLegRecordType() async throws {
    let database = try ProfileDatabase.openInMemory()
    let capture = HookCapture()
    let txnRepo = GRDBTransactionRepository(
      database: database,
      defaultInstrument: .defaultTestInstrument,
      conversionService: FixedConversionService(),
      onRecordChanged: makeChangedHook(capture),
      onRecordDeleted: makeDeletedHook(capture))

    let accountId = UUID()
    let txn = try await txnRepo.create(
      Transaction(
        date: Date(), payee: "Trade",
        legs: [
          makeContractTestLeg(accountId: accountId, quantity: -100, type: .transfer),
          makeContractTestLeg(accountId: accountId, quantity: 100, type: .transfer),
        ]))
    try await drainHookHops()
    capture.changed.removeAll()
    capture.deleted.removeAll()

    // Update with a fresh 2-leg set. `performUpdate` always replaces
    // every leg row (new UUIDs assigned inside the repo) so the hook
    // fan-out is: 1 TransactionRow change, 2 TransactionLegRow changes
    // for the new legs, 2 TransactionLegRow deletes for the old legs.
    let updated = Transaction(
      id: txn.id, date: txn.date, payee: "Trade",
      legs: [
        makeContractTestLeg(accountId: accountId, quantity: -50, type: .transfer),
        makeContractTestLeg(accountId: accountId, quantity: 50, type: .transfer),
      ])
    _ = try await txnRepo.update(updated)
    try await drainHookHops()

    let txnEmits = capture.changed.filter { $0.recordType == TransactionRow.recordType }
    #expect(txnEmits.map(\.id) == [txn.id])
    let legChanges = capture.changed.filter { $0.recordType == TransactionLegRow.recordType }
    // A regression that mis-tagged the per-leg insert emit with the
    // TransactionRow.recordType would drop this count to 0.
    #expect(legChanges.count == 2)
    let legDeletes = capture.deleted.filter { $0.recordType == TransactionLegRow.recordType }
    #expect(legDeletes.count == 2)
    let txnDeletes = capture.deleted.filter { $0.recordType == TransactionRow.recordType }
    #expect(txnDeletes.isEmpty)
  }

  @Test("delete(id:) emits TransactionRecord delete plus per-leg LegRecord deletes")
  func transactionDeleteEmitsLegRecordType() async throws {
    let database = try ProfileDatabase.openInMemory()
    let capture = HookCapture()
    let txnRepo = GRDBTransactionRepository(
      database: database,
      defaultInstrument: .defaultTestInstrument,
      conversionService: FixedConversionService(),
      onRecordChanged: makeChangedHook(capture),
      onRecordDeleted: makeDeletedHook(capture))

    let accountId = UUID()
    let txn = try await txnRepo.create(
      Transaction(
        date: Date(), payee: "Trade",
        legs: [
          makeContractTestLeg(accountId: accountId, quantity: -100, type: .transfer),
          makeContractTestLeg(accountId: accountId, quantity: 100, type: .transfer),
        ]))
    try await drainHookHops()
    capture.changed.removeAll()
    capture.deleted.removeAll()

    try await txnRepo.delete(id: txn.id)
    try await drainHookHops()

    let txnDeletes = capture.deleted.filter { $0.recordType == TransactionRow.recordType }
    #expect(txnDeletes.map(\.id) == [txn.id])
    let legDeletes = capture.deleted.filter { $0.recordType == TransactionLegRow.recordType }
    // Two legs created → two leg-deletes emitted. A regression that
    // hard-coded `TransactionRow.recordType` on leg emits would drop
    // these to zero (and uploads would phantom-delete on other devices).
    #expect(legDeletes.count == 2)
    #expect(capture.changed.isEmpty)
  }
}
