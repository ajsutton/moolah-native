import Foundation
import os

@testable import Moolah

/// Counts conversion calls and lets the caller decide whether to throw on
/// each one. The closure receives the call index so a caller can fail only
/// specific rows (e.g. "throw on row 0 and 2"). The counter is guarded by
/// `OSAllocatedUnfairLock` (async-safe, `Sendable`) so the service can be
/// used from any isolation domain.
///
/// Distinct from the `actor CountingConversionService` in
/// `CountingConversionService.swift`: that one always succeeds and is
/// keyed by source-instrument id; this one is per-call programmable so
/// tests can inject failures at specific row indices.
final class ThrowingCountingConversionService: InstrumentConversionService {
  private let counter = OSAllocatedUnfairLock(initialState: 0)
  private let outcome: @Sendable (Int) -> Result<Decimal, any Error>

  init(outcome: @escaping @Sendable (Int) -> Result<Decimal, any Error>) {
    self.outcome = outcome
  }

  var calls: Int { counter.withLock { $0 } }

  func convert(
    _ quantity: Decimal, from: Instrument, to: Instrument, on date: Date
  ) async throws -> Decimal {
    let index = counter.withLock { count -> Int in
      let current = count
      count += 1
      return current
    }
    switch outcome(index) {
    case .success(let value):
      return value
    case .failure(let error):
      throw error
    }
  }

  func convertAmount(
    _ amount: InstrumentAmount, to instrument: Instrument, on date: Date
  ) async throws -> InstrumentAmount {
    let value = try await convert(
      amount.quantity, from: amount.instrument, to: instrument, on: date)
    return InstrumentAmount(quantity: value, instrument: instrument)
  }
}

/// Async-safe collector for per-row failure-callback fan-out observed by
/// analysis-repository tests. Backed by `OSAllocatedUnfairLock` so the
/// `@Sendable` closure passed to a handler can append from whichever
/// isolation domain the helper resumes on without a data-race waiver.
final class FailureLog: Sendable {
  private let entries = OSAllocatedUnfairLock<[Int]>(initialState: [])

  func append(_ value: Int) {
    entries.withLock { $0.append(value) }
  }

  func snapshot() -> [Int] {
    entries.withLock { $0 }
  }
}
