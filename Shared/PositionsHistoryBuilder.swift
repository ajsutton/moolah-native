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

    // Range start: max of (cutoff for selected range, first holding date).
    let cutoff = range.cutoff(from: now) ?? firstTxnDate
    let start = calendar.startOfDay(for: max(cutoff, firstTxnDate))
    let endDay = calendar.startOfDay(for: now)
    guard endDay >= start else {
      return HistoricalValueSeries(
        hostCurrency: hostCurrency, total: [], perInstrument: [:])
    }

    // Pre-compute per-day snapshots in one pass over transactions. We fold
    // each transaction into a running snapshot, then on every distinct
    // event date emit "the snapshot as of end-of-that-day". Days in between
    // events carry the prior snapshot forward.
    var quantities: [Instrument: Decimal] = [:]
    var engine = CostBasisEngine()
    var txnIndex = 0

    var perInstrument: [String: [HistoricalValueSeries.Point]] = [:]
    var total: [HistoricalValueSeries.Point] = []

    // Pre-fold any transactions strictly before `start` so the snapshot at
    // `start` already reflects historical buys.
    while txnIndex < sortedTxns.count
      && calendar.startOfDay(for: sortedTxns[txnIndex].date) < start
    {
      await apply(
        transaction: sortedTxns[txnIndex], accountId: accountId,
        hostCurrency: hostCurrency,
        quantities: &quantities, engine: &engine
      )
      txnIndex += 1
    }

    var day = start
    while day <= endDay {
      if Task.isCancelled {
        return HistoricalValueSeries(
          hostCurrency: hostCurrency, total: total, perInstrument: perInstrument)
      }

      // Apply every transaction whose start-of-day is `day`.
      while txnIndex < sortedTxns.count
        && calendar.startOfDay(for: sortedTxns[txnIndex].date) == day
      {
        await apply(
          transaction: sortedTxns[txnIndex], accountId: accountId,
          hostCurrency: hostCurrency,
          quantities: &quantities, engine: &engine
        )
        txnIndex += 1
      }

      // Emit a point per held instrument + an aggregate (when complete).
      var aggValue: Decimal = 0
      var aggCost: Decimal = 0
      var aggOK = true
      var anyHeld = false

      for (instrument, qty) in quantities where qty != 0 {
        anyHeld = true
        let cost = engine.openLots(for: instrument)
          .reduce(Decimal(0)) { $0 + $1.remainingCost }

        let value: Decimal?
        do {
          value = try await conversionService.convert(
            qty, from: instrument, to: hostCurrency, on: day)
        } catch {
          logger.warning(
            "history conversion failed for \(instrument.id, privacy: .public) on \(day, privacy: .public): \(error.localizedDescription, privacy: .public)"
          )
          value = nil
          aggOK = false
        }

        if let value {
          perInstrument[instrument.id, default: []].append(
            HistoricalValueSeries.Point(date: day, value: value, cost: cost))
          aggValue += value
          aggCost += cost
        }
      }

      if anyHeld && aggOK {
        total.append(HistoricalValueSeries.Point(date: day, value: aggValue, cost: aggCost))
      }

      guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
      day = next
    }

    return HistoricalValueSeries(
      hostCurrency: hostCurrency, total: total, perInstrument: perInstrument)
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
