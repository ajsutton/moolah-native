import Foundation

/// Repository surface that `SessionManager` needs from the app-scoped
/// profile-index database. Defined in `Domain/` so the App layer can
/// hold a reference without importing `Backends/GRDB/`.
///
/// Production conformance is `GRDBProfileIndexRepository` (registered
/// in `MoolahApp+Setup.swift`). The protocol lists only the methods the
/// gate / bump-on-write paths use; broader operations (`fetchAll`,
/// `upsert`, `delete`, system-fields, etc.) stay on the concrete type
/// — they are part of the sync wiring, not the App-layer contract.
protocol ProfileIndexRepository: Sendable {
  /// Async single-profile fetch. Used by `SessionManager.session(for:)`
  /// to re-read the profile-index row immediately before the
  /// compatibility check, so a stale in-memory snapshot can't bypass
  /// the gate.
  func profile(forID id: UUID) async throws -> Profile?

  /// Async upsert; used by `SessionManager` for the bump-on-write
  /// (raising `dataFormatVersion` to `DataFormatVersion.current` after
  /// a successful `setUp()`).
  func upsert(_ profile: Profile) async throws

  /// Async fetch-all; used by the mid-session observer to walk every
  /// profile and find any whose version exceeds the build's.
  func fetchAll() async throws -> [Profile]
}
