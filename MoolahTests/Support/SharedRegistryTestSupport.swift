// MoolahTests/Support/SharedRegistryTestSupport.swift

import GRDB

@testable import Moolah

/// Builds an isolated, in-memory shared instrument registry for tests
/// and previews — a `GRDBInstrumentRegistryRepository` backed by a fresh
/// `ProfileIndexDatabase.openInMemory()` queue.
///
/// This is the test-side mirror of how production wires the
/// shared registry (`MoolahApp.makeSharedInstrumentRegistry` over
/// `ProfileContainerManager.profileIndexDatabase`). It is the instrument
/// resolver / registrar seam for every repository / sync / rollback
/// test. Suites that use it do not seed the shared registry, so reads
/// fall through to the `Instrument.fiat(code:)` path; the per-profile
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
