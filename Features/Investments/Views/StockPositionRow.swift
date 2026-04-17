import SwiftUI

struct StockPositionRow: View {
  let valuedPosition: ValuedPosition
  let profileCurrency: Instrument

  var body: some View {
    HStack {
      VStack(alignment: .leading, spacing: 2) {
        Text(valuedPosition.position.instrument.name)
          .font(.headline)
        Text(quantityText)
          .font(.caption)
          .foregroundStyle(.secondary)
          .monospacedDigit()
      }

      Spacer()

      VStack(alignment: .trailing, spacing: 2) {
        if let marketValue = valuedPosition.marketValue {
          Text(formatCurrency(marketValue))
            .font(.body)
            .monospacedDigit()
        } else {
          Text("--")
            .font(.body)
            .foregroundStyle(.tertiary)
        }
      }
    }
    .padding(.vertical, 4)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(accessibilityText)
  }

  private var quantityText: String {
    let position = valuedPosition.position
    if position.instrument.kind == .fiatCurrency {
      return formatCurrency(position.quantity)
    }
    let formatter = NumberFormatter()
    formatter.minimumFractionDigits = 0
    formatter.maximumFractionDigits = position.instrument.decimals
    formatter.numberStyle = .decimal
    return
      "\(formatter.string(from: position.quantity as NSDecimalNumber) ?? "\(position.quantity)") shares"
  }

  private func formatCurrency(_ value: Decimal) -> String {
    value.formatted(.currency(code: profileCurrency.id))
  }

  private var accessibilityText: String {
    let name = valuedPosition.position.instrument.name
    if let value = valuedPosition.marketValue {
      return "\(name), \(quantityText), valued at \(formatCurrency(value))"
    }
    return "\(name), \(quantityText), value unavailable"
  }
}

#Preview {
  let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")
  let apple = Instrument.stock(ticker: "AAPL", exchange: "NASDAQ", name: "Apple")
  List {
    StockPositionRow(
      valuedPosition: ValuedPosition(
        position: Position(instrument: bhp, quantity: 250),
        marketValue: 11_325
      ),
      profileCurrency: .AUD
    )
    StockPositionRow(
      valuedPosition: ValuedPosition(
        position: Position(instrument: apple, quantity: 40),
        marketValue: nil
      ),
      profileCurrency: .AUD
    )
  }
  .frame(width: 380)
}
