import Foundation
import Testing

@testable import Moolah

@Suite("PositionsViewInput")
struct PositionsViewInputTests {
  let aud = Instrument.AUD
  let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")
  let fixedTestDate = Date(timeIntervalSinceReferenceDate: 0)

  private func amount(_ quantity: Decimal) -> InstrumentAmount {
    InstrumentAmount(quantity: quantity, instrument: aud)
  }

  @Test("totalValue sums all row values in host currency")
  func totalSumsRowValues() {
    let input = PositionsViewInput(
      title: "Brokerage",
      hostCurrency: aud,
      positions: [
        ValuedPosition(
          instrument: bhp, quantity: 1, unitPrice: nil, costBasis: nil,
          value: amount(11_325)),
        ValuedPosition(
          instrument: aud, quantity: 1_000, unitPrice: nil, costBasis: nil,
          value: amount(1_000)),
      ],
      historicalValue: nil
    )
    #expect(input.totalValue == amount(12_325))
  }

  @Test("totalValue is nil when any row's value is nil")
  func totalUnavailableOnFailure() {
    let input = PositionsViewInput(
      title: "Brokerage",
      hostCurrency: aud,
      positions: [
        ValuedPosition(
          instrument: bhp, quantity: 1, unitPrice: nil, costBasis: nil,
          value: amount(100)),
        ValuedPosition(
          instrument: bhp, quantity: 1, unitPrice: nil, costBasis: nil,
          value: nil),
      ],
      historicalValue: nil
    )
    #expect(input.totalValue == nil)
  }

  @Test("totalGainLoss sums per-row gain/loss; rows without cost contribute 0")
  func totalGainLossSums() {
    let input = PositionsViewInput(
      title: "x", hostCurrency: aud,
      positions: [
        ValuedPosition(
          instrument: bhp, quantity: 1, unitPrice: nil,
          costBasis: amount(80), value: amount(100)),
        ValuedPosition(
          instrument: aud, quantity: 1, unitPrice: nil,
          costBasis: nil, value: amount(50)),
      ],
      historicalValue: nil
    )
    #expect(input.totalGainLoss == amount(20))
  }

  @Test("showsPLPill is false when no row has cost basis")
  func plPillHiddenWhenNoCostBasis() {
    let input = PositionsViewInput(
      title: "x", hostCurrency: aud,
      positions: [
        ValuedPosition(
          instrument: aud, quantity: 1, unitPrice: nil,
          costBasis: nil, value: amount(100))
      ],
      historicalValue: nil
    )
    #expect(!input.showsPLPill)
  }

  @Test("showsPLPill is false when total is unavailable")
  func plPillHiddenWhenTotalUnavailable() {
    let input = PositionsViewInput(
      title: "x", hostCurrency: aud,
      positions: [
        ValuedPosition(
          instrument: bhp, quantity: 1, unitPrice: nil,
          costBasis: amount(50), value: nil)
      ],
      historicalValue: nil
    )
    #expect(!input.showsPLPill)
  }

  @Test("showsChart is false when historicalValue is nil")
  func chartHiddenWithoutSeries() {
    let input = PositionsViewInput(
      title: "x", hostCurrency: aud,
      positions: [
        ValuedPosition(
          instrument: bhp, quantity: 1, unitPrice: nil,
          costBasis: amount(50), value: amount(60))
      ],
      historicalValue: nil
    )
    #expect(!input.showsChart)
  }

  @Test("showsChart is false when no row carries cost basis")
  func chartHiddenWithoutAnyCostBasis() {
    let point = HistoricalValueSeries.Point(
      date: fixedTestDate, value: 60, cost: 50, contributions: 50)
    let input = PositionsViewInput(
      title: "x", hostCurrency: aud,
      positions: [
        ValuedPosition(
          instrument: aud, quantity: 1, unitPrice: nil,
          costBasis: nil, value: amount(100))
      ],
      historicalValue: HistoricalValueSeries(
        hostCurrency: aud, total: [point], perInstrument: [:])
    )
    #expect(!input.showsChart)
  }

  @Test("showsAggregateChart is false when any row's value is nil")
  func aggregateChartHiddenOnFailure() {
    let point = HistoricalValueSeries.Point(
      date: fixedTestDate, value: 60, cost: 50, contributions: 50)
    let input = PositionsViewInput(
      title: "x", hostCurrency: aud,
      positions: [
        ValuedPosition(
          instrument: bhp, quantity: 1, unitPrice: nil,
          costBasis: amount(50), value: amount(60)),
        ValuedPosition(
          instrument: bhp, quantity: 1, unitPrice: nil,
          costBasis: amount(40), value: nil),
      ],
      historicalValue: HistoricalValueSeries(
        hostCurrency: aud, total: [point], perInstrument: [:])
    )
    #expect(!input.showsAggregateChart)
    #expect(input.showsChart)  // chart can still render for working instruments
  }

  @Test("totalValue is zero (not nil) for empty positions")
  func totalValueEmptyPositions() {
    let input = PositionsViewInput(
      title: "x", hostCurrency: aud, positions: [], historicalValue: nil)
    #expect(input.totalValue == amount(0))
    #expect(input.totalGainLoss == amount(0))
    #expect(!input.showsPLPill)
    #expect(!input.showsGroupSubtotals)
  }

  @Test("showsPLPill is true when cost basis exists and total is available")
  func plPillVisibleWhenCostBasisAndTotal() {
    let input = PositionsViewInput(
      title: "x", hostCurrency: aud,
      positions: [
        ValuedPosition(
          instrument: bhp, quantity: 1, unitPrice: nil,
          costBasis: amount(50), value: amount(60))
      ],
      historicalValue: nil
    )
    #expect(input.showsPLPill)
  }

  @Test(
    "showsChart is true when historicalValue has points and at least one row carries cost basis")
  func chartVisibleWithSeriesAndCostBasis() {
    let point = HistoricalValueSeries.Point(
      date: fixedTestDate, value: 60, cost: 50, contributions: 50)
    let input = PositionsViewInput(
      title: "x", hostCurrency: aud,
      positions: [
        ValuedPosition(
          instrument: bhp, quantity: 1, unitPrice: nil,
          costBasis: amount(50), value: amount(60))
      ],
      historicalValue: HistoricalValueSeries(
        hostCurrency: aud, total: [point], perInstrument: [:])
    )
    #expect(input.showsChart)
  }

  @Test("showsGroupSubtotals is true only when more than one kind is present")
  func subtotalsRequireMultipleKinds() {
    let stockOnly = PositionsViewInput(
      title: "x", hostCurrency: aud,
      positions: [
        ValuedPosition(
          instrument: bhp, quantity: 1, unitPrice: nil,
          costBasis: nil, value: amount(60))
      ],
      historicalValue: nil
    )
    #expect(!stockOnly.showsGroupSubtotals)

    let mixed = PositionsViewInput(
      title: "x", hostCurrency: aud,
      positions: [
        ValuedPosition(
          instrument: bhp, quantity: 1, unitPrice: nil,
          costBasis: nil, value: amount(60)),
        ValuedPosition(
          instrument: aud, quantity: 1, unitPrice: nil,
          costBasis: nil, value: amount(60)),
      ],
      historicalValue: nil
    )
    #expect(mixed.showsGroupSubtotals)
  }

  @Test("hasHistoricalSeries is false when historicalValue is nil")
  func historicalSeriesAbsentWhenNoSeries() {
    let input = PositionsViewInput(
      title: "x", hostCurrency: aud, positions: [], historicalValue: nil)
    #expect(!input.hasHistoricalSeries)
  }

  @Test("hasHistoricalSeries is false when total is empty")
  func historicalSeriesAbsentWhenTotalEmpty() {
    let input = PositionsViewInput(
      title: "x", hostCurrency: aud, positions: [],
      historicalValue: HistoricalValueSeries(
        hostCurrency: aud, total: [], perInstrument: [:]))
    #expect(!input.hasHistoricalSeries)
  }

  @Test("hasHistoricalSeries is true when total has at least one point")
  func historicalSeriesPresentWhenTotalHasPoints() {
    let point = HistoricalValueSeries.Point(
      date: fixedTestDate, value: 100, cost: 80, contributions: 80)
    let input = PositionsViewInput(
      title: "x", hostCurrency: aud, positions: [],
      historicalValue: HistoricalValueSeries(
        hostCurrency: aud, total: [point], perInstrument: [:]))
    #expect(input.hasHistoricalSeries)
  }

  @Test("showsChart is true when positions is empty but historical total has points")
  func chartVisibleForEmptyPositionsWithHistory() {
    let point = HistoricalValueSeries.Point(
      date: fixedTestDate, value: 100, cost: 80, contributions: 80)
    let input = PositionsViewInput(
      title: "x", hostCurrency: aud, positions: [],
      historicalValue: HistoricalValueSeries(
        hostCurrency: aud, total: [point], perInstrument: [:]))
    #expect(input.showsChart)
  }

  @Test("showsChart is false when positions is empty and historical total is empty")
  func chartHiddenForEmptyPositionsWithoutHistory() {
    let input = PositionsViewInput(
      title: "x", hostCurrency: aud, positions: [],
      historicalValue: HistoricalValueSeries(
        hostCurrency: aud, total: [], perInstrument: [:]))
    #expect(!input.showsChart)
  }

  @Test("showsChart is false when positions has cost basis but historical total is empty")
  func chartHiddenWhenCostBasisButNoHistoricalPoints() {
    let input = PositionsViewInput(
      title: "x", hostCurrency: aud,
      positions: [
        ValuedPosition(
          instrument: bhp, quantity: 1, unitPrice: nil,
          costBasis: amount(50), value: amount(60))
      ],
      historicalValue: HistoricalValueSeries(
        hostCurrency: aud, total: [], perInstrument: [:]))
    #expect(!input.showsChart)
  }

}
