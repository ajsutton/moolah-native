// Backends/GRDB/Repositories/PerProfileInstrumentRegistrar.swift

import GRDB

/// `InstrumentRegistering` over a per-profile database. Transitional:
/// the mirror of `PerProfileInstrumentMapResolver` for the write side.
/// Preview / test / apply callers don't have the shared registry, so
/// `registerResolvable` writes the same per-profile `instrument` row the
/// old create-path placeholder insert did — keeping create→read behaviour
/// byte-for-byte preserved until the `v10_drop_shared_instrument_legacy`
/// migration removes the per-profile `instrument` table. Production
/// CloudKit sessions inject the shared `GRDBInstrumentRegistryRepository`
/// instead (see ProfileSession+CloudKitBackendBuild).
///
/// Semantics replicate the removed `ensureInstrumentReadable` /
/// `ensureNonFiatInstrumentRow` exactly: fiat is ambient and skipped; a
/// non-fiat instrument is inserted only when no row with that id already
/// exists (idempotent). The insert is `InstrumentRow(domain:).insert` —
/// no provider-mapping columns, matching the old placeholder write.
struct PerProfileInstrumentRegistrar: InstrumentRegistering {
  let database: any DatabaseWriter

  func registerResolvable(_ instrument: Instrument) async throws {
    guard instrument.kind != .fiatCurrency else { return }
    try await database.write { database in
      guard
        try InstrumentRow
          .filter(InstrumentRow.Columns.id == instrument.id)
          .fetchOne(database) == nil
      else { return }
      try InstrumentRow(domain: instrument).insert(database)
    }
  }
}
