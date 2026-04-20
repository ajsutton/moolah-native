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
