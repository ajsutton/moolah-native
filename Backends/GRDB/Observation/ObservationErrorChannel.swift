// Backends/GRDB/Observation/ObservationErrorChannel.swift
import Foundation

actor ObservationErrorChannel {
  private var continuation: AsyncStream<any Error>.Continuation?
  /// Broadcast stream of observation errors. Immutable after init and
  /// `AsyncStream` is `Sendable`, so it is safe to read across actor
  /// boundaries without hopping into the actor.
  nonisolated let stream: AsyncStream<any Error>

  init() {
    var localContinuation: AsyncStream<any Error>.Continuation?
    self.stream = AsyncStream { continuation in
      localContinuation = continuation
    }
    self.continuation = localContinuation
  }

  /// Single-call API: yields the error then finishes both streams.
  /// Combining the two operations into one actor method guarantees
  /// ordering — there is no race window where `finish()` can win and
  /// drop the in-flight error.
  func surfaceAndFinish(_ error: any Error) {
    continuation?.yield(error)
    continuation?.finish()
    continuation = nil
  }
}
