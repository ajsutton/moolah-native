import Foundation

/// Bundle of inputs for the daily-balances compute path. Groups the shared
/// transaction/account/investment-value inputs and the window (after /
/// forecastUntil) so `computeDailyBalances` stays under the 5-parameter
/// threshold.
struct DailyBalancesRequest: Sendable {
  let nonScheduled: [Transaction]
  let scheduled: [Transaction]
  let accounts: [Account]
  let investmentValues: [InvestmentValueSnapshot]
  let after: Date?
  let forecastUntil: Date?
}

extension CloudKitAnalysisRepository {
  // MARK: - Daily Balances Computation

  @concurrent
  static func computeDailyBalances(
    request: DailyBalancesRequest,
    context: CloudKitAnalysisContext
  ) async throws -> [DailyBalance] {
    let investmentAccountIds = Set(
      request.accounts.filter { $0.type == .investment }.map(\.id))
    let sorted = request.nonScheduled.sorted { $0.date < $1.date }

    var book = seedPriorBook(
      sorted: sorted, after: request.after, investmentAccountIds: investmentAccountIds)

    var dailyBalances = try await accumulateDailyBalances(
      sorted: sorted,
      after: request.after,
      investmentAccountIds: investmentAccountIds,
      book: &book,
      context: context
    )

    try await applyInvestmentValues(
      request.investmentValues, to: &dailyBalances, context: context)

    var actualBalances = dailyBalances.values.sorted { $0.date < $1.date }
    applyBestFit(to: &actualBalances, instrument: context.instrument)

    var forecastBalances: [DailyBalance] = []
    if let forecastUntil = request.forecastUntil {
      forecastBalances = try await generateForecast(
        scheduled: request.scheduled,
        startingBook: book,
        endDate: forecastUntil,
        investmentAccountIds: investmentAccountIds,
        context: context
      )
    }

    return actualBalances + forecastBalances
  }

  /// Seed the position book with pre-`after` transactions so the transfers-
  /// only investment read has a baseline. Extracted from `computeDailyBalances`
  /// to keep that function under the body-length threshold.
  private static func seedPriorBook(
    sorted: [Transaction],
    after: Date?,
    investmentAccountIds: Set<UUID>
  ) -> PositionBook {
    var book = PositionBook.empty
    guard let after else { return book }
    for txn in sorted where txn.date < after {
      book.apply(
        txn, investmentAccountIds: investmentAccountIds, asStartingBalance: true)
    }
    return book
  }

  /// Walk the post-`after` transactions, updating `book` and producing a
  /// daily balance dictionary. Rule 11: scope the `dailyBalance` catch so a
  /// single failing conversion drops only that day.
  private static func accumulateDailyBalances(
    sorted: [Transaction],
    after: Date?,
    investmentAccountIds: Set<UUID>,
    book: inout PositionBook,
    context: CloudKitAnalysisContext
  ) async throws -> [Date: DailyBalance] {
    var dailyBalances: [Date: DailyBalance] = [:]
    for txn in sorted where after.map({ txn.date >= $0 }) ?? true {
      book.apply(txn, investmentAccountIds: investmentAccountIds)
      let dayKey = Calendar.current.startOfDay(for: txn.date)
      do {
        dailyBalances[dayKey] = try await book.dailyBalance(
          on: txn.date,
          investmentAccountIds: investmentAccountIds,
          profileInstrument: context.instrument,
          rule: .investmentTransfersOnly,
          conversionService: context.conversionService,
          isForecast: false
        )
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        analysisLogger.warning(
          """
          Skipping daily balance for \(dayKey, privacy: .public) — conversion \
          failed: \(error.localizedDescription, privacy: .public). \
          Sibling days continue to render.
          """
        )
      }
    }
    return dailyBalances
  }

  // MARK: - Investment Values

  static func applyInvestmentValues(
    _ investmentValues: [InvestmentValueSnapshot],
    to dailyBalances: inout [Date: DailyBalance],
    context: CloudKitAnalysisContext
  ) async throws {
    guard !investmentValues.isEmpty, !dailyBalances.isEmpty else { return }

    var latestByAccount: [UUID: InstrumentAmount] = [:]
    var valueIndex = 0

    for date in dailyBalances.keys.sorted() {
      valueIndex = advanceInvestmentCursor(
        values: investmentValues,
        latestByAccount: &latestByAccount,
        from: valueIndex,
        upTo: date
      )

      if latestByAccount.isEmpty { continue }

      guard
        let totalValue = try await sumInvestmentValues(
          latestByAccount: latestByAccount, on: date, context: context)
      else {
        continue
      }

      // SwiftData guarantees we just iterated this key — but avoid `!` to
      // satisfy the force_unwrapping rule.
      guard let balance = dailyBalances[date] else { continue }
      dailyBalances[date] = DailyBalance(
        date: balance.date,
        balance: balance.balance,
        earmarked: balance.earmarked,
        availableFunds: balance.availableFunds,
        investments: balance.investments,
        investmentValue: totalValue,
        netWorth: balance.balance + totalValue,
        bestFit: balance.bestFit,
        isForecast: balance.isForecast
      )
    }
  }

  /// Advance the sorted investment-values cursor, updating the per-account
  /// latest map with every entry whose day is on-or-before `date`. Extracted
  /// so `applyInvestmentValues` fits within the body-length threshold.
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

  /// Sum the per-account investment values, converting foreign instruments
  /// to the profile instrument. Returns `nil` when any conversion fails so
  /// the caller can drop just this day (Rule 11 scoping).
  private static func sumInvestmentValues(
    latestByAccount: [UUID: InstrumentAmount],
    on date: Date,
    context: CloudKitAnalysisContext
  ) async throws -> InstrumentAmount? {
    var total: Decimal = 0
    for value in latestByAccount.values {
      if value.instrument.id == context.instrument.id {
        total += value.quantity
        continue
      }
      do {
        total += try await context.conversionService.convert(
          value.quantity, from: value.instrument, to: context.instrument, on: date)
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        analysisLogger.warning(
          """
          Skipping investmentValue for \(date, privacy: .public) — \
          conversion of \(value.instrument.id, privacy: .public) failed: \
          \(error.localizedDescription, privacy: .public).
          """
        )
        return nil
      }
    }
    return InstrumentAmount(quantity: total, instrument: context.instrument)
  }

  // MARK: - Best Fit

  /// Apply linear regression best-fit line to daily balances.
  /// Uses availableFunds as the y-axis value and day offset as x-axis.
  static func applyBestFit(to balances: inout [DailyBalance], instrument: Instrument) {
    guard balances.count >= 2 else { return }

    let referenceDate = balances[0].date
    let calendar = Calendar.current

    var sumX: Double = 0
    var sumY: Double = 0
    var sumXY: Double = 0
    var sumXX: Double = 0
    let count = Double(balances.count)

    var xValues: [Double] = []
    for balance in balances {
      let xValue = Double(
        calendar.dateComponents([.day], from: referenceDate, to: balance.date).day ?? 0)
      let yValue = Double(truncating: balance.availableFunds.quantity as NSDecimalNumber)
      xValues.append(xValue)
      sumX += xValue
      sumY += yValue
      sumXY += xValue * yValue
      sumXX += xValue * xValue
    }

    let denominator = count * sumXX - sumX * sumX
    guard abs(denominator) > 0.001 else { return }

    let slope = (count * sumXY - sumX * sumY) / denominator
    let intercept = (sumY - slope * sumX) / count

    for index in balances.indices {
      let predicted = Decimal(slope * xValues[index] + intercept)
      let existing = balances[index]
      balances[index] = DailyBalance(
        date: existing.date,
        balance: existing.balance,
        earmarked: existing.earmarked,
        availableFunds: existing.availableFunds,
        investments: existing.investments,
        investmentValue: existing.investmentValue,
        netWorth: existing.netWorth,
        bestFit: InstrumentAmount(quantity: predicted, instrument: instrument),
        isForecast: existing.isForecast
      )
    }
  }

}
