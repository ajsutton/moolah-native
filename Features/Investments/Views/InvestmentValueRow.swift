import SwiftUI

struct InvestmentValueRow: View {
  let value: InvestmentValue
  let onDelete: () -> Void

  var body: some View {
    HStack {
      Text(value.date, format: .dateTime.day().month(.abbreviated).year())
        .font(.headline)
        .monospacedDigit()

      Spacer()

      InstrumentAmountView(amount: value.value)
        .font(.headline)
    }
    .accessibilityElement(children: .combine)  // Date + amount combine naturally: "15 Apr 2026, $5,000.00"
    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
      Button(role: .destructive) {
        onDelete()
      } label: {
        Label("Delete", systemImage: "trash")
      }
    }
    .contextMenu {
      Button(role: .destructive) {
        onDelete()
      } label: {
        Label("Delete", systemImage: "trash")
      }
    }
  }
}

#Preview {
  List {
    InvestmentValueRow(
      value: InvestmentValue(
        date: Date(),
        value: InstrumentAmount(quantity: 5432, instrument: .AUD)
      ),
      onDelete: {}
    )
    InvestmentValueRow(
      value: InvestmentValue(
        date: Calendar.current.date(byAdding: .month, value: -1, to: Date())!,
        value: InstrumentAmount(quantity: 5010, instrument: .AUD)
      ),
      onDelete: {}
    )
  }
  .frame(width: 320)
}
