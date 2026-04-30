import Foundation
import Testing

@testable import Moolah

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
