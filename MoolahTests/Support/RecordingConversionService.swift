import Foundation
import os

@testable import Moolah

/// One recorded call to `RecordingConversionService.convert(...)`.
/// Top-level so tests can construct, compare, and pattern-match values
/// without needing to fully qualify them through the service type.
struct RecordingConversionServiceCall: Sendable, Equatable {
  let quantity: Decimal
  let from: Instrument
  let to: Instrument
  let date: Date
}

/// Test conversion service that records every `convert(_:from:to:on:)` call
/// so tests can assert which conversions the caller actually performed.
/// Returns `quantity` unchanged (1:1 fallback) on every call — this double
/// is for *call-site* assertions, not rate behaviour.
///
/// Also records every `invalidateCache(for:)` call so tests for
/// `CryptoTokenStore.setStatus(_:for:)` (and other paths that want to
/// invalidate conversion-derived caches) can assert which instruments
/// the caller actually invalidated.
///
/// Backed by `OSAllocatedUnfairLock` so it is async-safe and `Sendable` and
/// usable from any isolation domain (same lock-around-mutable-state pattern
/// as `FailureLog` in `ThrowingCountingConversionService.swift`).
final class RecordingConversionService: InstrumentConversionService, Sendable {
  private let recorded = OSAllocatedUnfairLock<[RecordingConversionServiceCall]>(
    initialState: [])
  private let invalidations = OSAllocatedUnfairLock<[Instrument]>(initialState: [])

  var calls: [RecordingConversionServiceCall] { recorded.withLock { $0 } }
  /// Every instrument passed to `invalidateCache(for:)`, in order.
  /// Multiple invocations are preserved — there is no dedup at this
  /// layer because cache invalidation is intentionally idempotent and
  /// callers may legitimately invalidate the same instrument twice.
  var invalidatedInstruments: [Instrument] { invalidations.withLock { $0 } }

  func convert(
    _ quantity: Decimal, from: Instrument, to: Instrument, on date: Date
  ) async throws -> Decimal {
    recorded.withLock {
      $0.append(
        RecordingConversionServiceCall(
          quantity: quantity, from: from, to: to, date: date))
    }
    return quantity
  }

  func convertAmount(
    _ amount: InstrumentAmount, to instrument: Instrument, on date: Date
  ) async throws -> InstrumentAmount {
    let value = try await convert(
      amount.quantity, from: amount.instrument, to: instrument, on: date)
    return InstrumentAmount(quantity: value, instrument: instrument)
  }

  func convertResult(
    _ amount: InstrumentAmount, to instrument: Instrument, on date: Date
  ) async throws -> ConversionResult {
    let converted = try await convertAmount(amount, to: instrument, on: date)
    return .value(converted)
  }

  func invalidateCache(for instrument: Instrument) async {
    invalidations.withLock { $0.append(instrument) }
  }
}
