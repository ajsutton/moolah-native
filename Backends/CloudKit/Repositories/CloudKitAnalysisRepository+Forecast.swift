import Foundation

extension CloudKitAnalysisRepository {
  // MARK: - Forecast

  static func generateForecast(
    scheduled: [Transaction],
    startingBook: PositionBook,
    endDate: Date,
    investmentAccountIds: Set<UUID>,
    context: CloudKitAnalysisContext
  ) async throws -> [DailyBalance] {
    var instances: [Transaction] = []
    for scheduledTxn in scheduled {
      instances.append(contentsOf: extrapolateScheduledTransaction(scheduledTxn, until: endDate))
    }
    instances.sort { $0.date < $1.date }

    // Scheduled transactions live in the future; exchange-rate sources can't
    // return future rates. Use today's rate as the best available estimate
    // for forecast conversion. Captured once so every instance uses the same
    // snapshot.
    let conversionDate = Date()
    let converted = try await preConvertForecastInstances(
      instances, context: context, on: conversionDate)

    return try await runForecastAccumulator(
      converted: converted,
      startingBook: startingBook,
      investmentAccountIds: investmentAccountIds,
      context: context
    )
  }

  /// Pre-convert all instances concurrently — each conversion is
  /// independent. The accumulator that follows is inherently sequential
  /// (each iteration depends on the previous running totals), so it can't be
  /// parallelised. See guides/CONCURRENCY_GUIDE.md: dynamic count → TaskGroup.
  ///
  /// After pre-conversion every leg's instrument matches the profile
  /// instrument, so `book.dailyBalance` hits the single-instrument fast path.
  private static func preConvertForecastInstances(
    _ instances: [Transaction],
    context: CloudKitAnalysisContext,
    on conversionDate: Date
  ) async throws -> [Transaction] {
    guard let firstInstance = instances.first else { return [] }
    return try await withThrowingTaskGroup(
      of: (Int, Transaction).self
    ) { group in
      for (index, instance) in instances.enumerated() {
        group.addTask {
          let txn = try await convertLegsToProfileInstrument(
            instance,
            to: context.instrument,
            on: conversionDate,
            conversionService: context.conversionService
          )
          return (index, txn)
        }
      }
      var out = Array(repeating: firstInstance, count: instances.count)
      for try await (index, txn) in group { out[index] = txn }
      return out
    }
  }

  /// Walk the pre-converted instances and emit one `DailyBalance` per
  /// instance day. See Rule 11 scoping note in `computeDailyBalances`: a
  /// single day's conversion failure must not drop sibling forecast days.
  private static func runForecastAccumulator(
    converted: [Transaction],
    startingBook: PositionBook,
    investmentAccountIds: Set<UUID>,
    context: CloudKitAnalysisContext
  ) async throws -> [DailyBalance] {
    var book = startingBook
    var forecastBalances: [Date: DailyBalance] = [:]
    for instance in converted {
      book.apply(instance, investmentAccountIds: investmentAccountIds)

      let dayKey = Calendar.current.startOfDay(for: instance.date)
      do {
        forecastBalances[dayKey] = try await book.dailyBalance(
          on: instance.date,
          investmentAccountIds: investmentAccountIds,
          profileInstrument: context.instrument,
          rule: .investmentTransfersOnly,
          conversionService: context.conversionService,
          isForecast: true
        )
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        analysisLogger.warning(
          """
          Skipping forecast balance for \(dayKey, privacy: .public) — \
          conversion failed: \(error.localizedDescription, privacy: .public). \
          Sibling forecast days continue to render.
          """
        )
      }
    }
    return forecastBalances.values.sorted { $0.date < $1.date }
  }

  // MARK: - Scheduled Transaction Extrapolation

  static func extrapolateScheduledTransaction(
    _ scheduled: Transaction,
    until endDate: Date
  ) -> [Transaction] {
    guard let period = scheduled.recurPeriod, period != .once else {
      return scheduled.date <= endDate ? [scheduled] : []
    }

    let every = scheduled.recurEvery ?? 1
    var instances: [Transaction] = []
    var currentDate = scheduled.date

    while currentDate <= endDate {
      var instance = scheduled
      instance.date = currentDate
      instance.recurPeriod = nil
      instance.recurEvery = nil
      instances.append(instance)

      guard let nextDate = nextDueDate(from: currentDate, period: period, every: every) else {
        break
      }
      currentDate = nextDate
    }

    return instances
  }

  static func nextDueDate(from date: Date, period: RecurPeriod, every: Int) -> Date? {
    let calendar = Calendar.current
    var components = DateComponents()

    switch period {
    case .day:
      components.day = every
    case .week:
      components.weekOfYear = every
    case .month:
      components.month = every
    case .year:
      components.year = every
    case .once:
      return nil
    }

    return calendar.date(byAdding: components, to: date)
  }
}
