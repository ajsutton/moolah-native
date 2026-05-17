import Foundation

/// Persistence surface for user-asserted "these two transactions are NOT
/// a transfer" decisions. Detection consults `pairs(touching:)` to skip
/// any candidate the user has already dismissed.
protocol DismissedTransferPairRepository: Sendable {
  func fetchAll() async throws -> [DismissedTransferPair]
  /// Reactive observation surface. Emits the full dismissed-pair list
  /// once immediately with the current DB contents, then re-emits
  /// whenever the underlying `dismissed_transfer_pair` table changes.
  /// Backed by GRDB's `ValueObservation` with `removeDuplicates()` so
  /// identical snapshots are coalesced.
  ///
  /// A device that dismisses a pair uploads it via CKSyncEngine; a peer
  /// device receives that record and applies it locally, which fires
  /// this stream. Detection state therefore converges across devices
  /// without an explicit refresh — the same cross-device-convergence
  /// contract `CategoryRepository.observeAll()` provides.
  ///
  /// Errors are surfaced out-of-band on `observeErrors()` — the value
  /// stream itself is non-throwing so callers can subscribe with
  /// `for await` and never crash on a transient SQLite condition.
  func observeAll() -> AsyncStream<[DismissedTransferPair]>
  /// Companion error stream for `observeAll()`. A healthy observation
  /// stays quiet here for its lifetime; a programmer-bug or
  /// non-recoverable I/O error from the underlying observation is
  /// yielded once and then the stream completes.
  func observeErrors() -> AsyncStream<any Error>
  func create(_ pair: DismissedTransferPair) async throws -> DismissedTransferPair
  func delete(id: UUID) async throws
  /// Every dismissed pair whose unordered transaction-id set includes
  /// `transactionId`. The detection-time hot path.
  func pairs(touching transactionId: UUID) async throws -> [DismissedTransferPair]
}
