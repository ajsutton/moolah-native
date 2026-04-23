import Foundation

extension CloudKitAnalysisRepository {
  // MARK: - Currency Conversion Helpers

  /// Convert a transaction leg's amount to the target instrument, using the
  /// conversion service when the leg's instrument differs from the target.
  ///
  /// internal (was private) so sibling extension files — and the main-file
  /// static helpers — can reuse it without duplicating the currency-matching
  /// fast path.
  static func convertedAmount(
    _ leg: TransactionLeg,
    to instrument: Instrument,
    on date: Date,
    conversionService: any InstrumentConversionService
  ) async throws -> InstrumentAmount {
    if leg.instrument.id == instrument.id {
      return leg.amount
    }
    let converted = try await conversionService.convert(
      leg.quantity, from: leg.instrument, to: instrument, on: date)
    return InstrumentAmount(quantity: converted, instrument: instrument)
  }

  /// Return a copy of the transaction with every leg's quantity/instrument
  /// rewritten into the profile instrument. Used before feeding
  /// scheduled-transaction instances into the forecast accumulator so every
  /// leg already shares the profile instrument when `PositionBook.dailyBalance`
  /// is queried (skipping the multi-instrument conversion path on every
  /// forecast day).
  ///
  /// - Parameter date: date passed to the conversion service. For forecast
  ///   use, this is `Date()` — the current rate — because scheduled
  ///   transactions have future dates and no exchange-rate source has future
  ///   rates. Same-instrument legs are returned untouched.
  ///
  /// internal (was private) so the forecast helper in the sibling
  /// `+DailyBalances.swift` extension file can call it.
  static func convertLegsToProfileInstrument(
    _ txn: Transaction,
    to instrument: Instrument,
    on date: Date,
    conversionService: any InstrumentConversionService
  ) async throws -> Transaction {
    guard txn.legs.contains(where: { $0.instrument.id != instrument.id }) else {
      return txn
    }
    var convertedLegs: [TransactionLeg] = []
    convertedLegs.reserveCapacity(txn.legs.count)
    for leg in txn.legs {
      if leg.instrument.id == instrument.id {
        convertedLegs.append(leg)
        continue
      }
      let convertedQty = try await conversionService.convert(
        leg.quantity, from: leg.instrument, to: instrument, on: date)
      convertedLegs.append(
        TransactionLeg(
          accountId: leg.accountId,
          instrument: instrument,
          quantity: convertedQty,
          type: leg.type,
          categoryId: leg.categoryId,
          earmarkId: leg.earmarkId
        ))
    }
    var result = txn
    result.legs = convertedLegs
    return result
  }

  /// Compute the financial-month key (`YYYYMM`) that a calendar date falls
  /// into, respecting the user's configured `monthEnd` cut-off.
  ///
  /// internal (was private) so sibling extension files can reuse the same
  /// month-bucketing rule.
  static func financialMonth(for date: Date, monthEnd: Int) -> String {
    let calendar = Calendar.current
    let dayOfMonth = calendar.component(.day, from: date)
    let adjustedDate: Date
    if dayOfMonth > monthEnd {
      guard let shifted = calendar.date(byAdding: .month, value: 1, to: date) else {
        return Self.defaultMonthKey(for: date, calendar: calendar)
      }
      adjustedDate = shifted
    } else {
      adjustedDate = date
    }

    let year = calendar.component(.year, from: adjustedDate)
    let month = calendar.component(.month, from: adjustedDate)
    return String(format: "%04d%02d", year, month)
  }

  private static func defaultMonthKey(for date: Date, calendar: Calendar) -> String {
    let year = calendar.component(.year, from: date)
    let month = calendar.component(.month, from: date)
    return String(format: "%04d%02d", year, month)
  }
}
