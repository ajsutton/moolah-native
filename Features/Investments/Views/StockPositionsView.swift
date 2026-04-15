import SwiftUI

struct StockPositionsView: View {
  let valuedPositions: [ValuedPosition]
  let totalValue: Decimal
  let profileCurrency: Instrument

  var body: some View {
    VStack(spacing: 0) {
      // Header with total
      HStack {
        Text("Positions")
          .font(.headline)
        Spacer()
        Text(totalValue.formatted(.currency(code: profileCurrency.id)))
          .font(.headline)
          .monospacedDigit()
      }
      .padding(.horizontal)
      .padding(.vertical, 12)

      Divider()

      if valuedPositions.isEmpty {
        ContentUnavailableView(
          "No Positions",
          systemImage: "chart.bar",
          description: Text("Record a trade to start tracking positions")
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
    valuedPositions.filter { $0.position.instrument.kind == .stock }
  }

  private var cashPositions: [ValuedPosition] {
    valuedPositions.filter { $0.position.instrument.kind == .fiatCurrency }
  }
}
