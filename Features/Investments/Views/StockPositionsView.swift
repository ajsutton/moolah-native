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
