// Backends/GRDB/Repositories/GRDBEarmarkRepository+Positions.swift

import Foundation
import GRDB

// Position-computation helpers for `GRDBEarmarkRepository`. Split out of
// the main file so the class body stays under SwiftLint's
// `type_body_length` threshold. Three lists per earmark map the
// SwiftData-era `CloudKitEarmarkRepository.computeEarmarkPositions`:
// every leg contributes to `positions`; income/openingBalance/trade
// legs contribute to `savedPositions`; expense/transfer legs
// contribute to `spentPositions` (sign-flipped).
extension GRDBEarmarkRepository {
  /// Three position lists computed for a single earmark — one per flow
  /// direction (current holdings, saved-in, spent-out). Mirrors
  /// `CloudKitEarmarkRepository.EarmarkPositionLists`.
  struct EarmarkPositionLists {
    let positions: [Position]
    let savedPositions: [Position]
    let spentPositions: [Position]

    static let empty = EarmarkPositionLists(
      positions: [], savedPositions: [], spentPositions: [])
  }

  /// Builds `[String: Instrument]` from the `instrument` table, then
  /// supplements with ambient fiat for ISO codes that don't appear as
  /// rows. Mirrors `GRDBAccountRepository.fetchInstrumentMap`.
  static func fetchInstrumentMap(database: Database) throws -> [String: Instrument] {
    let rows = try InstrumentRow.fetchAll(database)
    var map: [String: Instrument] = [:]
    for row in rows {
      map[row.id] = row.toDomain()
    }
    for code in Locale.Currency.isoCurrencies.map(\.identifier) where map[code] == nil {
      map[code] = Instrument.fiat(code: code)
    }
    return map
  }

  /// Computes per-earmark, per-instrument position sums from the
  /// `transaction_leg` table, excluding scheduled (recurring) parents.
  /// Returns `[earmarkId: EarmarkPositionLists]`. Mirrors
  /// `CloudKitEarmarkRepository.computeEarmarkPositions`.
  static func computeEarmarkPositions(
    database: Database,
    instruments: [String: Instrument]
  ) throws -> [UUID: EarmarkPositionLists] {
    let sql = """
      SELECT leg.earmark_id     AS earmark_id,
             leg.instrument_id  AS instrument_id,
             leg.type           AS type,
             leg.quantity       AS quantity
      FROM transaction_leg AS leg
      JOIN "transaction" AS txn ON leg.transaction_id = txn.id
      WHERE txn.recur_period IS NULL
        AND leg.earmark_id IS NOT NULL
      """
    let rows = try Row.fetchAll(database, sql: sql)

    var positionTotals: [UUID: [Instrument: Decimal]] = [:]
    var savedTotals: [UUID: [Instrument: Decimal]] = [:]
    var spentTotals: [UUID: [Instrument: Decimal]] = [:]

    for row in rows {
      guard let earmarkId: UUID = row["earmark_id"] else { continue }
      guard let instrumentId: String = row["instrument_id"] else { continue }
      guard let typeRaw: String = row["type"] else { continue }
      guard let quantity: Int64 = row["quantity"] else { continue }
      let instrument = instruments[instrumentId] ?? Instrument.fiat(code: instrumentId)
      let amount = InstrumentAmount(storageValue: quantity, instrument: instrument)

      positionTotals[earmarkId, default: [:]][instrument, default: 0] += amount.quantity

      let legType = TransactionType(rawValue: typeRaw) ?? .expense
      switch legType {
      case .income, .openingBalance, .trade:
        savedTotals[earmarkId, default: [:]][instrument, default: 0] += amount.quantity
      case .expense, .transfer:
        spentTotals[earmarkId, default: [:]][instrument, default: 0] += -amount.quantity
      }
    }

    let earmarkIds = Set(positionTotals.keys)
      .union(savedTotals.keys)
      .union(spentTotals.keys)
    var result: [UUID: EarmarkPositionLists] = [:]
    for earmarkId in earmarkIds {
      result[earmarkId] = EarmarkPositionLists(
        positions: makePositions(positionTotals[earmarkId] ?? [:]),
        savedPositions: makePositions(savedTotals[earmarkId] ?? [:]),
        spentPositions: makePositions(spentTotals[earmarkId] ?? [:]))
    }
    return result
  }

  /// Drops zero-quantity entries, sorts by instrument id, and returns
  /// the resulting `[Position]`. Mirrors the inline closure in
  /// `CloudKitEarmarkRepository.computeEarmarkPositions`.
  private static func makePositions(_ totals: [Instrument: Decimal]) -> [Position] {
    totals.compactMap { instrument, quantity -> Position? in
      guard quantity != 0 else { return nil }
      return Position(instrument: instrument, quantity: quantity)
    }
    .sorted { $0.instrument.id < $1.instrument.id }
  }
}
