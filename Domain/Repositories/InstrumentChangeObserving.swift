// Domain/Repositories/InstrumentChangeObserving.swift

/// Narrow change-notification seam over the canonical instrument
/// registry, exposed to per-profile stores so an open list can
/// live-refresh when shared instrument metadata changes. The minimal
/// surface a store needs (no read/write registry methods), keeping the
/// `Features → Domain` dependency narrow and free of any backend type.
/// The payload is a signal, not a diff — consumers re-fetch after a
/// tick.
protocol InstrumentChangeObserving: Sendable {
  /// Creates a fresh change-observation stream for a single consumer.
  /// `@MainActor`-isolated because the implementation registers the
  /// continuation in a `@MainActor`-confined dictionary synchronously —
  /// a `Task { @MainActor in … }` hop would let a mutation fired
  /// immediately after subscription miss the event.
  @MainActor
  func observeChanges() -> AsyncStream<Void>
}
