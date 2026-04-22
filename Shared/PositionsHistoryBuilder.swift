import Foundation
import OSLog

/// Builds the `(value, cost)` time series the chart in `PositionsView` plots.
///
/// **Cost basis line is exact.** Cost only changes on transaction events, so
/// we walk transactions chronologically through `CostBasisEngine` once and
/// emit the resulting `(quantity, remainingCost)` snapshot for *every* day
/// in the visible range. Days between events carry forward the prior
/// snapshot — no interpolation, no approximation.
///
/// **Value line is queried daily.** For each day `d` in
/// `[startOfRange ... today]` and each instrument with a non-zero holding
/// on `d`, we ask the conversion service for `convert(qty, instrument,
/// hostCurrency, on: d)`. The conversion service is backed by
/// `StockPriceCache` / `ExchangeRateCache` / `CryptoPriceCache`, so the
/// only network calls are for prices not yet in cache; subsequent loads of
/// the same chart (and overlapping ranges across users of the same
/// instrument) are O(1) per day. There is no sampling, no smoothing — the
/// chart shows the actual portfolio value on every day.
///
/// Aggregate points are emitted only when *every* contributing
/// per-instrument conversion succeeds on that date — partial sums are
/// forbidden by `guides/INSTRUMENT_CONVERSION_GUIDE.md` Rule 11. A
/// per-instrument series whose conversion fails for some days simply
/// omits those days; sibling instruments still chart.
///
/// Cancellation: callers should run this from a `.task { ... }` so it is
/// torn down when the view goes away. We check `Task.isCancelled` once per
/// day to bail out quickly on dismissal.
struct PositionsHistoryBuilder: Sendable {
  let conversionService: any InstrumentConversionService
  private let logger = Logger(
    subsystem: "com.moolah.app", category: "PositionsHistoryBuilder")

  func build(
    transactions: [Transaction],
    accountId: UUID,
    hostCurrency: Instrument,
    range: PositionsTimeRange,
    now: Date = Date()
  ) async -> HistoricalValueSeries {
    let calendar = Calendar(identifier: .gregorian)
    let sortedTxns =
      transactions
      .filter { $0.legs.contains(where: { $0.accountId == accountId }) }
      .sorted { $0.date < $1.date }

    guard let firstTxnDate = sortedTxns.first?.date else {
      return HistoricalValueSeries(
        hostCurrency: hostCurrency, total: [], perInstrument: [:])
    }

    let cutoff = range.cutoff(from: now) ?? firstTxnDate
    let start = calendar.startOfDay(for: max(cutoff, firstTxnDate))
    let endDay = calendar.startOfDay(for: now)
    guard endDay >= start else {
      return HistoricalValueSeries(
        hostCurrency: hostCurrency, total: [], perInstrument: [:])
    }

    let context = BuildContext(
      sortedTxns: sortedTxns, accountId: accountId,
      hostCurrency: hostCurrency, calendar: calendar)
    var state = BuildState()
    await preFoldHistory(before: start, context: context, state: &state)

    var day = start
    while day <= endDay {
      if Task.isCancelled { return state.series(hostCurrency: hostCurrency) }
      await applyTransactions(on: day, context: context, state: &state)
      let cancelled = await emitDailyPoints(
        for: day, hostCurrency: hostCurrency, state: &state)
      if cancelled { return state.series(hostCurrency: hostCurrency) }
      guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
      day = next
    }

    return state.series(hostCurrency: hostCurrency)
  }

  /// Pre-fold any transactions strictly before `start` so the snapshot at
  /// `start` already reflects historical buys.
  private func preFoldHistory(
    before start: Date,
    context: BuildContext,
    state: inout BuildState
  ) async {
    while state.txnIndex < context.sortedTxns.count
      && context.calendar.startOfDay(for: context.sortedTxns[state.txnIndex].date) < start
    {
      await apply(
        transaction: context.sortedTxns[state.txnIndex], accountId: context.accountId,
        hostCurrency: context.hostCurrency,
        quantities: &state.quantities, engine: &state.engine
      )
      state.txnIndex += 1
    }
  }

  /// Fold every transaction whose start-of-day is `day` into the running state.
  private func applyTransactions(
    on day: Date,
    context: BuildContext,
    state: inout BuildState
  ) async {
    while state.txnIndex < context.sortedTxns.count
      && context.calendar.startOfDay(for: context.sortedTxns[state.txnIndex].date) == day
    {
      await apply(
        transaction: context.sortedTxns[state.txnIndex], accountId: context.accountId,
        hostCurrency: context.hostCurrency,
        quantities: &state.quantities, engine: &state.engine
      )
      state.txnIndex += 1
    }
  }

  /// Immutable inputs threaded through `build`'s per-day loop.
  private struct BuildContext {
    let sortedTxns: [Transaction]
    let accountId: UUID
    let hostCurrency: Instrument
    let calendar: Calendar
  }

  /// Emit one point per held instrument on `day` and, when every conversion
  /// succeeds, one aggregate point. Returns `true` if cancellation was observed
  /// so the caller can bail.
  private func emitDailyPoints(
    for day: Date,
    hostCurrency: Instrument,
    state: inout BuildState
  ) async -> Bool {
    var aggValue: Decimal = 0
    var aggCost: Decimal = 0
    var aggOK = true
    var anyHeld = false

    // Host-currency legs are excluded from `quantities` in `apply()`, so every
    // instrument here is a non-host investment instrument and always requires
    // a conversion call.
    for (instrument, qty) in state.quantities where qty != 0 {
      if Task.isCancelled { return true }
      anyHeld = true
      let cost = state.engine.openLots(for: instrument)
        .reduce(Decimal(0)) { $0 + $1.remainingCost }
      let value = await convertValue(
        qty: qty, instrument: instrument, hostCurrency: hostCurrency, on: day)
      if let value {
        state.perInstrument[instrument.id, default: []].append(
          HistoricalValueSeries.Point(date: day, value: value, cost: cost))
        aggValue += value
        aggCost += cost
      } else {
        aggOK = false
      }
    }

    if anyHeld && aggOK {
      state.total.append(
        HistoricalValueSeries.Point(date: day, value: aggValue, cost: aggCost))
    }
    return false
  }

  /// Convert `qty` of `instrument` to `hostCurrency` on `day`, logging and
  /// returning `nil` on failure so the caller can mark the day incomplete.
  private func convertValue(
    qty: Decimal, instrument: Instrument, hostCurrency: Instrument, on day: Date
  ) async -> Decimal? {
    do {
      return try await conversionService.convert(
        qty, from: instrument, to: hostCurrency, on: day)
    } catch {
      logger.warning(
        "history conversion failed for \(instrument.id, privacy: .public) on \(day, privacy: .public): \(error.localizedDescription, privacy: .public)"
      )
      return nil
    }
  }

  /// Mutable running state threaded through `build`'s per-day loop.
  private struct BuildState {
    var quantities: [Instrument: Decimal] = [:]
    var engine = CostBasisEngine()
    var txnIndex = 0
    var perInstrument: [String: [HistoricalValueSeries.Point]] = [:]
    var total: [HistoricalValueSeries.Point] = []

    func series(hostCurrency: Instrument) -> HistoricalValueSeries {
      HistoricalValueSeries(
        hostCurrency: hostCurrency, total: total, perInstrument: perInstrument)
    }
  }

  /// Fold one transaction into the running quantity dict and FIFO engine.
  ///
  /// Quantities update directly from the account's signed leg quantities
  /// (so an ETH→BTC swap subtracts ETH and adds BTC). Cost basis updates
  /// via the shared `TradeEventClassifier`, which handles fiat-paired
  /// trades AND crypto-to-crypto swaps — for a swap, ETH gets a sell event
  /// (proceeds = host-currency value of ETH on this date) and BTC gets a
  /// buy event (cost = host-currency value of BTC on this date).
  ///
  /// Host-currency legs (cash outflows / inflows) are excluded from
  /// `quantities` because the chart tracks non-cash *position* holdings.
  /// Their contribution is captured by the cost basis via
  /// `TradeEventClassifier`.
  private func apply(
    transaction: Transaction,
    accountId: UUID,
    hostCurrency: Instrument,
    quantities: inout [Instrument: Decimal],
    engine: inout CostBasisEngine
  ) async {
    let accountLegs = transaction.legs.filter { $0.accountId == accountId }
    for leg in accountLegs where leg.instrument != hostCurrency {
      quantities[leg.instrument, default: 0] += leg.quantity
    }

    do {
      let classification = try await TradeEventClassifier.classify(
        legs: accountLegs, on: transaction.date,
        hostCurrency: hostCurrency, conversionService: conversionService
      )
      for buy in classification.buys {
        engine.processBuy(
          instrument: buy.instrument, quantity: buy.quantity,
          costPerUnit: buy.costPerUnit, date: transaction.date)
      }
      for sell in classification.sells {
        _ = engine.processSell(
          instrument: sell.instrument, quantity: sell.quantity,
          proceedsPerUnit: sell.proceedsPerUnit, date: transaction.date)
      }
    } catch {
      // A failed conversion when classifying a swap means we cannot derive
      // a cost basis for this leg. Quantities still update so the value
      // line is correct; cost basis on the affected instrument simply
      // stops advancing (the chart will draw a flat dashed line through
      // the gap, which is the honest representation of "we don't know").
      logger.warning(
        "TradeEventClassifier failed for txn \(transaction.id, privacy: .public) on \(transaction.date, privacy: .public): \(error.localizedDescription, privacy: .public)"
      )
    }
  }
}
