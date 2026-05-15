// Backends/GRDB/Repositories/PerProfileInstrumentMapResolver.swift

import GRDB

/// `InstrumentMapResolving` over a per-profile database. Transitional:
/// preview / test / apply callers that don't have the shared registry
/// keep reading the per-profile `instrument` table until the
/// `v10_drop_shared_instrument_legacy` migration removes it. Production
/// CloudKit sessions inject the shared `GRDBInstrumentRegistryRepository`
/// instead (see ProfileSession+CloudKitBackendBuild).
struct PerProfileInstrumentMapResolver: InstrumentMapResolving {
  let database: any DatabaseReader

  func instrumentMap() async throws -> [String: Instrument] {
    try await database.read { database in
      try InstrumentRow.fetchInstrumentMap(database: database)
    }
  }
}
