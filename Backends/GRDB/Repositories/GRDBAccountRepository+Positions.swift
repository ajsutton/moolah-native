// Backends/GRDB/Repositories/GRDBAccountRepository+Positions.swift

import Foundation
import GRDB

// Position-computation helpers split out of `GRDBAccountRepository` so
// the main class body stays under SwiftLint's `type_body_length`
// threshold. The SQL groups non-scheduled, account-bound legs by
// `(account_id, instrument_id)`; rows resolve their full `Instrument`
// value via the supplied lookup table (with ambient ISO fiat as a
// fallback). Mirrors the SwiftData-era
// `CloudKitAccountRepository.computePositions(from:instruments:)`.
extension GRDBAccountRepository {
  /// Forwards to the shared `InstrumentRow.fetchInstrumentMap` so every
  /// repository observes the same stored-then-ambient ordering.
  static func fetchInstrumentMap(database: Database) throws -> [String: Instrument] {
    try InstrumentRow.fetchInstrumentMap(database: database)
  }

  /// Computes per-account, per-instrument position sums from the
  /// `transaction_leg` table, excluding scheduled (recurring) parents
  /// and account-less legs (e.g. category-only legs on transfers).
  /// Returns `[accountId: [Position]]` with positions sorted by
  /// instrument id and zero-quantity entries dropped — matching
  /// `Position.computePositions(from:)`'s contract.
  static func computePositions(
    database: Database,
    instruments: [String: Instrument]
  ) throws -> [UUID: [Position]] {
    let sql = """
      SELECT leg.account_id     AS account_id,
             leg.instrument_id  AS instrument_id,
             SUM(leg.quantity)  AS quantity
      FROM transaction_leg AS leg
      JOIN "transaction" AS txn ON leg.transaction_id = txn.id
      WHERE txn.recur_period IS NULL
        AND leg.account_id IS NOT NULL
      GROUP BY leg.account_id, leg.instrument_id
      HAVING SUM(leg.quantity) <> 0
      """
    let rows = try Row.fetchAll(database, sql: sql)
    var result: [UUID: [Position]] = [:]
    for row in rows {
      guard let accountId: UUID = row["account_id"] else { continue }
      guard let instrumentId: String = row["instrument_id"] else { continue }
      guard let storage: Int64 = row["quantity"] else { continue }
      let instrument = instruments[instrumentId] ?? Instrument.fiat(code: instrumentId)
      let amount = InstrumentAmount(storageValue: storage, instrument: instrument)
      result[accountId, default: []].append(
        Position(instrument: instrument, quantity: amount.quantity))
    }
    for (accountId, positions) in result {
      result[accountId] = positions.sorted { $0.instrument.id < $1.instrument.id }
    }
    return result
  }

  /// Single-account variant of `computePositions(database:instruments:)`.
  /// Used by `update(_:)` so the returned `Account` carries fresh
  /// positions without re-summing every other account's legs.
  static func computePositions(
    database: Database,
    instruments: [String: Instrument],
    accountId: UUID
  ) throws -> [Position] {
    let sql = """
      SELECT leg.instrument_id AS instrument_id,
             SUM(leg.quantity) AS quantity
      FROM transaction_leg AS leg
      JOIN "transaction" AS txn ON leg.transaction_id = txn.id
      WHERE txn.recur_period IS NULL
        AND leg.account_id = ?
      GROUP BY leg.instrument_id
      HAVING SUM(leg.quantity) <> 0
      """
    let rows = try Row.fetchAll(database, sql: sql, arguments: [accountId])
    var positions: [Position] = []
    for row in rows {
      guard let instrumentId: String = row["instrument_id"] else { continue }
      guard let storage: Int64 = row["quantity"] else { continue }
      let instrument = instruments[instrumentId] ?? Instrument.fiat(code: instrumentId)
      let amount = InstrumentAmount(storageValue: storage, instrument: instrument)
      positions.append(Position(instrument: instrument, quantity: amount.quantity))
    }
    return positions.sorted { $0.instrument.id < $1.instrument.id }
  }
}
