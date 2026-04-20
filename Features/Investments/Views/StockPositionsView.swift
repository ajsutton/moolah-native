import SwiftUI

struct StockPositionsView: View {
  let valuedPositions: [ValuedPosition]
  /// Profile-currency total. `nil` means at least one position's
  /// valuation failed, so we must not render a partial sum as the total.
  let totalValue: Decimal?
  let profileCurrency: Instrument

  var body: some View {
    VStack(spacing: 0) {
      // Header with total
      HStack {
        Text("Positions")
          .font(.headline)
        Spacer()
        if let totalValue {
          Text(totalValue.formatted(.currency(code: profileCurrency.id)))
            .font(.headline)
            .monospacedDigit()
        } else {
          Text("Unavailable")
            .font(.headline)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Total portfolio value unavailable")
        }
      }
      .padding(.horizontal)
      .padding(.vertical, 12)

      Divider()

      if valuedPositions.isEmpty {
        ContentUnavailableView(
          "No Positions Yet",
          systemImage: "chart.bar",
          description: Text(
            PlatformActionVerb.emptyStatePrompt(
              buttonLabel: "Record Trade",
              suffix: "to log your first buy or sell — we'll track the rest."
            )
          )
        )
      } else {
        List {
          // Stock positions first, then fiat
          ForEach(stockPositions) { vp in
            StockPositionRow(valuedPosition: vp, profileCurrency: profileCurrency)
          }
          if !cashPositions.isEmpty {
            Section("Cash") {
              ForEach(cashPositions) { vp in
                StockPositionRow(valuedPosition: vp, profileCurrency: profileCurrency)
              }
            }
          }
        }
        .listStyle(.inset)
      }
    }
  }

  private var stockPositions: [ValuedPosition] {
    valuedPositions.filter { $0.instrument.kind == .stock }
  }

  private var cashPositions: [ValuedPosition] {
    valuedPositions.filter { $0.instrument.kind == .fiatCurrency }
  }
}

#Preview {
  let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")
  let cba = Instrument.stock(ticker: "CBA.AX", exchange: "ASX", name: "CBA")
  StockPositionsView(
    valuedPositions: [
      ValuedPosition(
        instrument: bhp, quantity: 250, unitPrice: nil, costBasis: nil,
        value: InstrumentAmount(quantity: 11_325, instrument: .AUD)),
      ValuedPosition(
        instrument: cba, quantity: 80, unitPrice: nil, costBasis: nil,
        value: InstrumentAmount(quantity: 9_600, instrument: .AUD)),
      ValuedPosition(
        instrument: .AUD, quantity: 2_480, unitPrice: nil, costBasis: nil,
        value: InstrumentAmount(quantity: 2_480, instrument: .AUD)),
    ],
    totalValue: 23_405,
    profileCurrency: .AUD
  )
  .frame(width: 400, height: 360)
}

#Preview("Unavailable total") {
  let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")
  StockPositionsView(
    valuedPositions: [
      ValuedPosition(instrument: bhp, quantity: 250, unitPrice: nil, costBasis: nil, value: nil)
    ],
    totalValue: nil,
    profileCurrency: .AUD
  )
  .frame(width: 400, height: 240)
}

#Preview("Empty") {
  StockPositionsView(
    valuedPositions: [],
    totalValue: nil,
    profileCurrency: .AUD
  )
  .frame(width: 400, height: 240)
}
