// MoolahTests/Backends/GRDB/GRDBCreateManyTests.swift

import Foundation
import GRDB
import Testing

@testable import Moolah

/// GRDB-specific contract for the bulk `createMany(_:)` path:
///
/// 1. Atomicity. A failure on any leg insert rolls back every header,
///    every leg, and every auto-inserted instrument across the whole
///    input array — leaving the DB byte-equal to the pre-call state.
/// 2. Hook fan-out. After the write commits, `onRecordChanged` fires
///    exactly once per transaction header and once per leg;
///    `onInstrumentChanged` fires once per unique new instrument across
///    the whole batch (regardless of how many legs reference it).
///
/// The per-row pattern is already covered by
/// `CoreFinancialGraphRollbackTests.transactionCreateRollsBackOnLegFailure`
/// and `TransactionHookUpdateDeleteTests`; this file pins the bulk path.
@Suite("GRDBTransactionRepository.createMany — atomicity + hook fan-out")
@MainActor
struct GRDBCreateManyTests {

  @MainActor
  final class HookCapture {
    var changed: [(recordType: String, id: UUID)] = []
    var deleted: [(recordType: String, id: UUID)] = []
    var instruments: [Instrument] = []
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

  private func makeInstrumentHook(
    _ capture: HookCapture
  ) -> @Sendable (Instrument) -> Void {
    { instrument in
      Task { @MainActor in
        capture.instruments.append(instrument)
      }
    }
  }

  private func drainHookHops() async throws {
    try await Task.sleep(for: .milliseconds(50))
  }

  // MARK: - Atomicity

  @Test("createMany rolls back every header + leg if any leg insert fails")
  func createManyRollsBackOnLegFailure() async throws {
    let database = try ProfileDatabase.openInMemory()
    let txnRepo = GRDBTransactionRepository(
      database: database,
      defaultInstrument: .AUD,
      conversionService: FixedConversionService())
    let accountId = UUID()
    let stub = Account(id: accountId, name: "Cash", type: .bank, instrument: .AUD)
    try await database.write { database in
      try AccountRow(domain: stub).insert(database)
    }

    // Trigger fires on any leg insert. The first transaction's first leg
    // will trip it — the entire batch (including the headers of every
    // subsequent transaction in the input array) must roll back.
    try await database.write { database in
      try database.execute(
        sql: """
          CREATE TRIGGER fail_create_many_leg
          BEFORE INSERT ON transaction_leg
          BEGIN
              SELECT RAISE(ABORT, 'forced failure for rollback test');
          END;
          """)
    }

    let inputs = (0..<3).map { index in
      Transaction(
        date: Date(),
        payee: "Payee \(index)",
        legs: [
          TransactionLeg(
            accountId: accountId, instrument: .AUD,
            quantity: Decimal(-(index + 1) * 10), type: .expense)
        ])
    }
    do {
      _ = try await txnRepo.createMany(inputs)
      Issue.record("createMany should have thrown but did not")
    } catch {
      // Expected.
    }

    let txnRows = try await database.read { database in
      try TransactionRow.fetchAll(database)
    }
    let legRows = try await database.read { database in
      try TransactionLegRow.fetchAll(database)
    }
    #expect(txnRows.isEmpty)
    #expect(legRows.isEmpty)
  }

  // MARK: - Hook fan-out

  @Test("createMany fan-out: 1 hook per txn + 1 per leg + 1 per unique instrument")
  func createManyHookFanOut() async throws {
    let database = try ProfileDatabase.openInMemory()
    let capture = HookCapture()
    let txnRepo = GRDBTransactionRepository(
      database: database,
      defaultInstrument: .AUD,
      conversionService: FixedConversionService(),
      onRecordChanged: makeChangedHook(capture),
      onRecordDeleted: makeDeletedHook(capture),
      onInstrumentChanged: makeInstrumentHook(capture))
    let accountId = UUID()
    let stub = Account(id: accountId, name: "Cash", type: .bank, instrument: .AUD)
    try await database.write { database in
      try AccountRow(domain: stub).insert(database)
    }

    // Three transactions. The middle two reference a shared non-fiat
    // instrument (BTC); the others are fiat. Expected hook fan-out:
    //   - 3 TransactionRow change emits (one per header)
    //   - 4 TransactionLegRow change emits (1 + 1 + 2)
    //   - 1 onInstrumentChanged for BTC (shared between legs in txn 2 + txn 3)
    let btc = Instrument.crypto(
      chainId: 1, contractAddress: nil, symbol: "BTC", name: "Bitcoin", decimals: 8)
    let inputs: [Transaction] = [
      Transaction(
        date: Date(), payee: "Coffee",
        legs: [
          TransactionLeg(
            accountId: accountId, instrument: .AUD, quantity: -5, type: .expense)
        ]),
      Transaction(
        date: Date(), payee: "BTC buy",
        legs: [
          TransactionLeg(
            accountId: accountId, instrument: btc, quantity: 1, type: .income)
        ]),
      Transaction(
        date: Date(), payee: "BTC swap",
        legs: [
          TransactionLeg(
            accountId: accountId, instrument: btc, quantity: -1, type: .transfer),
          TransactionLeg(
            accountId: accountId, instrument: .AUD, quantity: 100, type: .transfer),
        ]),
    ]

    _ = try await txnRepo.createMany(inputs)
    try await drainHookHops()

    let txnChanges = capture.changed.filter { $0.recordType == TransactionRow.recordType }
    #expect(txnChanges.map(\.id) == inputs.map(\.id))
    let legChanges = capture.changed.filter { $0.recordType == TransactionLegRow.recordType }
    let expectedLegIds = inputs.flatMap { $0.legs.map(\.id) }
    #expect(Set(legChanges.map(\.id)) == Set(expectedLegIds))
    #expect(legChanges.count == expectedLegIds.count)
    #expect(capture.deleted.isEmpty)
    // Exactly one instrument-change emit for BTC across the whole batch
    // even though two separate transactions reference it.
    #expect(capture.instruments.count == 1)
    #expect(capture.instruments.first?.id == btc.id)
  }
}
