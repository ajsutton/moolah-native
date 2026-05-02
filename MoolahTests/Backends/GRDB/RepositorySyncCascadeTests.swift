// MoolahTests/Backends/GRDB/RepositorySyncCascadeTests.swift

import Foundation
import GRDB
import Testing

@testable import Moolah

@Suite("Repository sync delete cascades")
struct RepositorySyncCascadeTests {
  /// `applyRemoteChangesSync(saved: [], deleted: [accountId])` must
  /// also remove `investment_value` rows for that account and null
  /// `transaction_leg.account_id` references — replacing what the v4
  /// FK CASCADE / SET NULL did before v5 dropped the FKs.
  @Test
  func accountSyncDeleteCascadesToInvestmentValuesAndNullsLegs() async throws {
    let database = try ProfileDatabase.openInMemory()
    let accountRepo = GRDBAccountRepository(database: database)
    let accountId = UUID()
    let legId = UUID()
    let txId = UUID()
    let ivId = UUID()

    try await database.write { database in
      try database.execute(
        sql: """
          INSERT INTO instrument (id, record_name, kind, name, decimals)
            VALUES ('USD', 'instrument-USD', 'fiatCurrency', 'US Dollar', 2);
          INSERT INTO account (id, record_name, name, type, instrument_id, position, is_hidden)
            VALUES (?, 'account-1', 'Checking', 'bank', 'USD', 0, 0);
          INSERT INTO "transaction" (id, record_name, date)
            VALUES (?, 'tx-1', '2026-01-01');
          INSERT INTO transaction_leg (id, record_name, transaction_id, account_id, instrument_id,
                                       quantity, type, sort_order)
            VALUES (?, 'leg-1', ?, ?, 'USD', 100, 'expense', 0);
          INSERT INTO investment_value (id, record_name, account_id, date, value, instrument_id)
            VALUES (?, 'iv-1', ?, '2026-01-01', 100000, 'USD');
          """,
        arguments: [accountId, txId, legId, txId, accountId, ivId, accountId])
    }

    // Hard-delete via sync path.
    try accountRepo.applyRemoteChangesSync(saved: [], deleted: [accountId])

    try await database.read { database in
      let ivCount =
        try Int.fetchOne(
          database,
          sql: "SELECT COUNT(*) FROM investment_value WHERE account_id = ?",
          arguments: [accountId]) ?? -1
      #expect(ivCount == 0)

      let nulledLegs =
        try Int.fetchOne(
          database,
          sql: "SELECT COUNT(*) FROM transaction_leg WHERE id = ? AND account_id IS NULL",
          arguments: [legId]) ?? -1
      #expect(nulledLegs == 1)
    }
  }

  @Test
  func transactionDomainDeleteRemovesLegs() async throws {
    let database = try ProfileDatabase.openInMemory()
    let txRepo = GRDBTransactionRepository(
      database: database,
      defaultInstrument: .AUD,
      conversionService: FixedConversionService())
    let txId = UUID()
    let leg1Id = UUID()
    let leg2Id = UUID()

    try await database.write { database in
      try database.execute(
        sql: """
          INSERT INTO instrument (id, record_name, kind, name, decimals)
            VALUES ('USD', 'instrument-USD', 'fiatCurrency', 'US Dollar', 2);
          INSERT INTO "transaction" (id, record_name, date)
            VALUES (?, 'tx-1', '2026-01-01');
          INSERT INTO transaction_leg (id, record_name, transaction_id, instrument_id,
                                       quantity, type, sort_order)
            VALUES (?, 'leg-1', ?, 'USD', 100, 'expense', 0);
          INSERT INTO transaction_leg (id, record_name, transaction_id, instrument_id,
                                       quantity, type, sort_order)
            VALUES (?, 'leg-2', ?, 'USD', -100, 'transfer', 1);
          """,
        arguments: [txId, leg1Id, txId, leg2Id, txId])
    }

    try await txRepo.delete(id: txId)

    try await database.read { database in
      let legCount =
        try Int.fetchOne(
          database,
          sql: "SELECT COUNT(*) FROM transaction_leg WHERE transaction_id = ?",
          arguments: [txId]) ?? -1
      #expect(legCount == 0)
    }
  }

  @Test
  func transactionSyncDeleteRemovesLegs() async throws {
    let database = try ProfileDatabase.openInMemory()
    let txRepo = GRDBTransactionRepository(
      database: database,
      defaultInstrument: .AUD,
      conversionService: FixedConversionService())
    let txId = UUID()
    let legId = UUID()

    try await database.write { database in
      try database.execute(
        sql: """
          INSERT INTO instrument (id, record_name, kind, name, decimals)
            VALUES ('USD', 'instrument-USD', 'fiatCurrency', 'US Dollar', 2);
          INSERT INTO "transaction" (id, record_name, date)
            VALUES (?, 'tx-1', '2026-01-01');
          INSERT INTO transaction_leg (id, record_name, transaction_id, instrument_id,
                                       quantity, type, sort_order)
            VALUES (?, 'leg-1', ?, 'USD', 100, 'expense', 0);
          """,
        arguments: [txId, legId, txId])
    }

    try txRepo.applyRemoteChangesSync(saved: [], deleted: [txId])

    try await database.read { database in
      let legCount =
        try Int.fetchOne(
          database,
          sql: "SELECT COUNT(*) FROM transaction_leg WHERE transaction_id = ?",
          arguments: [txId]) ?? -1
      #expect(legCount == 0)
    }
  }
}
