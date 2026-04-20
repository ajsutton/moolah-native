import Foundation
import Testing

@testable import Moolah

@Suite("ValuedPosition")
struct ValuedPositionTests {
  let aud = Instrument.AUD
  let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")

  @Test("amount returns InstrumentAmount in the position's instrument")
  func amountWrapsInstrument() {
    let row = ValuedPosition(
      instrument: bhp,
      quantity: 250,
      unitPrice: InstrumentAmount(quantity: 45.30, instrument: aud),
      costBasis: InstrumentAmount(quantity: 10_125, instrument: aud),
      value: InstrumentAmount(quantity: 11_325, instrument: aud)
    )
    #expect(row.amount == InstrumentAmount(quantity: 250, instrument: bhp))
  }

  @Test("hasCostBasis is true only when costBasis is non-nil")
  func hasCostBasisFlag() {
    let withCost = ValuedPosition(
      instrument: bhp, quantity: 1,
      unitPrice: nil,
      costBasis: InstrumentAmount(quantity: 50, instrument: aud),
      value: InstrumentAmount(quantity: 60, instrument: aud)
    )
    let withoutCost = ValuedPosition(
      instrument: bhp, quantity: 1,
      unitPrice: nil, costBasis: nil,
      value: InstrumentAmount(quantity: 60, instrument: aud)
    )
    #expect(withCost.hasCostBasis)
    #expect(!withoutCost.hasCostBasis)
  }

  @Test("gainLoss computes value - cost in host currency")
  func gainLossSubtraction() {
    let row = ValuedPosition(
      instrument: bhp, quantity: 250,
      unitPrice: nil,
      costBasis: InstrumentAmount(quantity: 10_125, instrument: aud),
      value: InstrumentAmount(quantity: 11_325, instrument: aud)
    )
    #expect(row.gainLoss == InstrumentAmount(quantity: 1200, instrument: aud))
  }

  @Test("gainLoss is nil when value is nil")
  func gainLossNilOnFailure() {
    let row = ValuedPosition(
      instrument: bhp, quantity: 250,
      unitPrice: nil,
      costBasis: InstrumentAmount(quantity: 10_125, instrument: aud),
      value: nil
    )
    #expect(row.gainLoss == nil)
  }

  @Test("gainLoss is nil when costBasis is nil (pure flow row)")
  func gainLossNilWithoutCost() {
    let row = ValuedPosition(
      instrument: aud, quantity: 1_000,
      unitPrice: nil, costBasis: nil,
      value: InstrumentAmount(quantity: 1_000, instrument: aud)
    )
    #expect(row.gainLoss == nil)
  }

  @Test("gainLoss is negative when value is below cost basis")
  func gainLossNegativeOnUnderwater() {
    let row = ValuedPosition(
      instrument: bhp, quantity: 250,
      unitPrice: nil,
      costBasis: InstrumentAmount(quantity: 11_325, instrument: aud),
      value: InstrumentAmount(quantity: 10_125, instrument: aud)
    )
    #expect(row.gainLoss == InstrumentAmount(quantity: -1_200, instrument: aud))
  }
}

@Suite("HistoricalValueSeries")
struct HistoricalValueSeriesTests {
  let aud = Instrument.AUD
  let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")
  let cba = Instrument.stock(ticker: "CBA.AX", exchange: "ASX", name: "CBA")

  private func date(_ day: Int) -> Date {
    Date(timeIntervalSince1970: TimeInterval(day) * 86_400)
  }

  @Test("series(for:) returns the per-instrument slice when present")
  func sliceLookup() {
    let series = HistoricalValueSeries(
      hostCurrency: aud,
      total: [
        HistoricalValueSeries.Point(date: date(1), value: 100, cost: 80),
        HistoricalValueSeries.Point(date: date(2), value: 110, cost: 80),
      ],
      perInstrument: [
        bhp.id: [
          HistoricalValueSeries.Point(date: date(1), value: 60, cost: 50)
        ]
      ]
    )

    #expect(series.series(for: bhp).count == 1)
    #expect(series.series(for: cba).isEmpty)
    #expect(series.totalSeries.count == 2)
  }

  @Test("instruments lists every per-instrument key")
  func instrumentsReturnsKeys() {
    let series = HistoricalValueSeries(
      hostCurrency: aud,
      total: [],
      perInstrument: [
        bhp.id: [], cba.id: [],
      ]
    )
    #expect(Set(series.instruments) == Set([bhp.id, cba.id]))
  }

  @Test("totalSeries is empty when total is empty even when perInstrument has data")
  func totalEmptyWithPerInstrumentPopulated() {
    let series = HistoricalValueSeries(
      hostCurrency: aud,
      total: [],
      perInstrument: [
        bhp.id: [HistoricalValueSeries.Point(date: date(1), value: 60, cost: 50)]
      ]
    )
    #expect(series.totalSeries.isEmpty)
    #expect(series.series(for: bhp).count == 1)
  }
}

@Suite("PositionsViewInput")
struct PositionsViewInputTests {
  let aud = Instrument.AUD
  let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")

  private func amount(_ q: Decimal) -> InstrumentAmount {
    InstrumentAmount(quantity: q, instrument: aud)
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
    let input = PositionsViewInput(
      title: "x", hostCurrency: aud,
      positions: [
        ValuedPosition(
          instrument: aud, quantity: 1, unitPrice: nil,
          costBasis: nil, value: amount(100))
      ],
      historicalValue: HistoricalValueSeries(
        hostCurrency: aud, total: [], perInstrument: [:])
    )
    #expect(!input.showsChart)
  }

  @Test("showsAggregateChart is false when any row's value is nil")
  func aggregateChartHiddenOnFailure() {
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
        hostCurrency: aud, total: [], perInstrument: [:])
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

  @Test("showsChart is true when historicalValue exists and at least one row carries cost basis")
  func chartVisibleWithSeriesAndCostBasis() {
    let input = PositionsViewInput(
      title: "x", hostCurrency: aud,
      positions: [
        ValuedPosition(
          instrument: bhp, quantity: 1, unitPrice: nil,
          costBasis: amount(50), value: amount(60))
      ],
      historicalValue: HistoricalValueSeries(
        hostCurrency: aud, total: [], perInstrument: [:])
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
}
