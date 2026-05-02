// MoolahTests/Sync/ApplyRemoteChangesOutOfOrderTests.swift

@preconcurrency import CloudKit
import Foundation
import GRDB
import Testing

@testable import Moolah

/// Reproduces the v1.1.0-rc.12 incident as a unit test: a single
/// CKRecord for an `InvestmentValueRow` whose parent `account` row
/// doesn't exist locally must succeed at apply time. Under v4 (FK
/// enforced) the insert tripped SQLite-19 → `.saveFailed(...)` →
/// infinite re-fetch loop. v5 dropped the FK; the row lands cleanly.
@Suite("Sync apply tolerates out-of-order CKRecord delivery")
struct ApplyRemoteChangesOutOfOrderTests {

  // Mirrors the suite-local zone constant used by every existing
  // round-trip test (e.g. SyncRoundTripTransactionTests). The handler
  // does not constrain which zone its records live in for apply
  // semantics; this just needs to be a valid CKRecordZone.ID.
  private static let zoneID = CKRecordZone.ID(
    zoneName: "TestZone", ownerName: CKCurrentUserDefaultName)

  @Test("InvestmentValue CKRecord landing before its parent account succeeds")
  func investmentValueArrivesBeforeAccount() async throws {
    // Suite is intentionally NOT `@MainActor`. `applyRemoteChanges` is
    // `nonisolated` and is called by CKSyncEngine off the main actor in
    // production; calling it from `@MainActor` here would block the
    // main thread on a sync `database.write { ... }` and exercise the
    // wrong execution context. `makeHandlerWithDatabase` is itself
    // `@MainActor`, so the harness is constructed via `MainActor.run`.
    let harness = try await MainActor.run {
      try ProfileDataSyncHandlerTestSupport.makeHandlerWithDatabase()
    }
    // No parent rows seeded — the database is intentionally empty.

    let orphanAccountId = UUID()
    let ivId = UUID()
    let ivRow = InvestmentValueRow(
      id: ivId,
      recordName: InvestmentValueRow.recordName(for: ivId),
      accountId: orphanAccountId,
      date: Date(timeIntervalSince1970: 1_700_000_000),
      value: 100_000,
      instrumentId: "USD",
      encodedSystemFields: nil)
    let ckRecord = ivRow.toCKRecord(in: Self.zoneID)

    // Apply — must NOT throw, must NOT report .saveFailed.
    let result = harness.handler.applyRemoteChanges(saved: [ckRecord], deleted: [])

    if case .saveFailed(let message) = result {
      Issue.record("Expected success, got .saveFailed(\(message))")
    }

    // The row must land in GRDB even though the account is missing —
    // that is the new contract after the v5 FK removal.
    let count = try await harness.database.read { database in
      try Int.fetchOne(
        database,
        sql: "SELECT COUNT(*) FROM investment_value WHERE id = ?",
        arguments: [ivId]) ?? -1
    }
    #expect(count == 1)
  }

  /// Symmetric coverage for the `transaction_leg.transaction_id ON DELETE
  /// CASCADE` FK that v3 enforced. Under v4 a `TransactionLegRow` arriving
  /// before its parent `TransactionRow` would have produced the same
  /// SQLite-19 error rc.12 produced for investment values. v5 dropped the
  /// FK; the leg lands cleanly even with no parent transaction in GRDB.
  @Test("TransactionLeg CKRecord landing before its parent transaction succeeds")
  func transactionLegArrivesBeforeTransaction() async throws {
    let harness = try await MainActor.run {
      try ProfileDataSyncHandlerTestSupport.makeHandlerWithDatabase()
    }

    let orphanTransactionId = UUID()
    let legId = UUID()
    let legRow = TransactionLegRow(
      id: legId,
      recordName: TransactionLegRow.recordName(for: legId),
      transactionId: orphanTransactionId,
      accountId: nil,
      instrumentId: "USD",
      quantity: 1000,
      type: TransactionType.expense.rawValue,
      categoryId: nil,
      earmarkId: nil,
      sortOrder: 0,
      encodedSystemFields: nil)
    let ckRecord = legRow.toCKRecord(in: Self.zoneID)

    let result = harness.handler.applyRemoteChanges(saved: [ckRecord], deleted: [])

    if case .saveFailed(let message) = result {
      Issue.record("Expected success, got .saveFailed(\(message))")
    }

    let count = try await harness.database.read { database in
      try Int.fetchOne(
        database,
        sql: "SELECT COUNT(*) FROM transaction_leg WHERE id = ?",
        arguments: [legId]) ?? -1
    }
    #expect(count == 1)
  }
}
