import Foundation
import OSLog

private let transactionLogger = Logger(
  subsystem: "com.moolah.app", category: "Transaction.withRunningBalances")

struct Transaction: Codable, Sendable, Identifiable, Hashable {
  let id: UUID
  var date: Date
  var payee: String?
  var notes: String?
  var recurPeriod: RecurPeriod?
  var recurEvery: Int?
  var legs: [TransactionLeg]
  var importOrigin: ImportOrigin?

  var isScheduled: Bool {
    recurPeriod != nil
  }

  var isRecurring: Bool {
    guard let period = recurPeriod else { return false }
    return period != .once
  }

  init(
    id: UUID = UUID(),
    date: Date,
    payee: String? = nil,
    notes: String? = nil,
    recurPeriod: RecurPeriod? = nil,
    recurEvery: Int? = nil,
    legs: [TransactionLeg],
    importOrigin: ImportOrigin? = nil
  ) {
    self.id = id
    self.date = date
    self.payee = payee
    self.notes = notes
    self.recurPeriod = recurPeriod
    self.recurEvery = recurEvery
    self.legs = legs
    self.importOrigin = importOrigin
  }

  // MARK: - Convenience Accessors

  var accountIds: Set<UUID> { Set(legs.compactMap(\.accountId)) }
  var isTransfer: Bool {
    let accounts = Set(legs.filter { $0.type == .transfer }.compactMap(\.accountId))
    let instruments = Set(legs.filter { $0.type == .transfer }.map(\.instrument))
    return accounts.count > 1 || instruments.count > 1
  }

  // MARK: - Structure Queries (simple/transfer shape)

  /// Whether this transaction has simple structure: a single leg, or exactly
  /// two legs forming a basic transfer (amounts negate, same type, second leg
  /// has no category/earmark, and legs reference different accounts).
  var isSimple: Bool {
    if legs.count <= 1 { return true }
    guard legs.count == 2 else { return false }
    let first = legs[0]
    let second = legs[1]
    return first.quantity == -second.quantity
      && first.type == second.type
      && second.categoryId == nil
      && second.earmarkId == nil
      && first.accountId != second.accountId
  }

  /// Whether this transaction is a simple cross-currency transfer: exactly two
  /// transfer legs with different accounts and different instruments. Unlike
  /// `isSimple`, this does not require amounts to negate (since exchange rates
  /// mean the quantities will differ).
  var isSimpleCrossCurrencyTransfer: Bool {
    guard legs.count == 2 else { return false }
    let first = legs[0]
    let second = legs[1]
    guard first.type == .transfer && second.type == .transfer else { return false }
    guard let firstAcct = first.accountId, let secondAcct = second.accountId,
      firstAcct != secondAcct
    else { return false }
    guard second.categoryId == nil && second.earmarkId == nil else { return false }
    return first.instrument != second.instrument
  }

}

struct TransactionFilter: Sendable, Equatable {
  var accountId: UUID?
  var earmarkId: UUID?
  var scheduled: ScheduledFilter
  var dateRange: ClosedRange<Date>?
  var categoryIds: Set<UUID>
  var payee: String?

  init(
    accountId: UUID? = nil,
    earmarkId: UUID? = nil,
    scheduled: ScheduledFilter = .all,
    dateRange: ClosedRange<Date>? = nil,
    categoryIds: Set<UUID> = [],
    payee: String? = nil
  ) {
    self.accountId = accountId
    self.earmarkId = earmarkId
    self.scheduled = scheduled
    self.dateRange = dateRange
    self.categoryIds = categoryIds
    self.payee = payee
  }
}

extension TransactionFilter {
  var hasActiveFilters: Bool {
    accountId != nil || earmarkId != nil || scheduled != .all
      || dateRange != nil || !categoryIds.isEmpty || payee != nil
  }
}

/// A page of transactions returned from the repository, including the account
/// balance prior to the earliest transaction in this page.
struct TransactionPage: Sendable {
  let transactions: [Transaction]
  /// The instrument in which the running balance column should be displayed for
  /// this fetch. For account-scoped fetches this is the account's own instrument;
  /// for global fetches it's the profile instrument. Always populated — even when
  /// `priorBalance` is `nil` due to a conversion failure.
  let targetInstrument: Instrument
  /// Account balance before the oldest transaction in `transactions`. `nil` when
  /// the repository could not compute it (e.g. exchange-rate lookup failed). The
  /// transactions themselves are still returned so the list renders; running
  /// balances are just unavailable.
  let priorBalance: InstrumentAmount?
  let totalCount: Int?

  /// Computes the running balance after each transaction, converting each leg
  /// to the target instrument. Transactions must be ordered newest-first (as
  /// returned by the repository). `priorBalance` is the account balance
  /// before the oldest transaction in the list.
  ///
  /// All legs are converted at `Date()` — *not* `transaction.date`. The
  /// running balance has to tie out to the live account balance (which is
  /// also computed at "now"); using historic per-date rates would make
  /// the balance column drift from the account header. Treat the display
  /// amount on each row as "what this transaction is worth at today's
  /// rate," not "what it was worth when it happened." See #530.
  ///
  /// The algorithm is single-pass:
  ///   1. Walk every leg once to enumerate the unique source instruments
  ///      that need a rate.
  ///   2. Fetch one rate per instrument from `conversionService` in a single
  ///      `TaskGroup` batch — the parent only suspends once for the whole
  ///      batch, regardless of how many instruments are involved.
  ///   3. Apply rates per leg synchronously. For all-target-instrument data
  ///      (the common scheduled / native-account case) phase 1 yields an
  ///      empty set, phase 2 is a no-op, and phase 3 has zero suspension
  ///      points.
  ///
  /// Graceful degradation: if a rate fetch fails for instrument X, every
  /// transaction with an X leg is returned with `displayAmount == nil` and
  /// `balance == nil`, and the running balance is broken from that row
  /// onward. The first such failure is exposed as `firstConversionError`
  /// so callers can surface a retry path. Per Rule 11 of
  /// `guides/INSTRUMENT_CONVERSION_GUIDE.md`, each failure is logged via
  /// `os.Logger` at `warning` level — once per failed instrument, not once
  /// per affected leg.
  ///
  /// `@MainActor`-annotated so calls from a `@MainActor` caller (the
  /// `TransactionStore`) take the same-isolation fast path. For all-target
  /// data (the upcoming-card / scheduled cases) the `await` resolves
  /// without suspending and the function is effectively a synchronous
  /// call. Without this, hopping off main and back is dominated on cold
  /// launch by waiting for the main actor to drain its queue of other
  /// stores' bg-fetch domain conversions — measured ~600 ms even when the
  /// loop body itself is < 5 ms. See #530.
  @MainActor
  static func withRunningBalances(
    transactions: [Transaction],
    priorBalance: InstrumentAmount?,
    accountId: UUID?,
    earmarkId: UUID? = nil,
    targetInstrument: Instrument,
    conversionService: InstrumentConversionService
  ) async -> RunningBalanceResult {
    let prefetched = await prefetchRates(
      for: transactions,
      targetInstrument: targetInstrument,
      conversionService: conversionService)
    return accumulateRunningBalances(
      transactions: transactions,
      priorBalance: priorBalance,
      accountId: accountId,
      earmarkId: earmarkId,
      targetInstrument: targetInstrument,
      prefetched: prefetched)
  }

  /// Outcome of a single per-instrument rate prefetch. Sendable so it can
  /// flow out of a `TaskGroup` child task.
  private enum RatePrefetch: Sendable {
    case rate(Decimal)
    case failure(String)
  }

  /// Fetched rates and per-instrument failures, keyed by source instrument.
  /// Returned by `prefetchRates(...)` and consumed by
  /// `accumulateRunningBalances(...)`.
  private struct PrefetchedRates {
    let rates: [Instrument: Decimal]
    let failures: [Instrument: String]
  }

  @MainActor
  private static func prefetchRates(
    for transactions: [Transaction],
    targetInstrument: Instrument,
    conversionService: InstrumentConversionService
  ) async -> PrefetchedRates {
    var sources: Set<Instrument> = []
    for transaction in transactions {
      for leg in transaction.legs where leg.instrument != targetInstrument {
        sources.insert(leg.instrument)
      }
    }
    if sources.isEmpty { return PrefetchedRates(rates: [:], failures: [:]) }

    let asOf = Date()
    return await withTaskGroup(of: (Instrument, RatePrefetch).self) { group in
      for instrument in sources {
        group.addTask {
          do {
            let rate = try await conversionService.convert(
              Decimal(1), from: instrument, to: targetInstrument, on: asOf)
            return (instrument, .rate(rate))
          } catch {
            transactionLogger.warning(
              """
              Failed to fetch rate \(instrument.id, privacy: .public) → \
              \(targetInstrument.id, privacy: .public): \
              \(error.localizedDescription, privacy: .public). Every \
              transaction with a \(instrument.id, privacy: .public) leg will \
              have an unavailable running balance until the rate source recovers.
              """)
            return (instrument, .failure(error.localizedDescription))
          }
        }
      }
      var rates: [Instrument: Decimal] = [:]
      var failures: [Instrument: String] = [:]
      for await (instrument, outcome) in group {
        switch outcome {
        case .rate(let rate): rates[instrument] = rate
        case .failure(let description): failures[instrument] = description
        }
      }
      return PrefetchedRates(rates: rates, failures: failures)
    }
  }

  private static func accumulateRunningBalances(
    transactions: [Transaction],
    priorBalance: InstrumentAmount?,
    accountId: UUID?,
    earmarkId: UUID? = nil,
    targetInstrument: Instrument,
    prefetched: PrefetchedRates
  ) -> RunningBalanceResult {
    var balance: InstrumentAmount? = priorBalance
    var rows: [TransactionWithBalance] = []
    rows.reserveCapacity(transactions.count)
    var firstConversionError: RunningBalanceConversionError?

    for transaction in transactions.reversed() {
      let outcome = convert(
        legsOf: transaction,
        targetInstrument: targetInstrument,
        prefetched: prefetched)
      switch outcome {
      case .success(let convertedLegs):
        let displayAmount = computeDisplayAmount(
          for: transaction,
          convertedLegs: convertedLegs,
          accountId: accountId,
          earmarkId: earmarkId,
          targetInstrument: targetInstrument)
        if let displayAmount, var runningBalance = balance {
          runningBalance += displayAmount
          balance = runningBalance
        }
        rows.append(
          TransactionWithBalance(
            transaction: transaction,
            convertedLegs: convertedLegs,
            displayAmounts: Transaction.computeDisplayAmounts(
              for: transaction, accountId: accountId, earmarkId: earmarkId),
            displayAmount: displayAmount,
            balance: balance))
      case .failure(let underlyingDescription):
        if firstConversionError == nil {
          firstConversionError = RunningBalanceConversionError(
            transactionId: transaction.id,
            targetInstrumentId: targetInstrument.id,
            underlyingDescription: underlyingDescription)
        }
        balance = nil
        rows.append(
          TransactionWithBalance(
            transaction: transaction,
            convertedLegs: [],
            displayAmounts: [],
            displayAmount: nil,
            balance: nil))
      }
    }

    rows.reverse()
    return RunningBalanceResult(rows: rows, firstConversionError: firstConversionError)
  }

  private enum LegConversion {
    case success([ConvertedTransactionLeg])
    case failure(String)
  }

  /// Apply prefetched rates to each leg of `transaction`. Returns
  /// `.failure` on the first leg whose source instrument has no rate
  /// (failed prefetch) so the caller can mark the row unavailable.
  private static func convert(
    legsOf transaction: Transaction,
    targetInstrument: Instrument,
    prefetched: PrefetchedRates
  ) -> LegConversion {
    var legs: [ConvertedTransactionLeg] = []
    legs.reserveCapacity(transaction.legs.count)
    for leg in transaction.legs {
      if leg.instrument == targetInstrument {
        legs.append(ConvertedTransactionLeg(leg: leg, convertedAmount: leg.amount))
      } else if let rate = prefetched.rates[leg.instrument] {
        let amount = InstrumentAmount(
          quantity: leg.amount.quantity * rate, instrument: targetInstrument)
        legs.append(ConvertedTransactionLeg(leg: leg, convertedAmount: amount))
      } else {
        let description =
          prefetched.failures[leg.instrument]
          ?? "No rate available for \(leg.instrument.id)"
        return .failure(description)
      }
    }
    return .success(legs)
  }

  /// Picks the amount to display on a row: per-account sum when viewing an
  /// account, per-earmark sum when viewing an earmark, otherwise transfers
  /// show the negative-quantity leg and non-transfers sum all legs.
  private static func computeDisplayAmount(
    for transaction: Transaction,
    convertedLegs: [ConvertedTransactionLeg],
    accountId: UUID?,
    earmarkId: UUID?,
    targetInstrument: Instrument
  ) -> InstrumentAmount? {
    let zero = InstrumentAmount.zero(instrument: targetInstrument)
    if let accountId {
      return
        convertedLegs
        .filter { $0.leg.accountId == accountId }
        .reduce(zero) { $0 + $1.convertedAmount }
    }
    if let earmarkId {
      return
        convertedLegs
        .filter { $0.leg.earmarkId == earmarkId }
        .reduce(zero) { $0 + $1.convertedAmount }
    }
    // Scheduled view (no account context): transfers show the negative
    // leg; everything else sums all legs.
    let isTransfer = transaction.legs.contains { $0.type == .transfer }
    if isTransfer {
      let negativeLeg = convertedLegs.first { $0.leg.quantity < 0 }
      return negativeLeg?.convertedAmount ?? zero
    }
    return convertedLegs.reduce(zero) { $0 + $1.convertedAmount }
  }
}
