// Backends/GRDB/Observation/RateCacheTickStream.swift

import Foundation
import GRDB

/// Builds the `Void`-emitting "rate-tick" stream consumed by
/// `InstrumentConversionService.observeRates()`. Watches all three
/// live price-cache tables — `exchange_rate` (FX), `stock_price`, and
/// `crypto_price` — and yields one `Void` per change set after the
/// initial tick.
///
/// Lives next to the other observation primitives so both
/// `FiatConversionService` and `FullConversionService` can share the
/// same plumbing without duplicating the categorisation/retry logic
/// that already lives in `makeRetryingAsyncStream(...)`.
///
/// **Why `tracking(regions:fetch:)` and not `tracking { db in ... }`.**
/// On a fresh-install profile every cache table starts empty. A
/// `SELECT 1 FROM exchange_rate LIMIT 1`-style fetch would not register
/// the `exchange_rate` region until after the first row is read, so
/// the very first sync write that populates the table would not emit.
/// The explicit-region form pre-declares the region union before any
/// rows exist. See `guides/DATABASE_CODE_GUIDE.md` §2 convention 1.
///
/// **Why no `removeDuplicates()`.** `Void == Void` is always true, so
/// chaining `removeDuplicates()` would suppress every emission after
/// the first. The retry driver `makeRetryingAsyncStream` is used
/// directly (rather than the `Equatable`-bounded
/// `ValueObservation.toRetryingAsyncStream` extension) precisely so
/// this stream can opt out of the de-duplication step while keeping
/// the categorisation, logging, and backoff branches of the shared
/// retry policy.
func makeRateCacheTickStream(
  database: any DatabaseWriter,
  errorChannel: ObservationErrorChannel,
  repoMethod: String
) -> AsyncStream<Void> {
  let observation = ValueObservation.tracking(
    regions: [
      Table("exchange_rate"),
      Table("stock_price"),
      Table("crypto_price"),
    ],
    fetch: { _ in () }
  )
  return makeRetryingAsyncStream(
    makeAttempt: { errorSink in
      observation
        .values(in: database)
        .toAsyncStream(onError: errorSink)
    },
    policy: RetryingAsyncStreamPolicy(
      errorChannel: errorChannel,
      repoMethod: repoMethod,
      maxFailures: 5,
      backoffs: [.seconds(1), .seconds(5), .seconds(30)]))
}
