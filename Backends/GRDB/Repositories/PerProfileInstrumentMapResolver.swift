// Backends/GRDB/Repositories/PerProfileInstrumentMapResolver.swift

import GRDB

/// `InstrumentMapResolving` over a per-profile database. Transitional:
/// preview / test / apply callers that don't have the shared registry
/// keep reading the per-profile `instrument` table until the
/// `v10_drop_shared_instrument_legacy` migration removes it. Production
/// CloudKit sessions inject the shared `GRDBInstrumentRegistryRepository`
/// instead (see ProfileSession+CloudKitBackendBuild).
///
/// Once `v10_drop_shared_instrument_legacy` drops the per-profile
/// `instrument` table, any remaining caller of this resolver will receive
/// an `SQLITE_ERROR` (no such table) from `InstrumentRow.fetchInstrumentMap`.
/// That error is classified as a programmer bug and terminates the
/// observation silently in release builds. All callers MUST therefore
/// switch to `GRDBInstrumentRegistryRepository` at or before that migration —
/// before the per-profile table disappears.
struct PerProfileInstrumentMapResolver: InstrumentMapResolving {
  let database: any DatabaseReader

  func instrumentMap() async throws -> [String: Instrument] {
    try await database.read { database in
      try InstrumentRow.fetchInstrumentMap(database: database)
    }
  }
}
