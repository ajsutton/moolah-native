// MoolahTests/Backends/GRDB/SyncRoundTripTransactionTests.swift

import CloudKit
import Foundation
import GRDB
import Testing

@testable import Moolah

/// CKSyncEngine ↔ GRDB round-trip tests for `TransactionRow` and
/// `TransactionLegRow`. Sibling file to
/// `CoreFinancialGraphSyncRoundTripTests.swift`, which covers the other
/// six core financial graph row types. Same flow: device A produces a
/// CKRecord via `Row.toCKRecord(in:)`, device B's data handler applies
/// it via `applyRemoteChanges`, and we assert the GRDB row on device B
/// matches the source — including the cached `encodedSystemFields` blob
/// bit-for-bit.
@Suite("CKSyncEngine ↔ GRDB round trip — transactions and legs")
@MainActor
struct SyncRoundTripTransactionTests {

  private static let zoneID = CKRecordZone.ID(
    zoneName: "TestZone", ownerName: CKCurrentUserDefaultName)

  // MARK: - TransactionRow

  @Test("Transaction upsert round-trips through CKSyncEngine apply")
  func transactionRoundTrip() async throws {
    let harness = try ProfileDataSyncHandlerTestSupport.makeHandlerWithDatabase()
    let id = UUID()
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let source = TransactionRow(
      id: id,
      recordName: TransactionRow.recordName(for: id),
      date: date,
      payee: "Rent",
      notes: "Monthly",
      recurPeriod: RecurPeriod.month.rawValue,
      recurEvery: 1,
      importOriginRawDescription: nil,
      importOriginBankReference: nil,
      importOriginRawAmount: nil,
      importOriginRawBalance: nil,
      importOriginImportedAt: nil,
      importOriginImportSessionId: nil,
      importOriginSourceFilename: nil,
      importOriginParserIdentifier: nil,
      encodedSystemFields: nil)
    let ckRecord = source.toCKRecord(in: Self.zoneID)

    let result = harness.handler.applyRemoteChanges(saved: [ckRecord], deleted: [])
    if case .saveFailed(let message) = result {
      Issue.record("applyRemoteChanges reported saveFailed: \(message)")
    }

    let row = try await harness.database.read { database in
      try TransactionRow.filter(TransactionRow.Columns.id == id).fetchOne(database)
    }
    let resolved = try #require(row)
    #expect(resolved.id == id)
    #expect(resolved.payee == "Rent")
    #expect(resolved.recurPeriod == RecurPeriod.month.rawValue)
    #expect(resolved.recurEvery == 1)
    #expect(resolved.encodedSystemFields == ckRecord.encodedSystemFields)
  }

  // MARK: - TransactionLegRow

  /// Seeds the `account` and `transaction` parents the leg's FKs point
  /// at so the apply step has somewhere to land. Pulled out of the test
  /// body to keep the test under the function-body-length limit.
  private static func seedLegParents(
    database: any DatabaseWriter,
    txnId: UUID,
    accountId: UUID
  ) async throws {
    try await database.write { database in
      try AccountRow(
        domain: Account(id: accountId, name: "Cash", type: .bank, instrument: .AUD)
      )
      .insert(database)
      try TransactionRow(
        id: txnId,
        recordName: TransactionRow.recordName(for: txnId),
        date: Date(),
        payee: "Coffee",
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
        encodedSystemFields: nil
      ).insert(database)
    }
  }

  @Test("TransactionLeg upsert round-trips through CKSyncEngine apply")
  func transactionLegRoundTrip() async throws {
    let harness = try ProfileDataSyncHandlerTestSupport.makeHandlerWithDatabase()
    let txnId = UUID()
    let accountId = UUID()
    let legId = UUID()
    try await Self.seedLegParents(
      database: harness.database, txnId: txnId, accountId: accountId)

    let source = TransactionLegRow(
      id: legId,
      recordName: TransactionLegRow.recordName(for: legId),
      transactionId: txnId,
      accountId: accountId,
      instrumentId: Instrument.AUD.id,
      quantity: -1000,
      type: TransactionType.expense.rawValue,
      categoryId: nil,
      earmarkId: nil,
      sortOrder: 0,
      encodedSystemFields: nil)
    let ckRecord = source.toCKRecord(in: Self.zoneID)

    let result = harness.handler.applyRemoteChanges(saved: [ckRecord], deleted: [])
    if case .saveFailed(let message) = result {
      Issue.record("applyRemoteChanges reported saveFailed: \(message)")
    }

    let row = try await harness.database.read { database in
      try TransactionLegRow.filter(TransactionLegRow.Columns.id == legId)
        .fetchOne(database)
    }
    let resolved = try #require(row)
    #expect(resolved.id == legId)
    #expect(resolved.transactionId == txnId)
    #expect(resolved.accountId == accountId)
    #expect(resolved.quantity == -1000)
    #expect(resolved.encodedSystemFields == ckRecord.encodedSystemFields)
  }
}
