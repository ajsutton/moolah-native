import Foundation

/// Per-day position-valuation fold for trades-mode investment
/// accounts. Sister of `applyInvestmentValues` in
/// `+DailyBalancesInvestmentValues.swift` — same per-day Rule 11
/// error contract: `CancellationError` rethrows immediately; any
/// other thrown error drops the day from `dailyBalances` and logs
/// through `handleInvestmentValueFailure`.
///
/// Split out of `+DailyBalancesInvestmentValues.swift` for the
/// SwiftLint `file_length` budget — recorded-value (snapshot) and
/// trades-mode (position) folds are conceptually paired but each is
/// long enough to warrant its own file.
extension GRDBAnalysisRepository {

  // MARK: - Trades-mode per-day fold

  /// One decoded entry in the trades-mode cursor walk — a per-day,
  /// per-account, per-instrument quantity ready to apply to the
  /// cumulative `positions` dict. Four fields exceeds SwiftLint's
  /// `large_tuple` error threshold, so a named struct is required.
  private struct TradesModePositionEntry {
    let dayKey: Date
    let accountId: UUID
    let instrument: Instrument
    let quantity: Decimal
  }

  /// Per-day position-valuation fold for trades-mode investment
  /// accounts. Sister of `applyInvestmentValues` — same per-day error
  /// contract: `CancellationError` rethrows immediately; any other
  /// thrown error drops the day from `dailyBalances` and logs through
  /// `handleInvestmentValueFailure`.
  ///
  /// The fold builds a sorted cursor over trades-mode rows
  /// (`(dayKey, accountId, instrument, quantity)` entries), then
  /// walks `dailyBalances.keys.sorted()`. For each output `dayKey`,
  /// the cursor advances through every entry with `entry.dayKey <=
  /// dayKey` — including entries for days absent from
  /// `dailyBalances` (e.g. dropped by an earlier snapshot-fold
  /// failure) — so cumulative position state stays correct on every
  /// following day.
  ///
  /// `priorRows` and `postRows` carry only rows whose `accountId`
  /// belongs to a trades-mode investment account — pre-filtered in
  /// `readDailyBalancesAggregation` so this fold neither re-checks
  /// membership nor walks rows for accounts it doesn't own.
  static func applyTradesModePositionValuations(
    priorRows: [DailyBalanceAccountRow],
    postRows: [DailyBalanceAccountRow],
    to dailyBalances: inout [Date: DailyBalance],
    context: DailyBalancesAssemblyContext,
    handlers: DailyBalancesHandlers
  ) async throws {
    guard !context.tradesModeInvestmentAccountIds.isEmpty,
      !dailyBalances.isEmpty
    else { return }

    var positions = seedTradesModePriorPositions(
      priorRows: priorRows, instrumentMap: context.instrumentMap)
    let entries = buildTradesModeEntries(
      postRows: postRows, instrumentMap: context.instrumentMap)

    var valueIndex = 0
    for dayKey in dailyBalances.keys.sorted() {
      // The Rule 8 fast path inside `sumTradesModePositions` can let
      // the loop run synchronously when every position is in the
      // profile instrument; an explicit cancellation check ensures
      // the outer task can be torn down promptly even in that case.
      try Task.checkCancellation()
      // Advance the cursor: apply every entry on-or-before dayKey,
      // including those for days absent from dailyBalances.
      while valueIndex < entries.count, entries[valueIndex].dayKey <= dayKey {
        let entry = entries[valueIndex]
        positions[entry.accountId, default: [:]][entry.instrument, default: 0] +=
          entry.quantity
        valueIndex += 1
      }
      if positions.isEmpty { continue }
      do {
        // dayKey is `Calendar.current.startOfDay(for: row.sampleDate)`
        // — same normalization as walkDays and the conversion-service
        // lookup.
        let total = try await sumTradesModePositions(
          positions: positions,
          on: dayKey,
          profileInstrument: context.profileInstrument,
          conversionService: context.conversionService)
        mergeTradesModeTotal(
          total,
          into: &dailyBalances,
          on: dayKey,
          profileInstrument: context.profileInstrument)
      } catch let cancel as CancellationError {
        throw cancel
      } catch {
        // Rule 11: drop the day from dailyBalances so the chart shows
        // a gap. Matches the walkDays / applyInvestmentValues
        // per-day error contract.
        handlers.handleInvestmentValueFailure(error, dayKey)
        dailyBalances.removeValue(forKey: dayKey)
        continue
      }
    }
  }

  /// Pre-fold priors into a per-account, per-instrument cumulative
  /// dict. Decoding mirrors `applyDailyDeltas`: resolve the instrument
  /// via the registry, then convert the row's storage value into a
  /// Decimal quantity.
  private static func seedTradesModePriorPositions(
    priorRows: [DailyBalanceAccountRow],
    instrumentMap: [String: Instrument]
  ) -> [UUID: [Instrument: Decimal]] {
    var positions: [UUID: [Instrument: Decimal]] = [:]
    for row in priorRows {
      let instrument = resolveInstrument(row.instrumentId, in: instrumentMap)
      let quantity = InstrumentAmount(
        storageValue: row.qty, instrument: instrument
      ).quantity
      positions[row.accountId, default: [:]][instrument, default: 0] += quantity
    }
    return positions
  }

  /// Build a sorted cursor over post rows. Grouping by SQL `\.day`
  /// (UTC string) is intentionally avoided — the outer walk is over
  /// local-startOfDay `Date` keys, so we key the cursor at `dayKey`
  /// granularity directly to avoid Rule 10 timezone mismatch.
  private static func buildTradesModeEntries(
    postRows: [DailyBalanceAccountRow],
    instrumentMap: [String: Instrument]
  ) -> [TradesModePositionEntry] {
    var entries: [TradesModePositionEntry] = []
    entries.reserveCapacity(postRows.count)
    for row in postRows {
      let instrument = resolveInstrument(row.instrumentId, in: instrumentMap)
      let quantity = InstrumentAmount(
        storageValue: row.qty, instrument: instrument
      ).quantity
      entries.append(
        TradesModePositionEntry(
          dayKey: Calendar.current.startOfDay(for: row.sampleDate),
          accountId: row.accountId,
          instrument: instrument,
          quantity: quantity))
    }
    entries.sort { $0.dayKey < $1.dayKey }
    return entries
  }

  /// Merge a per-day trades-mode total into the existing
  /// `dailyBalances[dayKey]` row, summing into any
  /// recorded-value-fold-supplied `investmentValue` and recomputing
  /// `netWorth`. No-op when the day is absent (already dropped by
  /// an earlier failure).
  private static func mergeTradesModeTotal(
    _ total: InstrumentAmount,
    into dailyBalances: inout [Date: DailyBalance],
    on dayKey: Date,
    profileInstrument: Instrument
  ) {
    precondition(
      total.instrument == profileInstrument,
      "mergeTradesModeTotal: total must be in profileInstrument; got \(total.instrument.id)")
    guard let existing = dailyBalances[dayKey] else { return }
    let combined =
      (existing.investmentValue ?? .zero(instrument: profileInstrument)) + total
    dailyBalances[dayKey] = DailyBalance(
      date: existing.date,
      balance: existing.balance,
      earmarked: existing.earmarked,
      availableFunds: existing.availableFunds,
      investments: existing.investments,
      investmentValue: combined,
      netWorth: existing.balance + combined,
      bestFit: existing.bestFit,
      isForecast: existing.isForecast)
  }

  /// Sum per-account, per-instrument trades-mode positions on `date`,
  /// converting foreign instruments to the profile instrument via the
  /// conversion service. Rule 8 fast path applies at the leaf level
  /// so an account holding both profile-instrument and foreign-
  /// instrument positions still routes only the foreign positions
  /// through the service. Zero-quantity positions are skipped (a
  /// lingering instrument key after a same-day BUY+SELL nets out)
  /// to honour Rule 8's spirit — there is no value in a `0 * rate`
  /// async hop, and the answer is identically zero. When every
  /// position is in the profile instrument the function returns
  /// synchronously — the outer `applyTradesModePositionValuations`
  /// loop is responsible for the `try Task.checkCancellation()`
  /// that keeps the all-fast-path case promptly cancellable.
  private static func sumTradesModePositions(
    positions: [UUID: [Instrument: Decimal]],
    on date: Date,
    profileInstrument: Instrument,
    conversionService: any InstrumentConversionService
  ) async throws -> InstrumentAmount {
    var total: Decimal = 0
    for (_, perInstrument) in positions {
      for (instrument, quantity) in perInstrument {
        if quantity == 0 { continue }
        if instrument.id == profileInstrument.id {
          total += quantity
          continue
        }
        total += try await conversionService.convert(
          quantity, from: instrument, to: profileInstrument, on: date)
      }
    }
    return InstrumentAmount(quantity: total, instrument: profileInstrument)
  }
}
