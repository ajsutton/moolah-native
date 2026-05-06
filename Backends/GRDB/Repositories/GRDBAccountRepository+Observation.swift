// Backends/GRDB/Repositories/GRDBAccountRepository+Observation.swift

import Foundation
import GRDB

// Reactive observation surface for `AccountRepository`. Split out of the
// main class file to keep `GRDBAccountRepository.swift` under SwiftLint's
// `file_length` warning threshold and to mirror the established
// `+Positions.swift` companion-file pattern.
//
// `observeAll()` returns the same domain projection as `fetchAll()`:
// account rows ordered by `position`, each populated with its full
// `Instrument` value and per-instrument `Position` totals computed from
// non-scheduled `transaction_leg` rows.
//
// `observeErrors()` exposes the shared `ObservationErrorChannel.stream`
// declared on the repo instance (see `GRDBAccountRepository.swift`).
// The bridge contracts (single-shot, no retry, surface-then-finish) are
// documented on `AsyncValueObservation.toAsyncStream(onError:)` and on
// `ObservationErrorChannel.surfaceAndFinish(_:)`.
extension GRDBAccountRepository {

  /// Streams `[Account]` snapshots whenever `account`, `instrument`,
  /// `transaction_leg`, or the joined `transaction` table changes.
  /// Initial value is the current DB state. `removeDuplicates()`
  /// coalesces re-fetches that produce the same domain value (e.g. a
  /// no-op write on an unrelated row).
  ///
  /// On observation failure the error is forwarded to the shared
  /// `errorChannel` via `surfaceAndFinish(_:)` — a single actor call
  /// that yields-then-finishes atomically, so there is no two-task race
  /// where `finish()` could run before the in-flight error is delivered.
  /// The value stream then terminates cleanly via the bridge's
  /// `continuation.finish()`.
  func observeAll() -> AsyncStream<[Account]> {
    let channel = self.errorChannel
    return
      ValueObservation
      .tracking { database in
        let instruments = try Self.fetchInstrumentMap(database: database)
        let rows =
          try AccountRow
          .order(AccountRow.Columns.position.asc)
          .fetchAll(database)
        let positionsByAccount = try Self.computePositions(
          database: database, instruments: instruments)
        return try rows.map { row in
          try row.toDomain(
            instruments: instruments,
            positions: positionsByAccount[row.id] ?? [])
        }
      }
      .removeDuplicates()
      .values(in: database)
      .toAsyncStream(onError: { error in
        Task { await channel.surfaceAndFinish(error) }
      })
  }

  /// Companion error stream — see protocol doc on `observeErrors()` and
  /// the channel's docstring for the surface-then-finish contract.
  func observeErrors() -> AsyncStream<any Error> {
    errorChannel.stream
  }
}
