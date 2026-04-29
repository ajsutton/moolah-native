// Backends/GRDB/Repositories/GRDBAnalysisRepository+Conversion.swift

import Foundation

/// Conversion and day-bucketing helpers used by the SQL-driven analysis
/// methods on `GRDBAnalysisRepository`. Lifted into a sibling extension so
/// the main repository file stays small and so future SQL rewrites
/// (`fetchIncomeAndExpense`, `fetchCategoryBalances`,
/// `fetchDailyBalances`) can share the same day-string parser and the
/// (storageValue, instrument) → converted `InstrumentAmount` helper.
///
/// The helpers are static and free of CloudKit-only references so they
/// stand on their own once the SwiftData-era
/// `CloudKitAnalysisRepository` extension files are deleted.
extension GRDBAnalysisRepository {
  /// Day-string parser used by every SQL-driven method that aggregates
  /// `(DATE(t.date), …)`.
  ///
  /// SQLite's `DATE()` extracts the UTC calendar date of the stored
  /// timestamp (GRDB writes `Date` as UTC TEXT). The parser is anchored
  /// to a Gregorian calendar in UTC so the resulting `Date` round-trips
  /// through the conversion service's `ISO8601DateFormatter`
  /// (UTC-keyed) onto the same date string — preserving the per-day
  /// rate-cache equivalence argued in the §3.4 plan intro.
  ///
  /// Returns `nil` for malformed day strings; callers log and skip the
  /// row rather than silently swallowing.
  static func parseDayString(_ day: String) -> Date? {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.date(from: day)
  }

  /// Compute the financial-month key (`YYYYMM`) for `date`, respecting
  /// the user's configured `monthEnd` cut-off.
  ///
  /// Forwards to the existing `CloudKitAnalysisRepository.financialMonth`
  /// implementation for now so behaviour stays bit-for-bit identical
  /// to the SwiftData-era path. The CloudKit cleanup task in §3.4
  /// finalises the move into this extension.
  static func financialMonth(for date: Date, monthEnd: Int) -> String {
    CloudKitAnalysisRepository.financialMonth(for: date, monthEnd: monthEnd)
  }

  /// Build an `InstrumentAmount` in `target` from a SQL-summed storage
  /// quantity, converting on `day` when the source instrument differs.
  /// Same-instrument legs short-circuit and skip the conversion service.
  ///
  /// The leg-less signature (vs. CloudKit's
  /// `convertedAmount(_:to:on:conversionService:)` which takes a
  /// `TransactionLeg`) reflects the SQL aggregation: rows arrive as
  /// already-summed `(storageValue, instrumentId)` tuples, with no leg
  /// available to project from.
  static func convertedQuantity(
    storageValue: Int64,
    instrument: Instrument,
    to target: Instrument,
    on day: Date,
    conversionService: any InstrumentConversionService
  ) async throws -> InstrumentAmount {
    let amount = InstrumentAmount(storageValue: storageValue, instrument: instrument)
    if instrument.id == target.id {
      return amount
    }
    let converted = try await conversionService.convert(
      amount.quantity, from: instrument, to: target, on: day)
    return InstrumentAmount(quantity: converted, instrument: target)
  }
}
