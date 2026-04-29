// Features/Investments/InvestmentStore+DailyBalanceAggregation.swift

import Foundation

// Per-instrument forward-fill + host-currency aggregation for the
// legacy investment-account chart, extracted from `InvestmentStore`
// so the main store body stays under SwiftLint's `type_body_length`
// budget after issue #579.

extension InvestmentStore {
  /// Aggregates per-(date, instrument) entries into a single
  /// host-currency series.
  ///
  /// The repository emits one row per (date, instrument) tuple but
  /// only when that instrument *changed* on that date. To compute the
  /// account's total cumulative cash investment on a given date we
  /// forward-fill each instrument's most recent running balance
  /// across all dates the account had any activity, then convert each
  /// instrument leg to `hostCurrency` on that date and sum.
  ///
  /// Conversion is done on each date's own value (the snapshot date),
  /// matching the legacy single-instrument behaviour and Rule 7 of
  /// `guides/INSTRUMENT_CONVERSION_GUIDE.md`.
  func aggregateDailyBalances(
    raw: [AccountDailyBalance], hostCurrency: Instrument
  ) async throws -> [AccountDailyBalance] {
    let activeDates = Array(Set(raw.map(\.date))).sorted()
    var entriesByDate: [Date: [AccountDailyBalance]] = [:]
    for entry in raw {
      entriesByDate[entry.date, default: []].append(entry)
    }

    var latestByInstrument: [String: AccountDailyBalance] = [:]
    var aggregated: [AccountDailyBalance] = []
    for date in activeDates {
      // Update each instrument's latest running balance with any
      // entries that fired on this date.
      for entry in entriesByDate[date] ?? [] {
        latestByInstrument[entry.balance.instrument.id] = entry
      }
      let total = try await convertedTotal(
        running: latestByInstrument.values,
        on: date,
        hostCurrency: hostCurrency)
      aggregated.append(
        AccountDailyBalance(
          date: date,
          balance: InstrumentAmount(quantity: total, instrument: hostCurrency)))
    }
    return aggregated
  }

  /// Converts each per-instrument running balance to `hostCurrency`
  /// on `date` and sums them. Throws on the first conversion failure
  /// so the caller can mark the whole series unavailable per Rule 11.
  private func convertedTotal(
    running: some Sequence<AccountDailyBalance>,
    on date: Date,
    hostCurrency: Instrument
  ) async throws -> Decimal {
    var total: Decimal = 0
    for entry in running {
      if entry.balance.instrument.id == hostCurrency.id {
        total += entry.balance.quantity
      } else {
        total += try await conversionService.convert(
          entry.balance.quantity,
          from: entry.balance.instrument,
          to: hostCurrency,
          on: date)
      }
    }
    return total
  }
}
