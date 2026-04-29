// Features/Investments/InvestmentChartData.swift

import Foundation

/// Pure functions that merge investment values and daily balances into
/// chart data points. Namespaced in a caseless enum so they don't leak
/// into the app target's top level — visible to `@testable import
/// Moolah` so the algorithm can be unit-tested without driving the
/// store's async pipeline. Algorithm ported from
/// InvestmentValueGraph.vue:61-141.
enum InvestmentChartData {
  /// One bucket of merged data before forward-filling. `value` is the
  /// snapshot price for the date, `balance` is the cumulative cost
  /// basis. Both are optional because a date may have only one of the
  /// two recorded.
  struct Bucket: Equatable {
    let value: Decimal?
    let balance: Decimal?
  }

  /// One forward-filled chart point pre-pack into `InvestmentChartDataPoint`.
  /// Replaces a three-element tuple to satisfy `large_tuple` and avoid
  /// positional-argument confusion at the call site.
  private struct PendingPoint {
    let date: Date
    let value: Decimal?
    let balance: Decimal?
  }

  static func merge(
    values: [InvestmentValue],
    balances: [AccountDailyBalance],
    period: TimePeriod
  ) -> [InvestmentChartDataPoint] {
    let startDate = period.startDate
    let collected = collectByDate(values: values, balances: balances, startDate: startDate)
    return forwardFill(dataByDate: collected)
  }

  private static func collectByDate(
    values: [InvestmentValue],
    balances: [AccountDailyBalance],
    startDate: Date?
  ) -> [Date: Bucket] {
    var dataByDate: [Date: Bucket] = [:]
    var startValue: InvestmentValue?
    var startBalance: AccountDailyBalance?

    for value in values {
      if let startDate, value.date < startDate {
        if value.date > (startValue?.date ?? .distantPast) { startValue = value }
        continue
      }
      let existing = dataByDate[value.date]
      dataByDate[value.date] = Bucket(value: value.value.quantity, balance: existing?.balance)
    }

    for balance in balances {
      if let startDate, balance.date < startDate {
        if balance.date > (startBalance?.date ?? .distantPast) { startBalance = balance }
        continue
      }
      let existing = dataByDate[balance.date]
      dataByDate[balance.date] = Bucket(value: existing?.value, balance: balance.balance.quantity)
    }

    // If we have pre-period values, add them at the start date.
    if let startDate {
      if let seedValue = startValue {
        let existing = dataByDate[startDate]
        dataByDate[startDate] = Bucket(
          value: existing?.value ?? seedValue.value.quantity,
          balance: existing?.balance)
      }
      if let seedBalance = startBalance {
        let existing = dataByDate[startDate]
        dataByDate[startDate] = Bucket(
          value: existing?.value,
          balance: existing?.balance ?? seedBalance.balance.quantity)
      }
    }
    return dataByDate
  }

  private static func forwardFill(
    dataByDate: [Date: Bucket]
  ) -> [InvestmentChartDataPoint] {
    let sorted =
      dataByDate
      .map { PendingPoint(date: $0.key, value: $0.value.value, balance: $0.value.balance) }
      .sorted { $0.date < $1.date }

    var lastValue: Decimal?
    var lastBalance: Decimal?
    var result: [InvestmentChartDataPoint] = []

    for item in sorted {
      let currentValue = item.value ?? lastValue
      let currentBalance = item.balance ?? lastBalance

      if let itemValue = item.value { lastValue = itemValue }
      if let itemBalance = item.balance { lastBalance = itemBalance }

      let profitLoss: Decimal? =
        if let value = currentValue, let balance = currentBalance {
          value - balance
        } else {
          nil
        }

      result.append(
        InvestmentChartDataPoint(
          date: item.date,
          value: currentValue,
          balance: currentBalance,
          profitLoss: profitLoss))
    }

    return result
  }
}
