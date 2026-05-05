// Backends/GRDB/Repositories/GRDBTransactionRepository+ExternalIdLookup.swift

import Foundation
import GRDB

/// Wallet-importer dedup primitives. Both methods read against the
/// partial unique index `idx_transaction_leg_external_id` defined in the
/// crypto-wallet-fields migration, so even a million-row leg table
/// resolves the lookup in O(log n).
extension GRDBTransactionRepository {
  func legs(matchingExternalId externalId: String) async throws -> [TransactionLeg] {
    try await database.read { database in
      let instruments = try Self.fetchInstrumentMap(database: database)
      let rows =
        try TransactionLegRow
        .filter(TransactionLegRow.Columns.externalId == externalId)
        .fetchAll(database)
      return try rows.map { row in
        let instrument =
          instruments[row.instrumentId]
          ?? Instrument.fiat(code: row.instrumentId)
        return try row.toDomain(instrument: instrument)
      }
    }
  }

  func legExists(accountId: UUID, externalId: String) async throws -> Bool {
    try await database.read { database in
      try TransactionLegRow
        .filter(TransactionLegRow.Columns.accountId == accountId)
        .filter(TransactionLegRow.Columns.externalId == externalId)
        .fetchCount(database)
        > 0
    }
  }
}
