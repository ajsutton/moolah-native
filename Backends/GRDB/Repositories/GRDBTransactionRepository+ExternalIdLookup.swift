// Backends/GRDB/Repositories/GRDBTransactionRepository+ExternalIdLookup.swift

import Foundation
import GRDB

/// Wallet-importer dedup primitives. Both methods read against the
/// partial unique index `idx_transaction_leg_external_id` defined in the
/// crypto-wallet-fields migration, so even a million-row leg table
/// resolves the lookup in O(log n).
extension GRDBTransactionRepository {
  func legs(matchingExternalId externalId: String) async throws -> [TransactionLeg] {
    // Resolve the instrument map before the per-profile snapshot — the
    // canonical registry is a separate database. See
    // `GRDBTransactionRepository.instrumentResolver`.
    let instruments = try await instrumentResolver.instrumentMap()
    return try await database.read { database in
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

  /// Set-scoped sweep used by `CrossDeviceLegDeduper`: returns every
  /// `Transaction` that has at least one leg whose `external_id` is in
  /// `externalIds`, with all of that transaction's legs loaded so the
  /// deduper can pick a canonical winner per `(accountId, externalId)`
  /// group and route losers through `delete(id:)`.
  ///
  /// The leg-side `IN` filter rides the partial unique index
  /// `leg_dedup_by_account_external`. Per-transaction leg fetch reuses
  /// the same `fetchLegs` helper as `fetchAll(filter:)`. Empty input
  /// short-circuits — `IN ()` is a syntax error and a full table scan
  /// would silently waste work.
  func transactions(touchingExternalIds externalIds: Set<String>) async throws
    -> [Transaction]
  {
    guard !externalIds.isEmpty else { return [] }
    // Resolve the instrument map before the per-profile snapshot — the
    // canonical registry is a separate database. See
    // `GRDBTransactionRepository.instrumentResolver`.
    let instruments = try await instrumentResolver.instrumentMap()
    return try await database.read { database in
      let matchingTxnIds =
        try TransactionLegRow
        .select(TransactionLegRow.Columns.transactionId, as: UUID.self)
        .filter(externalIds.contains(TransactionLegRow.Columns.externalId))
        .distinct()
        .fetchAll(database)
      guard !matchingTxnIds.isEmpty else { return [] }
      let txnIdSet = Set(matchingTxnIds)
      let txnRows =
        try TransactionRow
        .filter(txnIdSet.contains(TransactionRow.Columns.id))
        .fetchAll(database)
      let legsByTxnId = try Self.fetchLegs(
        database: database,
        transactionIds: txnRows.map(\.id),
        instruments: instruments)
      return try txnRows.map { row in
        try row.toDomain(legs: legsByTxnId[row.id] ?? [])
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

  func distinctLegInstrumentIds() async throws -> Set<String> {
    try await database.read { database in
      let rows = try String.fetchAll(
        database, sql: "SELECT DISTINCT instrument_id FROM transaction_leg")
      return Set(rows)
    }
  }
}
