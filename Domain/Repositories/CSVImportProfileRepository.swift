import Foundation

protocol CSVImportProfileRepository: Sendable {
  func fetchAll() async throws -> [CSVImportProfile]
  /// Reactive observation surface. Emits the full profile list once
  /// immediately with the current DB contents (ordered by `created_at`),
  /// then re-emits whenever the underlying `csv_import_profile` table
  /// changes. Backed by GRDB's `ValueObservation` with
  /// `removeDuplicates()` so identical snapshots are coalesced.
  ///
  /// Errors are surfaced out-of-band on `observeErrors()` — the value
  /// stream itself is non-throwing so views can subscribe with
  /// `for await` and never crash on a transient SQLite condition.
  func observeAll() -> AsyncStream<[CSVImportProfile]>
  /// Companion error stream for `observeAll()`. A healthy observation
  /// stays quiet here for its lifetime; a programmer-bug or
  /// non-recoverable I/O error from the underlying observation is
  /// yielded once and then the stream completes. Stores typically
  /// surface this to a banner / log path.
  func observeErrors() -> AsyncStream<any Error>
  func create(_ profile: CSVImportProfile) async throws -> CSVImportProfile
  func update(_ profile: CSVImportProfile) async throws -> CSVImportProfile
  func delete(id: UUID) async throws
}
