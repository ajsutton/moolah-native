// Backends/GRDB/Repositories/GRDBTransactionRepository+CreateMany.swift

import Foundation
import GRDB

extension GRDBTransactionRepository {
  // MARK: - Bulk create pipeline

  /// Bundle returned by `performCreateMany`'s write block: every
  /// inserted leg id (flat, input order) and every non-fiat instrument
  /// that `ensureInstrumentReadable` had to auto-insert across the
  /// whole batch (deduped, first-seen wins). Mirrors the per-row
  /// `CreateOutcome` so the post-commit hook fan-out runs the same
  /// way regardless of batch size.
  struct BulkCreateOutcome: Sendable {
    let legIds: [UUID]
    let instruments: [Instrument]
  }

  /// Inserts every transaction header and its legs inside one
  /// `database.write { … }` transaction. On any throw the whole batch
  /// rolls back; the caller in the main file fires `onRecordChanged` /
  /// `onInstrumentChanged` only after the write commits — see
  /// `GRDBTransactionRepository.createMany(_:)`.
  static func performCreateMany(
    database: Database,
    transactions: [Transaction]
  ) throws -> BulkCreateOutcome {
    var legIds: [UUID] = []
    legIds.reserveCapacity(transactions.reduce(0) { $0 + $1.legs.count })
    var insertedInstruments: [Instrument] = []
    var seenInstrumentIds: Set<String> = []

    for transaction in transactions {
      let txnRow = TransactionRow(domain: transaction)
      try txnRow.insert(database)

      for (index, leg) in transaction.legs.enumerated() {
        // `ensureInstrumentReadable` is deduped per-batch — a non-fiat
        // instrument referenced by N legs across N transactions still
        // surfaces exactly once to the shared-registry hook.
        if let inserted = try Self.ensureInstrumentReadable(
          database: database, leg: leg),
          seenInstrumentIds.insert(inserted.id).inserted
        {
          insertedInstruments.append(inserted)
        }
        let legRow = TransactionLegRow(
          id: leg.id,
          domain: leg,
          transactionId: transaction.id,
          sortOrder: index)
        try legRow.insert(database)
        legIds.append(leg.id)
      }
    }
    return BulkCreateOutcome(legIds: legIds, instruments: insertedInstruments)
  }
}
