// Domain/Repositories/InstrumentMapResolving.swift

/// Resolves the full instrument lookup table (`id → Instrument`,
/// including ambient ISO fiat) from the canonical instrument registry.
///
/// Replaces the per-profile `InstrumentRow.fetchInstrumentMap(database:)`
/// read. The map is reference/lookup data with immutable identity, so it
/// is fetched once per repository operation outside the per-profile
/// transaction snapshot rather than joined into it.
protocol InstrumentMapResolving: Sendable {
  func instrumentMap() async throws -> [String: Instrument]
}
