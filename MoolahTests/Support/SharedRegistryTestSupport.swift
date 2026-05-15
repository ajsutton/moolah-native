// MoolahTests/Support/SharedRegistryTestSupport.swift

import GRDB

@testable import Moolah

/// Builds an isolated, in-memory shared instrument registry for tests
/// and previews — a `GRDBInstrumentRegistryRepository` backed by a fresh
/// `ProfileIndexDatabase.openInMemory()` queue.
///
/// This is the test-side mirror of how production wires the
/// shared registry (`MoolahApp.makeSharedInstrumentRegistry` over
/// `ProfileContainerManager.profileIndexDatabase`). It replaces the
/// retired per-profile `PerProfileInstrumentMapResolver` /
/// `PerProfileInstrumentRegistrar` shims at every repository / sync /
/// rollback test seam: those shims read and wrote the per-profile
/// `instrument` table that the `v10_drop_shared_instrument_legacy`
/// migration removes. Resolution semantics are unchanged for the
/// suites that use it — none seeds the shared registry, so reads fall
/// through to the same `Instrument.fiat(code:)` path the per-profile
/// shim produced on an empty per-profile table, while the per-profile
/// rows those suites insert for FK / cascade structure stay untouched.
enum SharedRegistryTestSupport {
  /// A fresh shared registry over its own in-memory profile-index DB.
  /// Each call returns an independent registry/database pair, matching
  /// the per-test isolation the `PerProfile*` shims provided.
  static func makeSharedRegistry() throws -> GRDBInstrumentRegistryRepository {
    GRDBInstrumentRegistryRepository(
      database: try ProfileIndexDatabase.openInMemory())
  }
}
