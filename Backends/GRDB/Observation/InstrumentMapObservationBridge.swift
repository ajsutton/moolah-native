// Backends/GRDB/Observation/InstrumentMapObservationBridge.swift

import Foundation
import GRDB

/// Bridges the async instrument-map resolution into a synchronous
/// `ValueObservation` pipeline. Shared by every GRDB repository whose
/// observation projection needs the resolved instrument map (account,
/// earmark, transaction, investment daily balances) — one canonical
/// definition rather than a per-repository copy.
///
/// **Why resolve before constructing the observation.** The canonical
/// instrument registry lives on a *separate* (profile-index) database, so
/// its lookup table cannot be joined into the per-profile
/// `ValueObservation`: GRDB's `tracking(regions:fetch:)` closure is
/// synchronous and cannot `await` a cross-database read. The map must
/// therefore be resolved *before* the observation is constructed. The
/// returned outer `AsyncStream`'s worker task is the async setup point:
/// it `await`s `resolver.instrumentMap()`, then `build`s the inner
/// retrying stream with the resolved map captured, and forwards every
/// emission.
///
/// **Resolver failure.** A resolver error surfaces via the shared
/// `errorChannel` (matching the observation error contract) and ends the
/// stream — but only if the consumer is still alive. A cancelled
/// subscription's transient resolver error must not permanently finish
/// the single-shot channel for a later re-subscriber. Note that
/// `errorChannel` is single-shot per repository instance: once a resolver
/// error is surfaced, that channel is permanently finished, and any
/// subsequent observation subscription on the same repository instance
/// will produce an empty stream with no further error notification.
/// Callers that need to re-subscribe after a resolver failure must obtain
/// a fresh repository instance (or accept silent empty streams).
///
/// **Metadata re-resolution.** The map is a snapshot taken once at
/// subscription start. An instrument-metadata edit does not live-refresh
/// an already-open observation; re-resolution requires cancelling the
/// prior subscription and re-subscribing. Cross-database
/// instrument-metadata live-refresh via the shared registry's change
/// stream is a follow-up.
///
/// **Cancellation.** Mirrors the inner-bridge discipline exactly: the
/// outer stream's `onTermination` cancels the worker task; the worker
/// checks `Task.isCancelled` after the resolver `await`, breaks out of
/// the inner `for await` on cancellation, and finishes the continuation,
/// which tears the inner retrying stream down via its own
/// `onTermination`.
///
/// - Parameters:
///   - resolver: Resolves the per-profile-id → `Instrument` map from the
///     shared registry.
///   - errorChannel: Where a non-recoverable resolver error surfaces.
///     The same channel the repository's `observeErrors()` exposes.
///   - database: The writer the inner observation runs against, passed
///     through to `build` so call sites construct the inner stream
///     without recapturing the repository.
///   - build: Constructs the inner retrying observation stream with the
///     resolved map. Receives the same `errorChannel` and `database`
///     it should hand to `toRetryingAsyncStream(...)`.
func resolvedInstrumentMapStream<Value: Sendable>(
  resolver: any InstrumentMapResolving,
  errorChannel: ObservationErrorChannel,
  database: any DatabaseWriter,
  build:
    @escaping @Sendable (
      _ instruments: [String: Instrument],
      _ errorChannel: ObservationErrorChannel,
      _ database: any DatabaseWriter
    ) -> AsyncStream<Value>
) -> AsyncStream<Value> {
  AsyncStream { continuation in
    let task = Task {
      let instruments: [String: Instrument]
      do {
        instruments = try await resolver.instrumentMap()
      } catch {
        // Only surface to the shared (single-shot) errorChannel if the
        // consumer is still alive — a cancelled subscription's transient
        // resolver error must not permanently finish the channel for a
        // later re-subscriber.
        if !Task.isCancelled {
          await errorChannel.surfaceAndFinish(error)
        }
        continuation.finish()
        return
      }
      guard !Task.isCancelled else {
        continuation.finish()
        return
      }
      let inner = build(instruments, errorChannel, database)
      for await value in inner {
        if Task.isCancelled { break }
        continuation.yield(value)
      }
      continuation.finish()
    }
    continuation.onTermination = { _ in task.cancel() }
  }
}
