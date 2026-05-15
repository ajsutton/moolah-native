// Domain/Repositories/InstrumentRegistering.swift

/// Registers a non-fiat instrument so it becomes resolvable by the
/// corresponding `InstrumentMapResolving`. Fiat is ambient (synthesised
/// from `Locale.Currency.isoCurrencies`) and is never stored. Idempotent:
/// a redundant registration of an already-known instrument is a no-op
/// merge that never downgrades a richer stored row.
///
/// The create / update paths await this seam *before* the per-profile
/// `database.write` that inserts the txn / leg / account rows, so a read
/// issued immediately after the method returns resolves the instrument.
/// Production injects the shared profile-index registry (where its
/// resolver reads); preview / test / apply inject a transitional
/// per-profile registrar that writes the same per-profile `instrument`
/// row the old placeholder insert did (see `PerProfileInstrumentMapResolver`).
protocol InstrumentRegistering: Sendable {
  func registerResolvable(_ instrument: Instrument) async throws
}
