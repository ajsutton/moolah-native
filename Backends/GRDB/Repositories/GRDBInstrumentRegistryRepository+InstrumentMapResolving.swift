// Backends/GRDB/Repositories/GRDBInstrumentRegistryRepository+InstrumentMapResolving.swift

import GRDB

extension GRDBInstrumentRegistryRepository: InstrumentMapResolving {
  /// Stored rows first, ambient ISO fiat supplemented after — preserving
  /// the ordering callers will see post-cutover so no read path changes
  /// behaviour when it switches from per-profile to shared resolution.
  func instrumentMap() async throws -> [String: Instrument] {
    try await database.read { database in
      try InstrumentRow.fetchInstrumentMap(database: database)
    }
  }
}
