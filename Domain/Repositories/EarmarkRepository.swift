import Foundation

protocol EarmarkRepository: Sendable {
  func fetchAll() async throws -> [Earmark]
  /// Reactive observation surface. Emits the full earmark list once
  /// immediately with the current DB contents, then re-emits whenever
  /// the underlying tables change (`earmark`, `instrument`,
  /// `transaction_leg`, joined `transaction`). Backed by GRDB's
  /// `ValueObservation` with `removeDuplicates()` so identical
  /// snapshots are coalesced.
  ///
  /// Errors are surfaced out-of-band on `observeErrors()` — the value
  /// stream itself is non-throwing so views can subscribe with
  /// `for await` and never crash on a transient SQLite condition.
  func observeAll() -> AsyncStream<[Earmark]>
  /// Reactive observation of a single earmark's budget. Emits the
  /// current budget items once on subscription, then re-emits whenever
  /// `earmark_budget_item` rows for the supplied `earmarkId` change.
  /// Mirrors the `fetchBudget(earmarkId:)` projection (instrument
  /// resolution included).
  func observeBudget(earmarkId: UUID) -> AsyncStream<[EarmarkBudgetItem]>
  /// Companion error stream for `observeAll()` and `observeBudget`. A
  /// healthy observation stays quiet here for its lifetime; a
  /// programmer-bug or non-recoverable I/O error from the underlying
  /// observation is yielded once and then the stream completes. Stores
  /// typically surface this to a banner / log path.
  func observeErrors() -> AsyncStream<any Error>
  func create(_ earmark: Earmark) async throws -> Earmark
  func update(_ earmark: Earmark) async throws -> Earmark
  func fetchBudget(earmarkId: UUID) async throws -> [EarmarkBudgetItem]
  func setBudget(earmarkId: UUID, categoryId: UUID, amount: InstrumentAmount) async throws
}
