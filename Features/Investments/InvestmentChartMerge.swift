// Features/Investments/InvestmentChartMerge.swift

import Foundation

/// Chart-data merging utilities for the legacy investment-account
/// chart. Extracted from `InvestmentStore` so that file stays under
/// SwiftLint's `file_length` budget after the issue-#579
/// multi-instrument refactoring grew the store body.
///
/// Algorithm ported from `InvestmentValueGraph.vue:61-141`. Merges
/// per-day investment-value snapshots (`InvestmentValue`) with the
/// per-day cumulative-balance series (`AccountDailyBalance`) into a
/// single `[InvestmentChartDataPoint]`, forward-filling gaps and
/// computing profit/loss on every point that has both inputs.
enum InvestmentChartMerge {
  /// Forward-fill state for `forwardFill`. A `var` holding `lastValue`
  /// / `lastBalance` so each iteration can override either (or both)
  /// when the current data point provides a fresh number.
  private struct ForwardFillState {
    var lastValue: Decimal?
    var lastBalance: Decimal?
  }

  /// One date's (optional value, optional balance) pair, populated as
  /// the merge walks both input arrays. Replaces an inline 2-tuple so
  /// the consuming sort can extract elements by name.
  private struct ChartPointInputs {
    var value: Decimal?
    var balance: Decimal?
  }

  /// Merges investment values and daily balances into chart data
  /// points, forward-filling gaps and computing profit/loss on every
  /// point that has both inputs.
  static func merge(
    values: [InvestmentValue],
    balances: [AccountDailyBalance],
    period: TimePeriod
  ) -> [InvestmentChartDataPoint] {
    let startDate = period.startDate
    let valuesPart = collectValues(values, startDate: startDate)
    let balancesPart = collectBalances(balances, startDate: startDate)
    let combined = mergeCollected(
      values: valuesPart, balances: balancesPart, startDate: startDate)
    return forwardFill(dataByDate: combined)
  }

  /// Collected investment-value samples after applying the
  /// `startDate` cut-off, plus the most recent pre-period value (used
  /// later as a "seed" anchor at `startDate` so the chart doesn't
  /// start at zero).
  private struct CollectedValues {
    var byDate: [Date: Decimal]
    var preStart: InvestmentValue?
  }

  private struct CollectedBalances {
    var byDate: [Date: Decimal]
    var preStart: AccountDailyBalance?
  }

  private static func collectValues(
    _ values: [InvestmentValue], startDate: Date?
  ) -> CollectedValues {
    var byDate: [Date: Decimal] = [:]
    var preStart: InvestmentValue?
    for value in values {
      if let startDate, value.date < startDate {
        if value.date > (preStart?.date ?? .distantPast) { preStart = value }
        continue
      }
      byDate[value.date] = value.value.quantity
    }
    return CollectedValues(byDate: byDate, preStart: preStart)
  }

  private static func collectBalances(
    _ balances: [AccountDailyBalance], startDate: Date?
  ) -> CollectedBalances {
    var byDate: [Date: Decimal] = [:]
    var preStart: AccountDailyBalance?
    for balance in balances {
      if let startDate, balance.date < startDate {
        if balance.date > (preStart?.date ?? .distantPast) { preStart = balance }
        continue
      }
      byDate[balance.date] = balance.balance.quantity
    }
    return CollectedBalances(byDate: byDate, preStart: preStart)
  }

  /// Joins per-date value and balance samples into a single map and,
  /// when a `startDate` cut-off is in play, anchors the most recent
  /// pre-period values at the cut-off so the chart's first plotted
  /// point isn't pinned to zero.
  private static func mergeCollected(
    values: CollectedValues, balances: CollectedBalances, startDate: Date?
  ) -> [Date: ChartPointInputs] {
    var dataByDate: [Date: ChartPointInputs] = [:]
    for (date, quantity) in values.byDate {
      var slot = dataByDate[date] ?? ChartPointInputs()
      slot.value = quantity
      dataByDate[date] = slot
    }
    for (date, quantity) in balances.byDate {
      var slot = dataByDate[date] ?? ChartPointInputs()
      slot.balance = quantity
      dataByDate[date] = slot
    }
    if let startDate {
      var slot = dataByDate[startDate] ?? ChartPointInputs()
      if slot.value == nil, let seed = values.preStart {
        slot.value = seed.value.quantity
      }
      if slot.balance == nil, let seed = balances.preStart {
        slot.balance = seed.balance.quantity
      }
      if slot.value != nil || slot.balance != nil {
        dataByDate[startDate] = slot
      }
    }
    return dataByDate
  }

  private static func forwardFill(
    dataByDate: [Date: ChartPointInputs]
  ) -> [InvestmentChartDataPoint] {
    let sorted =
      dataByDate
      .map { (date: $0.key, inputs: $0.value) }
      .sorted { $0.date < $1.date }

    var state = ForwardFillState()
    var result: [InvestmentChartDataPoint] = []

    for item in sorted {
      let currentValue = item.inputs.value ?? state.lastValue
      let currentBalance = item.inputs.balance ?? state.lastBalance

      if let itemValue = item.inputs.value { state.lastValue = itemValue }
      if let itemBalance = item.inputs.balance { state.lastBalance = itemBalance }

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

/// Free-function shim preserved for existing tests / call sites that
/// were written against the `InvestmentValueGraph.vue` port before the
/// merge implementation moved into `InvestmentChartMerge`.
func mergeChartData(
  values: [InvestmentValue],
  balances: [AccountDailyBalance],
  period: TimePeriod
) -> [InvestmentChartDataPoint] {
  InvestmentChartMerge.merge(values: values, balances: balances, period: period)
}
