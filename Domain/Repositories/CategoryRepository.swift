import Foundation

protocol CategoryRepository: Sendable {
  func fetchAll() async throws -> [Category]
  /// Reactive observation surface. Emits the full category list once
  /// immediately with the current DB contents, then re-emits whenever
  /// the underlying `category` table changes. Backed by GRDB's
  /// `ValueObservation` with `removeDuplicates()` so identical
  /// snapshots are coalesced.
  ///
  /// Errors are surfaced out-of-band on `observeErrors()` — the value
  /// stream itself is non-throwing so views can subscribe with
  /// `for await` and never crash on a transient SQLite condition.
  func observeAll() -> AsyncStream<[Category]>
  /// Companion error stream for `observeAll()`. A healthy observation
  /// stays quiet here for its lifetime; a programmer-bug or
  /// non-recoverable I/O error from the underlying observation is
  /// yielded once and then the stream completes. Stores typically
  /// surface this to a banner / log path.
  func observeErrors() -> AsyncStream<any Error>
  func create(_ category: Category) async throws -> Category
  func update(_ category: Category) async throws -> Category
  func delete(id: UUID, withReplacement replacementId: UUID?) async throws
}
