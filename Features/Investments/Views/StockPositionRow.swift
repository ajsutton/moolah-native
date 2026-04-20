import SwiftUI

struct StockPositionRow: View {
  let valuedPosition: ValuedPosition
  let profileCurrency: Instrument

  var body: some View {
    HStack {
      VStack(alignment: .leading, spacing: 2) {
        Text(valuedPosition.instrument.name)
          .font(.headline)
        Text(quantityText)
          .font(.caption)
          .foregroundStyle(.secondary)
          .monospacedDigit()
      }

      Spacer()

      VStack(alignment: .trailing, spacing: 2) {
        if let marketValue = valuedPosition.value?.quantity {
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
    let instrument = valuedPosition.instrument
    let quantity = valuedPosition.quantity
    if instrument.kind == .fiatCurrency {
      return formatCurrency(quantity)
    }
    let formatter = NumberFormatter()
    formatter.minimumFractionDigits = 0
    formatter.maximumFractionDigits = instrument.decimals
    formatter.numberStyle = .decimal
    return
      "\(formatter.string(from: quantity as NSDecimalNumber) ?? "\(quantity)") shares"
  }

  private func formatCurrency(_ value: Decimal) -> String {
    value.formatted(.currency(code: profileCurrency.id))
  }

  private var accessibilityText: String {
    let name = valuedPosition.instrument.name
    if let value = valuedPosition.value?.quantity {
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
        instrument: bhp, quantity: 250, unitPrice: nil, costBasis: nil,
        value: InstrumentAmount(quantity: 11_325, instrument: .AUD)
      ),
      profileCurrency: .AUD
    )
    StockPositionRow(
      valuedPosition: ValuedPosition(
        instrument: apple, quantity: 40, unitPrice: nil, costBasis: nil, value: nil
      ),
      profileCurrency: .AUD
    )
  }
  .frame(width: 380)
}
