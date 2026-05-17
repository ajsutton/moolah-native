// Backends/GRDB/Repositories/GRDBTransactionRepository+Replace.swift

import Foundation
import GRDB

extension GRDBTransactionRepository {
  /// Atomic delete-then-create. Deletes every `deletingIds` transaction
  /// (legs first, then the header — the schema has no FK CASCADE on
  /// `transaction_leg.transaction_id`, so legs are removed explicitly,
  /// mirroring `delete(id:)`) and inserts every `creating` transaction,
  /// all inside one `database.write { … }`. On any throw the whole
  /// write rolls back, so a transfer collapse / split can never leave
  /// half the rows on disk. Non-fiat leg instruments are registered
  /// before the write for the same cross-database reason as `create`.
  /// Post-commit hooks fan out per deleted and per created row, matching
  /// `delete(id:)` / `createMany(_:)`.
  func replace(
    deletingIds: [UUID],
    creating: [Transaction]
  ) async throws -> [Transaction] {
    try await Self.registerNonFiatLegInstruments(
      creating.flatMap(\.legs), using: instrumentRegistrar)

    let outcome = try await database.write { database -> ReplaceOutcome in
      var deletedLegIds: [UUID] = []
      for id in deletingIds {
        let legIds =
          try TransactionLegRow
          .filter(TransactionLegRow.Columns.transactionId == id)
          .fetchAll(database)
          .map(\.id)
        _ =
          try TransactionLegRow
          .filter(TransactionLegRow.Columns.transactionId == id)
          .deleteAll(database)
        let didDelete = try TransactionRow.deleteOne(database, id: id)
        guard didDelete else {
          throw BackendError.notFound("Transaction not found")
        }
        deletedLegIds.append(contentsOf: legIds)
      }
      let createdLegIds = try Self.performCreateMany(
        database: database, transactions: creating)
      return ReplaceOutcome(
        deletedLegIds: deletedLegIds, createdLegIds: createdLegIds)
    }

    // Post-commit fan-out order: all deleted headers, then all deleted
    // legs, then all created headers, then all created legs. The sync
    // engine processes each emit independently by `(recordType, id)`,
    // so this grouped order is observationally equivalent to the
    // per-transaction header-then-legs order `delete(id:)` uses.
    for id in deletingIds {
      onRecordDeleted(TransactionRow.recordType, id)
    }
    for legId in outcome.deletedLegIds {
      onRecordDeleted(TransactionLegRow.recordType, legId)
    }
    for transaction in creating {
      onRecordChanged(TransactionRow.recordType, transaction.id)
    }
    for legId in outcome.createdLegIds {
      onRecordChanged(TransactionLegRow.recordType, legId)
    }
    return creating
  }
}

/// Per-write tally of the leg ids touched by `replace`, carried out of
/// the `database.write` closure so the post-commit sync hooks fan out
/// after the transaction commits (a hook fired inside the write would
/// observe rows that a later rollback discards).
private struct ReplaceOutcome {
  let deletedLegIds: [UUID]
  let createdLegIds: [UUID]
}
