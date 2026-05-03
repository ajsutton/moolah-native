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
/// Backed by `OSAllocatedUnfairLock` so it is async-safe and `Sendable` and
/// usable from any isolation domain (same lock-around-mutable-state pattern
/// as `FailureLog` in `ThrowingCountingConversionService.swift`).
final class RecordingConversionService: InstrumentConversionService, Sendable {
  private let recorded = OSAllocatedUnfairLock<[RecordingConversionServiceCall]>(
    initialState: [])

  var calls: [RecordingConversionServiceCall] { recorded.withLock { $0 } }

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
}
