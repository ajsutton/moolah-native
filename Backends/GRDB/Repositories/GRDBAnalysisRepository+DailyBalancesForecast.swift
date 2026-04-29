import Foundation
import OSLog

/// Forecast extrapolation for `fetchDailyBalances`. Scheduled
/// transactions are expanded into per-instance `Transaction` values
/// in Swift (SQL can't extrapolate recurring patterns), each
/// instance's foreign-instrument legs are pre-converted on `Date()`
/// (Rule 6 of `INSTRUMENT_CONVERSION_GUIDE.md` — exchange-rate
/// sources have no future rates), and the converted instances feed a
/// sequential `PositionBook` walk that emits one forecast
/// `DailyBalance` per instance day.
///
/// Split out of `+DailyBalances.swift` for the SwiftLint
/// `file_length` budget.
extension GRDBAnalysisRepository {
  /// Generate the forecast tail by extrapolating scheduled
  /// transactions and feeding each instance into a fresh
  /// `PositionBook` walk. Mirrors `CloudKitAnalysisRepository.generateForecast`
  /// — the forecast path stays Swift-only because SQL can't
  /// extrapolate recurring patterns. Conversion runs on `Date()`
  /// because exchange-rate sources have no future rates.
  static func generateForecast(
    scheduled: [Transaction],
    startingBook: PositionBook,
    endDate: Date,
    context: DailyBalancesAssemblyContext
  ) async throws -> [DailyBalance] {
    var instances: [Transaction] = []
    for scheduledTxn in scheduled {
      instances.append(
        contentsOf: CloudKitAnalysisRepository.extrapolateScheduledTransaction(
          scheduledTxn, until: endDate))
    }
    instances.sort { $0.date < $1.date }
    // Scheduled transactions live in the future; exchange-rate sources
    // can't return future rates. Use today's rate as the best
    // available estimate, captured once so every instance uses the
    // same snapshot (Rule 6 of `INSTRUMENT_CONVERSION_GUIDE.md`).
    let conversionDate = Date()
    let converted = try await preConvertForecastInstances(
      instances,
      profileInstrument: context.profileInstrument,
      conversionService: context.conversionService,
      on: conversionDate)
    return try await runForecastAccumulator(
      converted: converted,
      startingBook: startingBook,
      context: context)
  }

  /// Pre-convert all instances concurrently — each conversion is
  /// independent. The accumulator that follows is inherently
  /// sequential (each iteration depends on the previous running
  /// totals), so it can't be parallelised. Mirrors
  /// `CloudKitAnalysisRepository.preConvertForecastInstances`.
  private static func preConvertForecastInstances(
    _ instances: [Transaction],
    profileInstrument: Instrument,
    conversionService: any InstrumentConversionService,
    on conversionDate: Date
  ) async throws -> [Transaction] {
    guard let firstInstance = instances.first else { return [] }
    return try await withThrowingTaskGroup(of: (Int, Transaction).self) { group in
      for (index, instance) in instances.enumerated() {
        group.addTask {
          let txn = try await CloudKitAnalysisRepository.convertLegsToProfileInstrument(
            instance,
            to: profileInstrument,
            on: conversionDate,
            conversionService: conversionService)
          return (index, txn)
        }
      }
      var out = Array(repeating: firstInstance, count: instances.count)
      for try await (index, txn) in group { out[index] = txn }
      return out
    }
  }

  /// Walk the pre-converted instances and emit one `DailyBalance` per
  /// instance day. Same Rule 11 scoping as the historic walk: a single
  /// day's conversion failure must not drop sibling forecast days.
  private static func runForecastAccumulator(
    converted: [Transaction],
    startingBook: PositionBook,
    context: DailyBalancesAssemblyContext
  ) async throws -> [DailyBalance] {
    var book = startingBook
    var forecastBalances: [Date: DailyBalance] = [:]
    let balanceContext = PositionBook.BalanceContext(
      investmentAccountIds: context.investmentAccountIds,
      profileInstrument: context.profileInstrument,
      rule: .investmentTransfersOnly,
      conversionService: context.conversionService)
    for instance in converted {
      book.apply(instance, investmentAccountIds: context.investmentAccountIds)
      let dayKey = Calendar.current.startOfDay(for: instance.date)
      do {
        forecastBalances[dayKey] = try await book.dailyBalance(
          on: instance.date, context: balanceContext, isForecast: true)
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        forecastLogger.warning(
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
}

/// File-private logger for forecast warnings emitted from the
/// accumulator. Hoisted to file scope (rather than reaching for the
/// main class's `private let logger`) so the static helpers stay free
/// of stored-property coupling — same shape as the warnings emitted
/// by other SQL-rewrite extensions.
private let forecastLogger = Logger(
  subsystem: "com.moolah.app", category: "GRDBAnalysisRepository.Forecast")
