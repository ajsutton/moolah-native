import Foundation

protocol ImportRuleRepository: Sendable {
  func fetchAll() async throws -> [ImportRule]
  /// Reactive observation surface. Emits the full rule list once
  /// immediately with the current DB contents (ordered by `position`),
  /// then re-emits whenever the underlying `import_rule` table changes.
  /// Backed by GRDB's `ValueObservation` with `removeDuplicates()` so
  /// identical snapshots are coalesced.
  ///
  /// Errors are surfaced out-of-band on `observeErrors()` — the value
  /// stream itself is non-throwing so views can subscribe with
  /// `for await` and never crash on a transient SQLite condition.
  func observeAll() -> AsyncStream<[ImportRule]>
  /// Companion error stream for `observeAll()`. A healthy observation
  /// stays quiet here for its lifetime; a programmer-bug or
  /// non-recoverable I/O error from the underlying observation is
  /// yielded once and then the stream completes. Stores typically
  /// surface this to a banner / log path.
  func observeErrors() -> AsyncStream<any Error>
  func create(_ rule: ImportRule) async throws -> ImportRule
  func update(_ rule: ImportRule) async throws -> ImportRule
  func delete(id: UUID) async throws

  /// Atomically renumber `position` across every existing rule so that the
  /// passed ids take the positions 0…n-1 in order. Throws if `orderedIds`
  /// does not exactly match the set of stored rule ids.
  func reorder(_ orderedIds: [UUID]) async throws
}
