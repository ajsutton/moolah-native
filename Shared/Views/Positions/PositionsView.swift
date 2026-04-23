// swiftlint:disable multiline_arguments

import SwiftUI

/// Unified container for displaying positions across the app. Composes a
/// header, optional chart, and responsive table from a single
/// `PositionsViewInput`. Renders nothing for empty input — callers decide
/// whether to show context-specific empty state.
///
/// Selection: a single tap on a row filters the chart to that instrument.
/// Tapping again, the chip's ✕, or pressing Escape clears the selection.
struct PositionsView: View {
  let input: PositionsViewInput

  @State private var selection: Instrument?
  @Binding var range: PositionsTimeRange

  var body: some View {
    if input.positions.isEmpty {
      EmptyView()
    } else {
      VStack(spacing: 0) {
        PositionsHeader(input: input)
        if input.showsChart {
          Divider()
          PositionsChart(
            input: input,
            range: $range,
            selectedInstrument: $selection
          )
          .padding(.vertical, 8)
        }
        Divider()
        PositionsTable(input: input, selection: $selection)
      }
      #if os(macOS)
        .onExitCommand { selection = nil }
      #endif
      .onChange(of: input) { _, _ in
        selection = nil
      }
    }
  }
}

#Preview("Default") {
  let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")
  let cba = Instrument.stock(ticker: "CBA.AX", exchange: "ASX", name: "CBA")
  let aud = Instrument.AUD
  PositionsView(
    input: PositionsViewInput(
      title: "Brokerage",
      hostCurrency: aud,
      positions: [
        ValuedPosition(
          instrument: bhp, quantity: 250,
          unitPrice: InstrumentAmount(quantity: 45.30, instrument: aud),
          costBasis: InstrumentAmount(quantity: 10_125, instrument: aud),
          value: InstrumentAmount(quantity: 11_325, instrument: aud)
        ),
        ValuedPosition(
          instrument: cba, quantity: 80,
          unitPrice: InstrumentAmount(quantity: 120, instrument: aud),
          costBasis: InstrumentAmount(quantity: 9_000, instrument: aud),
          value: InstrumentAmount(quantity: 9_600, instrument: aud)
        ),
        ValuedPosition(
          instrument: aud, quantity: 2_480,
          unitPrice: nil, costBasis: nil,
          value: InstrumentAmount(quantity: 2_480, instrument: aud)
        ),
      ],
      historicalValue: nil  // chart hidden in preview to keep snapshot stable
    ),
    range: .constant(.threeMonths)
  )
  .frame(width: 720, height: 480)
}

#Preview("All fiat") {
  PositionsView(
    input: PositionsViewInput(
      title: "Travel Wallet",
      hostCurrency: .AUD,
      positions: [
        ValuedPosition(
          instrument: .USD, quantity: 100,
          unitPrice: nil, costBasis: nil,
          value: InstrumentAmount(quantity: 152, instrument: .AUD)),
        ValuedPosition(
          instrument: .AUD, quantity: 1_000,
          unitPrice: nil, costBasis: nil,
          value: InstrumentAmount(quantity: 1_000, instrument: .AUD)),
      ],
      historicalValue: nil
    ),
    range: .constant(.threeMonths)
  )
  .frame(width: 480, height: 240)
}

#Preview("Conversion failure") {
  let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")
  PositionsView(
    input: PositionsViewInput(
      title: "Brokerage",
      hostCurrency: .AUD,
      positions: [
        ValuedPosition(
          instrument: bhp, quantity: 250,
          unitPrice: nil, costBasis: nil, value: nil)
      ],
      historicalValue: nil
    ),
    range: .constant(.threeMonths)
  )
  .frame(width: 480, height: 240)
}

#Preview("Empty") {
  PositionsView(
    input: PositionsViewInput(
      title: "Empty",
      hostCurrency: .AUD,
      positions: [],
      historicalValue: nil
    ),
    range: .constant(.threeMonths)
  )
  .frame(width: 480, height: 200)
}

#Preview("With chart") {
  let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")
  let aud = Instrument.AUD
  let calendar = Calendar(identifier: .gregorian)
  let now = Date()
  let points: [HistoricalValueSeries.Point] = (0..<60).map { d in
    let date = calendar.date(byAdding: .day, value: -59 + d, to: now) ?? now
    return HistoricalValueSeries.Point(
      date: date, value: 10_000 + Decimal(d) * 25, cost: 9_500)
  }
  let series = HistoricalValueSeries(
    hostCurrency: aud,
    total: points,
    perInstrument: [bhp.id: points]
  )
  return PositionsView(
    input: PositionsViewInput(
      title: "Brokerage",
      hostCurrency: aud,
      positions: [
        ValuedPosition(
          instrument: bhp, quantity: 100,
          unitPrice: InstrumentAmount(quantity: (points.last?.value ?? 0) / 100, instrument: aud),
          costBasis: InstrumentAmount(quantity: 9_500, instrument: aud),
          value: InstrumentAmount(quantity: points.last?.value ?? 0, instrument: aud)
        )
      ],
      historicalValue: series
    ),
    range: .constant(.threeMonths)
  )
  .frame(width: 720, height: 640)
}
