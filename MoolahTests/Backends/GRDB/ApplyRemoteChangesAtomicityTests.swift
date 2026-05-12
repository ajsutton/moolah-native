// MoolahTests/Backends/GRDB/ApplyRemoteChangesAtomicityTests.swift

import CloudKit
import Foundation
import GRDB
import Testing

@testable import Moolah

/// Verifies that `ProfileDataSyncHandler.applyRemoteChanges` commits its
/// per-record-type saves and deletions inside a single GRDB transaction,
/// so `ValueObservation` consumers only see the final consistent state.
///
/// Regression test for the "transaction shows two legs briefly" bug:
/// when an iCloud fetch coalesces a leg-swap (save L_new + delete
/// L_old) into one `applyRemoteChanges` call, the prior implementation
/// committed each per-record-type group in its own write transaction
/// and produced a transient state where both legs were present in the
/// `transaction_leg` table. UI observers fired on the intermediate
/// commit, doubled the displayed amount, then settled on the next.
@Suite("ProfileDataSyncHandler.applyRemoteChanges atomicity")
@MainActor
struct ApplyRemoteChangesAtomicityTests {

  nonisolated private static let zoneID = CKRecordZone.ID(
    zoneName: "TestZone", ownerName: CKCurrentUserDefaultName)

  /// Counts post-commit hook invocations on a GRDB writer. Used to
  /// pin the number of `databaseDidCommit` events `applyRemoteChanges`
  /// produces — the same trigger `ValueObservation` listens on.
  private final class CommitCounter: TransactionObserver, @unchecked Sendable {
    var commits: Int = 0

    func observes(eventsOfKind: DatabaseEventKind) -> Bool { true }
    func databaseDidChange(with event: DatabaseEvent) {}
    func databaseWillCommit() throws {}
    func databaseDidCommit(_ database: Database) { commits += 1 }
    func databaseDidRollback(_ database: Database) {}
  }

  @Test("Mixed save + delete batch fires exactly one commit")
  func mixedSaveDeleteBatchFiresOneCommit() async throws {
    let harness = try ProfileDataSyncHandlerTestSupport.makeHandlerAndDatabase()
    let txnId = UUID()
    let oldLegId = UUID()
    let newLegId = UUID()
    let seedTxn = Self.makeTxn(id: txnId)
    let newLeg = Self.makeLeg(id: newLegId, transactionId: txnId)

    // Seed the local DB with the transaction header and the leg the
    // local update has already committed (mirrors the post-edit state).
    try await harness.database.write { database in
      try seedTxn.upsert(database)
      try newLeg.upsert(database)
    }

    // Attach the counter *after* seeding so the seed write is not
    // counted. The registration write is dropped by resetting the
    // counter right after.
    let counter = CommitCounter()
    try await harness.database.write { database in
      database.add(transactionObserver: counter, extent: .observerLifetime)
    }
    counter.commits = 0

    // Build the incoming fetch payload that triggered the bug:
    //   - saved: the parent transaction (echoed unchanged) + the
    //     ORIGINAL leg that local has already deleted. The fetch is
    //     replaying server-state that lags one update behind the
    //     local DB.
    //   - deleted: the original leg's recordID (the subsequent update
    //     deletion confirmed in the same fetch).
    let oldLegOnServer = Self.makeLeg(
      id: oldLegId, transactionId: txnId, like: newLeg)
    let savedRecords: [CKRecord] = [
      seedTxn.toCKRecord(in: Self.zoneID),
      oldLegOnServer.toCKRecord(in: Self.zoneID),
    ]
    let deleted: [(CKRecord.ID, String)] = [Self.legDeletion(id: oldLegId)]

    let result = harness.handler.applyRemoteChanges(saved: savedRecords, deleted: deleted)
    if case .saveFailed(let message) = result {
      Issue.record("applyRemoteChanges reported saveFailed: \(message)")
    }

    #expect(
      counter.commits == 1,
      "applyRemoteChanges must commit once; got \(counter.commits) commits")

    // Final state sanity: the deletion phase has run, so only the
    // local `newLegId` remains.
    let legCount = try await harness.database.read { database in
      try TransactionLegRow
        .filter(TransactionLegRow.Columns.transactionId == txnId)
        .fetchCount(database)
    }
    #expect(legCount == 1, "Final leg count must be 1; got \(legCount)")
  }

  @Test("Mid-batch failure rolls back every save in the same outer transaction")
  func midBatchFailureRollsBackEverything() async throws {
    let harness = try ProfileDataSyncHandlerTestSupport.makeHandlerAndDatabase()
    let txnId = UUID()
    let existingLegId = UUID()
    let failingLegId = UUID()
    let originalPayee = "Coffee"
    let mutatedPayee = "PAYEE THAT MUST NOT LAND"

    // Seed: one transaction header + one leg representing the state
    // before the fetched batch arrives.
    try await harness.database.write { database in
      try Self.makeTxn(id: txnId, payee: originalPayee).upsert(database)
      try Self.makeLeg(id: existingLegId, transactionId: txnId).upsert(database)
    }

    // Force the second leg in the batch to fail via a `BEFORE INSERT`
    // trigger keyed on a sentinel quantity. Without the single-outer-
    // write refactor, the header upsert and the first leg upsert would
    // have committed before the failure — and the regression we're
    // pinning is exactly that they DON'T.
    try await harness.database.write { database in
      try database.execute(
        sql: """
          CREATE TRIGGER fail_apply_remote_changes
          BEFORE INSERT ON transaction_leg
          WHEN NEW.quantity = -99999
          BEGIN
              SELECT RAISE(ABORT, 'forced failure mid-batch');
          END;
          """)
    }

    let mutatedTxn = Self.makeTxn(id: txnId, payee: mutatedPayee)
    let goodLeg = Self.makeLeg(id: UUID(), transactionId: txnId, quantity: -500)
    let failingLeg = Self.makeLeg(
      id: failingLegId, transactionId: txnId, quantity: -99999)
    let savedRecords: [CKRecord] = [
      mutatedTxn.toCKRecord(in: Self.zoneID),
      goodLeg.toCKRecord(in: Self.zoneID),
      failingLeg.toCKRecord(in: Self.zoneID),
    ]
    let deleted: [(CKRecord.ID, String)] = [Self.legDeletion(id: existingLegId)]

    let result = harness.handler.applyRemoteChanges(saved: savedRecords, deleted: deleted)
    guard case .saveFailed = result else {
      Issue.record("Expected .saveFailed; got \(result)")
      return
    }

    // Header payee is unchanged — the upsert that would have rewritten
    // it never committed.
    let txn = try await harness.database.read { database in
      try TransactionRow.filter(TransactionRow.Columns.id == txnId).fetchOne(database)
    }
    #expect(txn?.payee == originalPayee)

    // The pre-existing leg survives byte-equal AND no partial new legs
    // landed. The deletion in the batch never committed either.
    let legs = try await harness.database.read { database in
      try TransactionLegRow
        .filter(TransactionLegRow.Columns.transactionId == txnId)
        .fetchAll(database)
    }
    #expect(legs.count == 1, "Pre-existing leg must survive; got \(legs.count) legs")
    #expect(legs.first?.id == existingLegId)
  }

  // MARK: - Fixture Helpers

  nonisolated private static func makeTxn(
    id: UUID, payee: String = "Coffee"
  ) -> TransactionRow {
    TransactionRow(
      id: id,
      recordName: TransactionRow.recordName(for: id),
      date: Date(timeIntervalSince1970: 1_700_000_000),
      payee: payee,
      notes: nil,
      recurPeriod: nil,
      recurEvery: nil,
      importOriginRawDescription: nil,
      importOriginBankReference: nil,
      importOriginRawAmount: nil,
      importOriginRawBalance: nil,
      importOriginImportedAt: nil,
      importOriginImportSessionId: nil,
      importOriginSourceFilename: nil,
      importOriginParserIdentifier: nil,
      encodedSystemFields: nil)
  }

  /// Builds a leg with default per-test fields. When `like` is supplied
  /// the account, instrument, quantity, and type are copied so the
  /// server-orphan leg matches the local leg's "shape" — that's the
  /// scenario that doubled the displayed amount.
  nonisolated private static func makeLeg(
    id: UUID,
    transactionId: UUID,
    quantity: Int64? = nil,
    like template: TransactionLegRow? = nil
  ) -> TransactionLegRow {
    TransactionLegRow(
      id: id,
      recordName: TransactionLegRow.recordName(for: id),
      transactionId: transactionId,
      accountId: template?.accountId ?? UUID(),
      instrumentId: template?.instrumentId ?? Instrument.defaultTestInstrument.id,
      quantity: quantity ?? template?.quantity ?? -1000,
      type: template?.type ?? "expense",
      categoryId: nil,
      earmarkId: nil,
      sortOrder: 0,
      encodedSystemFields: nil,
      externalId: nil,
      counterpartyAddress: nil)
  }

  nonisolated private static func legDeletion(id: UUID) -> (CKRecord.ID, String) {
    (
      CKRecord.ID(
        recordType: TransactionLegRow.recordType,
        uuid: id,
        zoneID: Self.zoneID),
      TransactionLegRow.recordType
    )
  }
}
