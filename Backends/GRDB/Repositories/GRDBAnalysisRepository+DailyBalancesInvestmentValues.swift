import Foundation

/// Per-day investment-value fold-in for `fetchDailyBalances`. Walks
/// the per-day balances in date order, tracks the latest recorded
/// value per investment account, and overwrites each day's
/// `DailyBalance` with the converted-to-profile-instrument total —
/// driving the `investmentValue` and `netWorth` fields. Split out of
/// `+DailyBalances.swift` for the SwiftLint `file_length` budget.
extension GRDBAnalysisRepository {
  /// Fold the investment-value snapshots into the per-day balances by
  /// walking the days in order and tracking the latest value per
  /// account. Same per-day error contract as the historic walk: a
  /// failed conversion logs and drops just that day's investment
  /// override; the rest of the days continue.
  static func applyInvestmentValues(
    _ investmentValues: [InvestmentValueSnapshot],
    to dailyBalances: inout [Date: DailyBalance],
    context: DailyBalancesAssemblyContext,
    handlers: DailyBalancesHandlers
  ) async throws {
    guard !investmentValues.isEmpty, !dailyBalances.isEmpty else { return }
    var latestByAccount: [UUID: InstrumentAmount] = [:]
    var valueIndex = 0
    for date in dailyBalances.keys.sorted() {
      valueIndex = advanceInvestmentCursor(
        values: investmentValues,
        latestByAccount: &latestByAccount,
        from: valueIndex,
        upTo: date)
      if latestByAccount.isEmpty { continue }
      let totalValue: InstrumentAmount?
      do {
        totalValue = try await sumInvestmentValues(
          latestByAccount: latestByAccount,
          on: date,
          profileInstrument: context.profileInstrument,
          conversionService: context.conversionService)
      } catch let cancel as CancellationError {
        throw cancel
      } catch {
        handlers.handleInvestmentValueFailure(error, date)
        continue
      }
      guard let totalValue, let balance = dailyBalances[date] else { continue }
      dailyBalances[date] = DailyBalance(
        date: balance.date,
        balance: balance.balance,
        earmarked: balance.earmarked,
        availableFunds: balance.availableFunds,
        investments: balance.investments,
        investmentValue: totalValue,
        netWorth: balance.balance + totalValue,
        bestFit: balance.bestFit,
        isForecast: balance.isForecast)
    }
  }

  /// Advance the sorted investment-values cursor, updating the
  /// per-account latest map with every entry whose day is on-or-before
  /// `date`. Mirrors the CloudKit-side `advanceInvestmentCursor` so
  /// the two paths produce identical overrides on identical inputs.
  private static func advanceInvestmentCursor(
    values: [InvestmentValueSnapshot],
    latestByAccount: inout [UUID: InstrumentAmount],
    from startIndex: Int,
    upTo date: Date
  ) -> Int {
    var valueIndex = startIndex
    while valueIndex < values.count {
      let entry = values[valueIndex]
      let entryDay = Calendar.current.startOfDay(for: entry.date)
      if entryDay <= date {
        latestByAccount[entry.accountId] = entry.value
        valueIndex += 1
      } else {
        break
      }
    }
    return valueIndex
  }

  /// Sum the per-account investment values, converting foreign
  /// instruments to the profile instrument on `date`. Returns `nil`
  /// when any conversion fails so the caller can drop just this day's
  /// override without folding the failure into the historic-walk
  /// error path. Mirrors the CloudKit-side `sumInvestmentValues`.
  private static func sumInvestmentValues(
    latestByAccount: [UUID: InstrumentAmount],
    on date: Date,
    profileInstrument: Instrument,
    conversionService: any InstrumentConversionService
  ) async throws -> InstrumentAmount? {
    var total: Decimal = 0
    for value in latestByAccount.values {
      if value.instrument.id == profileInstrument.id {
        total += value.quantity
        continue
      }
      total += try await conversionService.convert(
        value.quantity, from: value.instrument, to: profileInstrument, on: date)
    }
    return InstrumentAmount(quantity: total, instrument: profileInstrument)
  }
}
