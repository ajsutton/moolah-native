// Backends/GRDB/Repositories/GRDBInvestmentRepository+Observation.swift

import Foundation
import GRDB

// Reactive observation surface for `InvestmentRepository`. Split out of
// the main class file to keep `GRDBInvestmentRepository.swift` under
// SwiftLint's `file_length` warning threshold and to mirror the established
// `+Observation.swift` companion-file pattern (account, earmark, category,
// transaction, import-rule).
//
// `observeValues(accountId:page:pageSize:)` mirrors the projection of
// `fetchValues(accountId:page:pageSize:)`. `observeDailyBalances(accountId:)`
// mirrors the projection of `fetchDailyBalances(accountId:)`. Both
// observation methods capture their parameters into the GRDB tracking
// closure — changing `accountId`, `page`, or `pageSize` requires
// cancelling the prior subscription and starting a new one.
//
// `observeErrors()` exposes the shared `ObservationErrorChannel.stream`
// declared on the repo instance (see `GRDBInvestmentRepository.swift`).
//
// Error handling lives entirely in `ValueObservation+RetryingAsyncStream.swift`:
// programmer bugs trip an `assertionFailure` and surface via the channel;
// transient I/O restarts the observation with backoff (1 s, 5 s, 30 s,
// capped at 5 retries); budget exhaustion surfaces the most recent
// error. See `guides/DATABASE_CODE_GUIDE.md` §2 convention 5.
extension GRDBInvestmentRepository {

  /// Streams `InvestmentValuePage` snapshots whenever `investment_value`
  /// changes. Initial value is the current DB state. `removeDuplicates()`
  /// (applied inside the retry helper) coalesces re-fetches that produce
  /// the same page (e.g. a write to a row outside the page window that
  /// didn't change `hasMore`). The supplied `accountId`, `page`, and
  /// `pageSize` are captured into the tracking closure — changing any of
  /// them requires cancelling the prior subscription and starting a new
  /// one with the new values.
  func observeValues(
    accountId: UUID, page: Int, pageSize: Int
  ) -> AsyncStream<InvestmentValuePage> {
    ValueObservation
      // Explicit-region form via `InvestmentValueRow.observableRegion`
      // so the sync-bookkeeping `encoded_system_fields` writes do not
      // re-fire this observation. See issue #865.
      .tracking(
        regions: [InvestmentValueRow.observableRegion],
        fetch: { [accountId, page, pageSize] database in
          let rows =
            try InvestmentValueRow
            .filter(InvestmentValueRow.Columns.accountId == accountId)
            .order(InvestmentValueRow.Columns.date.desc)
            .limit(pageSize + 1, offset: page * pageSize)
            .fetchAll(database)
          let hasMore = rows.count > pageSize
          let values = rows.prefix(pageSize).map { $0.toDomain() }
          return InvestmentValuePage(values: Array(values), hasMore: hasMore)
        }
      )
      .toRetryingAsyncStream(
        in: database,
        errorChannel: errorChannel,
        repoMethod: "GRDBInvestmentRepository.observeValues")
  }

  /// Streams `[AccountDailyBalance]` snapshots whenever the underlying
  /// `transaction`, `transaction_leg`, or `instrument` tables change.
  /// Mirrors the projection of `fetchDailyBalances(accountId:)`: one
  /// entry per (calendar-day, instrument) tuple, sorted by date
  /// ascending. Captures `accountId` into the tracking closure.
  func observeDailyBalances(
    accountId: UUID
  ) -> AsyncStream<[AccountDailyBalance]> {
    let defaultInstrument = self.defaultInstrument
    return
      ValueObservation
      // Explicit-region form so the sync-bookkeeping
      // `encoded_system_fields` writes on the tables `DailyBalanceCompute`
      // reads (transaction, transaction_leg, instrument) do not re-fire
      // this observation. See issue #865.
      .tracking(
        regions: [
          InstrumentRow.observableRegion,
          TransactionRow.observableRegion,
          TransactionLegRow.observableRegion,
        ],
        fetch: { [accountId, defaultInstrument] database in
          try DailyBalanceCompute.compute(
            database: database,
            accountId: accountId,
            defaultInstrument: defaultInstrument)
        }
      )
      .toRetryingAsyncStream(
        in: database,
        errorChannel: errorChannel,
        repoMethod: "GRDBInvestmentRepository.observeDailyBalances")
  }

  /// Tick stream over all `investment_value` rows. Used by
  /// `AccountStore` to refresh its `investmentValueCache` and recompute
  /// `convertedInvestmentTotal` whenever any investment value changes,
  /// without requiring a per-account subscription. `Void`-emitting so
  /// `removeDuplicates()` can't be applied (every emission is
  /// indistinguishable); we therefore use the explicit-region
  /// `tracking(regions:fetch:)` form so a fresh-install profile with
  /// zero `investment_value` rows still emits when the first row lands.
  /// Mirrors the rate-tick stream's region-pre-declaration idiom — see
  /// `RateCacheTickStream.swift` for the rationale.
  func observeAllValues() -> AsyncStream<Void> {
    // Region-pre-declared form via `InvestmentValueRow.observableRegion`
    // — narrower than `Table("investment_value")` because it excludes
    // the sync-bookkeeping `encoded_system_fields` column. `Void`-valued
    // streams can't use `removeDuplicates`, so the region trim is the
    // only defence against system-fields writes producing spurious
    // ticks. See issue #865.
    let observation = ValueObservation.tracking(
      regions: [InvestmentValueRow.observableRegion],
      fetch: { _ in () }
    )
    let database = self.database
    return makeRetryingAsyncStream(
      makeAttempt: { errorSink in
        observation
          .values(in: database)
          .toAsyncStream(onError: errorSink)
      },
      policy: RetryingAsyncStreamPolicy(
        errorChannel: errorChannel,
        repoMethod: "GRDBInvestmentRepository.observeAllValues",
        maxFailures: 5,
        backoffs: [.seconds(1), .seconds(5), .seconds(30)]))
  }

  /// Companion error stream — see protocol doc on `observeErrors()` and
  /// the channel's docstring for the surface-then-finish contract.
  func observeErrors() -> AsyncStream<any Error> {
    errorChannel.stream
  }
}
