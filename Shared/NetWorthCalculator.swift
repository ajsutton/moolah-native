import Foundation

/// A transaction leg paired with its transaction date, for time-series computation.
struct DatedLeg: Sendable {
  let leg: TransactionLeg
  let date: Date
}

/// Computes daily net worth across multiple instruments by converting positions to profile currency.
///
/// Performance approach: Option A — Direct computation.
/// Benchmarked: ~0.01ms for 1825 days x 5 instruments of pure in-memory position accumulation
/// and price map lookup simulation. Well under the 2s threshold for direct computation.
/// The price services cache full date->price maps locally after initial fetch, so lookups
/// after the first batch are dictionary reads. No resolution reduction or persistent caching needed.
struct NetWorthCalculator: Sendable {
  let profileCurrency: Instrument
  let conversionService: InstrumentConversionService

  /// Compute net worth time series from dated legs over a date range.
  ///
  /// Legs must not be empty. Only days where a leg occurs produce a data point.
  /// Each point represents cumulative position value in profile currency as of that date.
  func compute(
    legs: [DatedLeg],
    dateRange: ClosedRange<Date>
  ) async throws -> [NetWorthPoint] {
    guard !legs.isEmpty else { return [] }

    let calendar = Calendar(identifier: .gregorian)
    let sortedLegs =
      legs
      .filter { dateRange.contains($0.date) }
      .sorted { $0.date < $1.date }
    guard !sortedLegs.isEmpty else { return [] }

    // Group legs by day
    var legsByDay: [(date: Date, legs: [TransactionLeg])] = []
    var currentDay = calendar.startOfDay(for: sortedLegs[0].date)
    var currentDayLegs: [TransactionLeg] = []

    for dated in sortedLegs {
      let day = calendar.startOfDay(for: dated.date)
      if day != currentDay {
        legsByDay.append((currentDay, currentDayLegs))
        currentDay = day
        currentDayLegs = []
      }
      currentDayLegs.append(dated.leg)
    }
    legsByDay.append((currentDay, currentDayLegs))

    // Accumulate positions and convert daily
    var positions: [String: Decimal] = [:]
    var points: [NetWorthPoint] = []

    for (date, dayLegs) in legsByDay {
      for leg in dayLegs {
        positions[leg.instrument.id, default: 0] += leg.quantity
      }

      // Convert all non-zero positions to profile currency
      var totalValue: Decimal = 0
      for (instrumentId, quantity) in positions where quantity != 0 {
        if instrumentId == profileCurrency.id {
          totalValue += quantity
        } else {
          let instrument = instrumentForId(instrumentId, in: sortedLegs)
          let converted = try await conversionService.convert(
            quantity, from: instrument, to: profileCurrency, on: date
          )
          totalValue += converted
        }
      }

      points.append(
        NetWorthPoint(
          date: date,
          value: InstrumentAmount(quantity: totalValue, instrument: profileCurrency)
        ))
    }

    return points
  }

  private func instrumentForId(_ id: String, in legs: [DatedLeg]) -> Instrument {
    legs.first { $0.leg.instrument.id == id }!.leg.instrument
  }
}
